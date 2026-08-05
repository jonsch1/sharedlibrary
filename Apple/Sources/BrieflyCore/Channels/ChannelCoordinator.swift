import Foundation

/// Owns channel lifecycle and refresh workflows. Discovery is supplied by the
/// channel layer and persistence is accessed only through repositories.
struct LibraryChannelCoordinator {
    let documents: SQLiteDocumentRepository
    let voiceBriefs: SQLiteVoiceBriefRepository
    let channels: SQLiteChannelRepository
    let state: LibraryChannelStateRepository

    func loadChannels() throws -> [LibraryChannel] {
        var currentState = state.read()
        var repaired = false
        for source in Array(currentState.sources.keys) {
            guard var current = currentState.sources[source] else { continue }
            let count = current.items.count
            try state.repair(&current)
            if current.items.count != count {
                currentState.sources[source] = current
                repaired = true
            }
        }
        if repaired { try state.write(currentState) }
        return try state.buildChannels(from: currentState)
    }

    func addChannel(_ values: [String]) throws -> String {
        let normalized = try values.map(normalizedChannelSource)
        let sources = Array(NSOrderedSet(array: normalized).array.compactMap { $0 as? String })
        guard !sources.isEmpty else { throw LibraryError.invalidChannel }
        let groupID = sources.count == 1 ? sources[0] : UUID().uuidString.uppercased()
        var currentState = state.read()
        if sources.count == 1, let existing = currentState.sources[sources[0]] {
            return existing.groupID ?? sources[0]
        }
        for source in sources {
            guard currentState.sources[source] == nil else {
                throw LibraryError.channelAlreadyExists
            }
            currentState.sources[source] = .init(
                groupID: groupID,
                schedule: "manual",
                retrievalCount: 5,
                seen: [],
                items: []
            )
        }
        try state.write(currentState)
        return groupID
    }

    func updateChannel(_ value: String, retrievalCount: Int, schedule valueSchedule: String) throws {
        let source = try normalizedChannelSource(value)
        guard (1...100).contains(retrievalCount) else {
            throw LibraryError.invalidChannelRetrievalCount
        }
        let schedule = valueSchedule.trimmingCharacters(in: .whitespacesAndNewlines)
        guard validSchedule(schedule.isEmpty ? "manual" : schedule) else {
            throw LibraryError.invalidChannelSchedule
        }
        var currentState = state.read()
        let isDefined = try state.voiceBriefs().contains { $0.sources.contains(source) }
        guard currentState.sources[source] != nil || isDefined else {
            throw LibraryError.missingChannel
        }
        var current = currentState.sources[source] ?? .init(seen: [], items: [])
        current.retrievalCount = retrievalCount
        current.schedule = schedule.isEmpty ? "manual" : schedule
        currentState.sources[source] = current
        try state.write(currentState)
    }

    func updateChannelGroup(
        _ groupID: String,
        title valueTitle: String,
        sources values: [String],
        retrievalCount: Int,
        autoSummarize: Bool,
        schedule: String
    ) throws {
        let title = valueTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.count <= 120 else { throw LibraryError.invalidChannelTitle }
        let normalized = try values.map(normalizedChannelSource)
        let sources = Array(Set(normalized)).sorted()
        guard !sources.isEmpty else { throw LibraryError.invalidChannel }
        var currentState = state.read()
        let previousSources = currentState.sources.compactMap { source, value in
            (value.groupID ?? source) == groupID ? source : nil
        }
        guard !previousSources.isEmpty else { throw LibraryError.missingChannel }
        let conflicts = sources.filter { source in
            guard let value = currentState.sources[source] else { return false }
            return (value.groupID ?? source) != groupID
        }
        guard conflicts.isEmpty else { throw LibraryError.channelAlreadyExists }
        for source in Set(previousSources).subtracting(sources) {
            _ = try removeChannel(source)
        }
        currentState = state.read()
        let template = previousSources.compactMap { currentState.sources[$0] }.first
        for source in sources {
            if currentState.sources[source] == nil {
                currentState.sources[source] = .init(
                    groupID: groupID,
                    groupTitle: title,
                    schedule: template?.schedule ?? "manual",
                    retrievalCount: template?.retrievalCount ?? 5,
                    autoSummarize: autoSummarize,
                    seen: [],
                    items: []
                )
            }
            currentState.sources[source]?.groupID = groupID
            currentState.sources[source]?.groupTitle = title
            currentState.sources[source]?.autoSummarize = autoSummarize
        }
        try state.write(currentState)
        for source in sources {
            try updateChannel(source, retrievalCount: retrievalCount, schedule: schedule)
        }
    }

    @discardableResult
    func removeChannel(_ value: String) throws -> Int {
        let source = try normalizedChannelSource(value)
        var currentState = state.read()
        let owners = try state.voiceBriefs().filter { $0.sources.contains(source) }
        guard currentState.sources[source] != nil || !owners.isEmpty else {
            throw LibraryError.missingChannel
        }
        for brief in owners {
            _ = try saveVoiceBrief(LibraryVoiceBriefDraft(
                id: brief.id,
                title: brief.title,
                schedule: brief.schedule,
                length: brief.length,
                sources: brief.sources.filter { $0 != source },
                prioritizeForMe: brief.prioritizeForMe == true
            ))
        }
        let entryIDs = Set(currentState.sources[source]?.items.map(\.entryID) ?? [])
            .filter { !$0.isEmpty }
        let documents = entryIDs.compactMap { try? self.documents.get($0) }
        _ = try self.documents.batch(documents.map {
            SQLiteDocumentCommit(id: $0.id, baseRevision: $0.revision, deleted: true)
        })
        currentState.sources.removeValue(forKey: source)
        try channels.delete(source)
        try state.write(currentState)
        return documents.count
    }

    @discardableResult
    func removeChannelGroup(_ groupID: String) throws -> Int {
        let sources = state.read().sources.compactMap { source, value in
            (value.groupID ?? source) == groupID ? source : nil
        }
        guard !sources.isEmpty else { throw LibraryError.missingChannel }
        return try sources.reduce(0) { total, source in total + (try removeChannel(source)) }
    }

    func checkChannel(
        _ value: String,
        maximumItems: Int?,
        ingest: @Sendable (LibraryChannelCandidate) async throws -> String
    ) async throws -> LibraryChannelRefresh {
        let source = try normalizedChannelSource(value)
        var currentState = state.read()
        let isDefined = try state.voiceBriefs().contains { $0.sources.contains(source) }
        guard currentState.sources[source] != nil || isDefined else { throw LibraryError.missingChannel }
        var current = currentState.sources[source] ?? .init(seen: [], items: [])
        try state.repair(&current)
        let limit = min(100, max(1, maximumItems ?? current.retrievalCount ?? 5))
        var newEntryIDs = [String]()
        var failure: Error?
        do {
            let discovered = try await ChannelDiscovery().discover(source, maximumItems: limit)
            newEntryIDs = try await state.merge(discovered, into: &current, limit: limit, ingest: ingest)
        } catch {
            current.error = error.localizedDescription
            failure = error
        }
        current.lastCheckedAt = Date().iso8601
        current.retrievalCount = current.retrievalCount ?? 5
        currentState.sources[source] = current
        try state.write(currentState)
        guard let channel = try state.buildChannels(from: currentState).first(where: {
            $0.sources.contains(source)
        }) else { throw LibraryError.missingChannel }
        if let failure { throw failure }
        return LibraryChannelRefresh(channel: channel, newEntryIDs: newEntryIDs)
    }

    func checkChannelInput(
        _ value: String,
        maximumItems: Int?,
        discover: @Sendable (Int) async throws -> ChannelInputBatch,
        ingest: @Sendable (LibraryChannelCandidate) async throws -> String
    ) async throws -> LibraryChannelRefresh {
        let source = try normalizedChannelSource(value)
        var currentState = state.read()
        let isDefined = try state.voiceBriefs().contains { $0.sources.contains(source) }
        guard currentState.sources[source] != nil || isDefined else { throw LibraryError.missingChannel }
        var current = currentState.sources[source] ?? .init(seen: [], items: [])
        try state.repair(&current)
        let limit = min(100, max(1, maximumItems ?? current.retrievalCount ?? 5))
        do {
            let batch = try await discover(limit)
            let discovered = DiscoveredChannel(
                title: batch.title,
                kind: batch.kind,
                items: batch.items.map { item in
                    .init(
                        id: item.id,
                        title: item.title,
                        url: item.url.absoluteString,
                        publishedAt: item.publishedAt,
                        content: item.hints.content,
                        linkedURL: item.hints.mediaURL?.absoluteString,
                        preferredInput: item.hints.preferredInput,
                        mediaURL: item.hints.mediaURL?.absoluteString,
                        transcriptURL: item.hints.transcriptURL?.absoluteString,
                        transcriptType: item.hints.transcriptType,
                        transcriptLanguage: item.hints.transcriptLanguage
                    )
                }
            )
            let newEntryIDs = try await state.merge(
                discovered,
                into: &current,
                limit: limit,
                ingest: ingest
            )
            current.lastCheckedAt = Date().iso8601
            current.retrievalCount = current.retrievalCount ?? 5
            currentState.sources[source] = current
            try state.write(currentState)
            guard let channel = try state.buildChannels(from: currentState).first(where: {
                $0.sources.contains(source)
            }) else { throw LibraryError.missingChannel }
            return LibraryChannelRefresh(channel: channel, newEntryIDs: newEntryIDs)
        } catch {
            current.error = error.localizedDescription
            current.lastCheckedAt = Date().iso8601
            current.retrievalCount = current.retrievalCount ?? 5
            currentState.sources[source] = current
            try state.write(currentState)
            throw error
        }
    }

    func captureSignedInChannelPage(
        source value: String,
        title: String,
        content: String,
        ingest: @Sendable (LibraryChannelCandidate) async throws -> String
    ) async throws -> LibraryChannelRefresh {
        let text = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw LibraryError.emptyCapture }
        return try await captureSignedInChannelItems(
            source: value,
            title: title,
            items: [LibraryChannelCandidate(
                id: voiceBriefItemKey(value, text), title: title, url: value, content: text
            )],
            ingest: ingest
        )
    }

    func captureSignedInChannelItems(
        source value: String,
        title: String,
        items: [LibraryChannelCandidate],
        ingest: @Sendable (LibraryChannelCandidate) async throws -> String
    ) async throws -> LibraryChannelRefresh {
        let source = try normalizedChannelSource(value)
        let candidates = items.filter {
            !$0.id.isEmpty && httpURL($0.url) != nil &&
                !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard !candidates.isEmpty else { throw LibraryError.emptyCapture }
        var currentState = state.read()
        let isDefined = try state.voiceBriefs().contains { $0.sources.contains(source) }
        guard currentState.sources[source] != nil || isDefined else { throw LibraryError.missingChannel }
        var current = currentState.sources[source] ?? .init(seen: [], items: [])
        let discovered = DiscoveredChannel(
            title: title.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ??
                channelDisplayTitle(source),
            kind: .page,
            items: candidates.map {
                .init(
                    id: $0.id,
                    title: $0.title.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ??
                        channelDisplayTitle(source),
                    url: $0.url,
                    publishedAt: $0.publishedAt,
                    content: $0.content.trimmingCharacters(in: .whitespacesAndNewlines),
                    linkedURL: $0.linkedURL
                )
            }
        )
        let limit = min(100, max(current.retrievalCount ?? 5, candidates.count))
        let newEntryIDs = try await state.merge(discovered, into: &current, limit: limit, ingest: ingest)
        current.lastCheckedAt = Date().iso8601
        current.retrievalCount = current.retrievalCount ?? 5
        currentState.sources[source] = current
        try state.write(currentState)
        guard let channel = try state.buildChannels(from: currentState).first(where: {
            $0.sources.contains(source)
        }) else { throw LibraryError.missingChannel }
        return LibraryChannelRefresh(channel: channel, newEntryIDs: newEntryIDs)
    }

    func loadMoreChannel(
        _ value: String,
        ingest: @Sendable (LibraryChannelCandidate) async throws -> String
    ) async throws -> LibraryChannelRefresh {
        let source = try normalizedChannelSource(value)
        let current = state.read().sources[source]
        return try await checkChannel(
            source,
            maximumItems: min(100, (current?.items.count ?? 0) + (current?.retrievalCount ?? 5)),
            ingest: ingest
        )
    }

    func saveVoiceBrief(_ value: LibraryVoiceBriefDraft) throws -> String {
        let title = value.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.count <= 120 else { throw LibraryError.invalidVoiceBriefTitle }
        let schedule = value.schedule.trimmingCharacters(in: .whitespacesAndNewlines)
        guard validSchedule(schedule.isEmpty ? "manual" : schedule) else {
            throw LibraryError.invalidVoiceBriefSchedule
        }
        guard value.length.count <= 120 else { throw LibraryError.invalidVoiceBriefLength }
        let sources = Array(Set(value.sources.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty })).sorted()
        guard sources.count <= 200, sources.allSatisfy(validChannelSource) else {
            throw LibraryError.invalidChannel
        }
        return try voiceBriefs.save(LibraryVoiceBriefDraft(
            id: value.id,
            title: title,
            schedule: schedule.isEmpty ? "manual" : schedule,
            length: value.length.trimmingCharacters(in: .whitespacesAndNewlines),
            sources: sources,
            prioritizeForMe: value.prioritizeForMe
        ))
    }
}
