import Foundation

struct VoiceBriefWatcherState: Codable {
    struct Source: Codable {
        var groupID: String? = nil
        var groupTitle: String? = nil
        var title: String? = nil
        var kind: LibraryChannelKind? = nil
        var schedule: String? = nil
        var lastCheckedAt: String? = nil
        var error: String? = nil
        var retrievalCount: Int? = nil
        var autoSummarize: Bool? = nil
        var canLoadMore: Bool? = nil
        var seen = [String]()
        var items = [LibraryChannelItem]()
    }

    struct Run: Codable {
        var lastRunAt: String? = nil
        var lastAttemptAt: String? = nil
        var status: String? = nil
        var message: String? = nil
        var consumed = [String]()
        var pendingEpisodeID: String? = nil
    }

    var schemaVersion: Int
    var sources: [String: Source]
    var voiceBriefs: [String: Run]

    static let empty = Self(schemaVersion: 1, sources: [:], voiceBriefs: [:])
}

/// Durable channel and voice-brief state. This repository translates between
/// normalized SQLite records and the workflow state used by channel services.
struct LibraryChannelStateRepository {
    let repositories: SQLiteLibraryRepositories

    func channelStateURL(for root: URL) -> URL {
        root
            .appending(path: ".shared-library", directoryHint: .isDirectory)
            .appending(path: "voice-brief-state.json")
    }

    func voiceBriefs() throws -> [LibraryVoiceBrief] {
        try repositories.documents.voiceBriefs()
    }

    func saveVoiceBriefEpisode(
        brief: LibraryVoiceBrief,
        scripts: [LibraryVariant: String],
        sources: [LibraryChannelItem]
    ) throws -> String {
        let captureID = UUID().uuidString.uppercased()
        let title = scripts[.concise].flatMap(firstHeading) ??
            scripts[.detailed].flatMap(firstHeading) ??
            "\(brief.title) — \(Date().formatted(date: .abbreviated, time: .omitted))"
        let sourceIDs = Array(Set(sources.map(\.entryID)))
        let sourceURLs = Array(Set(sources.map(\.url)))
        let sourceList = sources.map { "- [\($0.title)](\($0.url))" }.joined(separator: "\n")
        let texts = scripts.mapValues { script in
            """
            \(script.trimmingCharacters(in: .whitespacesAndNewlines))

            ## Sources

            \(sourceList)
            """
        }
        return try repositories.documents.create(
            title: title,
            body: texts[.concise] ?? texts[.detailed] ?? "",
            texts: texts,
            type: "voice_brief_episode",
            voiceBriefID: brief.id,
            sourceIDs: sourceIDs,
            sourceURLs: sourceURLs,
            id: "personal:\(captureID)",
            captureID: captureID
        ).id
    }

    func merge(
        _ discovered: DiscoveredChannel,
        into current: inout VoiceBriefWatcherState.Source,
        limit: Int,
        ingest: @Sendable (LibraryChannelCandidate) async throws -> String
    ) async throws -> [String] {
        if current.kind == .page, discovered.kind != .page {
            current.items.removeAll()
            current.seen.removeAll()
        }
        var seen = Set(current.seen)
        var newEntryIDs = [String]()
        var ingestionError: Error?
        for item in discovered.items.prefix(limit).reversed() where !seen.contains(item.id) {
            guard httpURL(item.url) != nil else { continue }
            let content = item.content?.trimmingCharacters(in: .whitespacesAndNewlines)
            let candidate = LibraryChannelCandidate(
                id: item.id,
                title: item.title,
                url: item.url,
                publishedAt: item.publishedAt,
                content: content ?? "",
                linkedURL: item.linkedURL,
                preferredInput: item.preferredInput,
                mediaURL: item.mediaURL,
                transcriptURL: item.transcriptURL,
                transcriptType: item.transcriptType,
                transcriptLanguage: item.transcriptLanguage
            )
            do {
                let entryID = try await ingest(candidate)
                let identity = canonicalItemIdentity(URL(string: item.url))
                let replacedIDs = Set(current.items.filter {
                    identity != nil && canonicalItemIdentity(URL(string: $0.url)) == identity
                }.map(\.id))
                current.items.removeAll {
                    identity != nil && canonicalItemIdentity(URL(string: $0.url)) == identity
                }
                current.items.insert(
                    LibraryChannelItem(
                        id: item.id,
                        title: item.title,
                        url: item.url,
                        publishedAt: item.publishedAt,
                        content: item.content,
                        linkedURL: item.linkedURL,
                        entryID: entryID,
                        ingestedAt: Date().iso8601
                    ),
                    at: 0
                )
                current.seen.removeAll { $0 == item.id || replacedIDs.contains($0) }
                current.seen.insert(item.id, at: 0)
                seen.insert(item.id)
                newEntryIDs.append(entryID)
            } catch {
                ingestionError = error
            }
        }
        current.items = Array(current.items.prefix(100))
        current.seen = Array(NSOrderedSet(array: current.seen).array
            .compactMap { $0 as? String }
            .prefix(100))
        current.title = discovered.title
        current.kind = discovered.kind
        current.error = ingestionError?.localizedDescription
        current.canLoadMore = discovered.items.count >= limit && limit < 100
        return newEntryIDs
    }

    func repair(_ current: inout VoiceBriefWatcherState.Source) throws {
        let missing = Set(current.items.compactMap { item in
            (try? repositories.documents.get(item.entryID)) == nil ? item.id : nil
        })
        guard !missing.isEmpty else { return }
        current.items.removeAll { missing.contains($0.id) }
        current.seen.removeAll { missing.contains($0) }
    }

    func read() -> VoiceBriefWatcherState {
        let sources = (try? repositories.channels.records()) ?? []
        let runs = (try? repositories.channels.runStates()) ?? []
        return VoiceBriefWatcherState(
            schemaVersion: 1,
            sources: Dictionary(uniqueKeysWithValues: sources.map { record in
                (record.source, VoiceBriefWatcherState.Source(
                    groupID: record.groupID,
                    groupTitle: record.groupTitle,
                    title: record.title,
                    kind: record.kind,
                    schedule: record.schedule,
                    lastCheckedAt: record.lastCheckedAt,
                    error: record.error,
                    retrievalCount: record.retrievalCount,
                    autoSummarize: record.autoSummarize,
                    canLoadMore: record.canLoadMore,
                    seen: record.seen,
                    items: record.items
                ))
            }),
            voiceBriefs: Dictionary(uniqueKeysWithValues: runs.map { run in
                (run.voiceBriefID, VoiceBriefWatcherState.Run(
                    lastRunAt: run.lastRunAt,
                    lastAttemptAt: run.lastAttemptAt,
                    status: run.status,
                    message: run.message,
                    consumed: run.consumed,
                    pendingEpisodeID: run.pendingEpisodeID
                ))
            })
        )
    }

    func write(_ state: VoiceBriefWatcherState) throws {
        try repositories.channels.saveRecords(state.sources.map { source, value in
            SQLiteChannelRecord(
                source: source,
                groupID: value.groupID ?? source,
                groupTitle: value.groupTitle,
                title: value.title,
                kind: value.kind,
                schedule: value.schedule ?? "manual",
                lastCheckedAt: value.lastCheckedAt,
                error: value.error,
                retrievalCount: value.retrievalCount ?? 5,
                autoSummarize: value.autoSummarize ?? true,
                canLoadMore: value.canLoadMore ?? true,
                seen: value.seen,
                items: value.items
            )
        })
        try repositories.channels.saveRunStates(state.voiceBriefs.map { id, value in
            SQLiteVoiceBriefRunState(
                voiceBriefID: id,
                lastRunAt: value.lastRunAt,
                lastAttemptAt: value.lastAttemptAt,
                status: value.status,
                message: value.message,
                consumed: value.consumed,
                pendingEpisodeID: value.pendingEpisodeID
            )
        })
    }

    func buildChannels(from state: VoiceBriefWatcherState) throws -> [LibraryChannel] {
        let definitions = try voiceBriefs()
        var allSources = state.sources
        for source in Set(definitions.flatMap(\.sources)) where allSources[source] == nil {
            allSources[source] = .init(groupID: source)
        }
        let groups = Dictionary(grouping: allSources.keys) { source in
            allSources[source]?.groupID ?? source
        }
        return groups.map { groupID, unorderedSources in
            let sources = unorderedSources.sorted()
            let values = sources.compactMap { allSources[$0] }
            let primary = values.first
            let owners = definitions.filter { !Set($0.sources).isDisjoint(with: sources) }
            let items = Dictionary(
                values.flatMap(\.items).map { ($0.entryID.isEmpty ? $0.id : $0.entryID, $0) },
                uniquingKeysWith: { first, _ in first }
            ).values.sorted { $0.ingestedAt > $1.ingestedAt }
            return LibraryChannel(
                source: groupID,
                sources: sources,
                title: primary?.groupTitle ?? primary?.title ?? channelDisplayTitle(sources[0]),
                kind: Set(values.compactMap(\.kind)).count == 1 ? primary?.kind : nil,
                schedule: primary?.schedule ?? "manual",
                lastCheckedAt: values.compactMap(\.lastCheckedAt).max(),
                error: values.compactMap(\.error).first,
                retrievalCount: primary?.retrievalCount ?? 5,
                autoSummarize: primary?.autoSummarize ?? true,
                canLoadMore: values.contains { $0.canLoadMore ?? true },
                items: items,
                briefIDs: owners.map(\.id),
                briefTitles: owners.map(\.title)
            )
        }
        .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }
}
