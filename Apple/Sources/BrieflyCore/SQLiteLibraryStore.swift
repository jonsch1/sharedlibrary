import Foundation

public enum LibraryError: LocalizedError {
    case emptyCapture
    case emptyDocument
    case emptyHighlight
    case highlightTooLong
    case invalidAudio
    case missingEntry
    case missingChannel
    case channelAlreadyExists
    case missingVariant
    case missingVoiceBrief
    case invalidChannel
    case invalidChannelTitle
    case invalidChannelRetrievalCount
    case invalidChannelSchedule
    case channelFailed(String)
    case invalidProcessingOutput
    case invalidProcessingPrompt
    case invalidProcessingCommand
    case invalidTopic
    case invalidTopicDefinitions(String)
    case processingFailed(String)
    case processingOutputTooLarge
    case processingTimedOut
    case processingUnavailable
    case invalidVoiceBriefLength
    case invalidVoiceBriefSchedule
    case invalidVoiceBriefScript
    case invalidVoiceBriefTitle
    case invalidSynchronizedFile(String)
    case noVoiceBriefItems

    public var errorDescription: String? {
        switch self {
        case .emptyCapture: "The clipboard does not contain text."
        case .emptyDocument: "The PDF does not contain extractable text."
        case .emptyHighlight: "Select some document text before highlighting."
        case .highlightTooLong: "A highlight must be 50,000 characters or fewer."
        case .invalidAudio: "Briefly could not save the generated audio."
        case .missingEntry: "The selected library item no longer exists."
        case .missingChannel: "The selected channel no longer exists."
        case .channelAlreadyExists: "One of these sources is already in a channel."
        case .missingVariant: "That document version is not available."
        case .missingVoiceBrief: "The selected voice brief no longer exists."
        case .invalidChannel: "Channels must be HTTP(S) URLs or arXiv queries."
        case .invalidChannelTitle: "Channel names must contain 1–120 characters."
        case .invalidChannelRetrievalCount:
            "Items per check must be between 1 and 100."
        case .invalidChannelSchedule:
            "Schedule must be manual, daily HH:MM, or weekly MON HH:MM."
        case .channelFailed(let message): message
        case .invalidProcessingOutput:
            "AI processing did not return the required summaries and topic."
        case .invalidProcessingPrompt:
            "The processing prompt must include {{topics}} and {{source}}."
        case .invalidProcessingCommand:
            "The AI command must contain 1–4,000 characters."
        case .invalidTopic: "Topic titles must contain 1–48 characters."
        case .invalidTopicDefinitions(let message): message
        case .processingFailed(let message): message
        case .processingOutputTooLarge:
            "The AI command returned more than 10 MB of output."
        case .processingTimedOut: "AI processing timed out after 5 minutes."
        case .processingUnavailable:
            "Local AI commands are only available in the macOS app."
        case .invalidVoiceBriefLength:
            "The length instruction must be 120 characters or fewer."
        case .invalidVoiceBriefSchedule:
            "Schedule must be manual, hourly :MM, daily HH:MM, or weekly MON HH:MM."
        case .invalidVoiceBriefScript:
            "AI processing returned an empty voice brief."
        case .invalidVoiceBriefTitle:
            "Voice brief titles must contain 1–120 characters."
        case .invalidSynchronizedFile(let path):
            "The synchronized copy of \(path) is invalid."
        case .noVoiceBriefItems:
            "No new channel items are ready for this voice brief."
        }
    }
}
public actor SQLiteLibraryStore {
    public let databaseURL: URL
    let fileManager = FileManager.default
    private var sqliteLibrary: SQLiteLibrary?

    public init(databaseURL: URL) {
        self.databaseURL = databaseURL.standardizedFileURL
    }

    func database() throws -> SQLiteLibrary {
        if let sqliteLibrary { return sqliteLibrary }
        let database = try SQLiteLibrary(databaseURL: databaseURL)
        try database.trashDocumentsFromDeletedChannels()
        sqliteLibrary = database
        return database
    }

    public func documentDatabase() throws -> SQLiteLibrary { try database() }

    public func capture(_ value: String) throws -> String {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw LibraryError.emptyCapture }
        let sourceURL = httpURL(text)
        let title = sourceURL?.host?
            .replacingOccurrences(of: "www.", with: "") ??
            firstUsefulLine(text)
        return try saveCapture(
            title: title,
            content: text,
            sourceURL: sourceURL,
            entryType: sourceURL == nil ? "text" : "link"
        )
    }

    @discardableResult
    public func captureWebPage(
        title: String,
        content: String,
        sourceURL: URL,
        asVoiceBriefSource: Bool = false,
        faviconData: Data? = nil,
        faviconFileExtension: String? = nil
    ) throws -> String {
        guard sourceURL.scheme == "http" || sourceURL.scheme == "https" else {
            throw LibraryError.invalidChannel
        }
        let text = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw LibraryError.emptyCapture }
        return try saveCapture(
            title: title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? sourceURL.host ?? "Web capture"
                : title,
            content: text,
            sourceURL: sourceURL,
            entryType: asVoiceBriefSource ? "voice_brief_source" : "link",
            faviconData: faviconData,
            faviconFileExtension: faviconFileExtension
        )
    }

    @discardableResult
    public func captureDocument(title: String, content: String) throws -> String {
        let text = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw LibraryError.emptyDocument }
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return try saveCapture(
            title: name.isEmpty ? "PDF document" : String(name.prefix(200)),
            content: text,
            sourceURL: nil,
            entryType: "pdf"
        )
    }

    @discardableResult
    public func captureItem(
        _ draft: ItemDraft,
        asVoiceBriefSource: Bool = false
    ) throws -> String {
        let content = draft.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { throw LibraryError.emptyCapture }
        let database = try database()
        if let key = draft.canonicalKey {
            // ponytail: linear scan is enough for a personal library; add a canonical_key index at 10k+ items.
            if let existing = try database.allDocuments().first(where: {
                $0.type != "voice_brief_episode" &&
                    canonicalItemIdentity($0.sourceURL.flatMap(URL.init(string:))) == key
            }) {
                let sourceURL = (draft.canonicalURL ?? draft.sourceURL)?.absoluteString
                let mediaURL = draft.mediaURL?.absoluteString
                if existing.texts[.source] != content ||
                    (existing.mediaURL == nil && mediaURL != nil) ||
                    (existing.sourceURL == nil && sourceURL != nil) ||
                    (existing.type == "voice_brief_source" && !asVoiceBriefSource) {
                    _ = try database.commitDocument(SQLiteDocumentCommit(
                        id: existing.id,
                        baseRevision: existing.revision,
                        type: existing.type == "voice_brief_source" && !asVoiceBriefSource
                            ? "link"
                            : nil,
                        sourceURL: existing.sourceURL == nil ? sourceURL : nil,
                        mediaURL: existing.mediaURL == nil ? mediaURL : nil,
                        texts: existing.texts[.source] == content ? [:] : [.source: content]
                    ))
                }
                try saveDraftAttachments(draft, documentID: existing.id, database: database)
                return existing.id
            }
        }
        let entryType: String = switch (asVoiceBriefSource, draft.inputID) {
        case (true, _): "voice_brief_source"
        case (_, .text): "text"
        case (_, .pdf): "pdf"
        default: "link"
        }
        return try saveCapture(
            title: draft.title,
            content: content,
            sourceURL: draft.canonicalURL ?? draft.sourceURL,
            mediaURL: draft.mediaURL,
            entryType: entryType,
            faviconData: draft.faviconData,
            faviconFileExtension: draft.faviconFileExtension,
            audioData: draft.audioData,
            audioMimeType: draft.audioMimeType
        )
    }


    public func loadChannels() throws -> [LibraryChannel] {
        var state = readChannelState()
        var repaired = false
        for source in Array(state.sources.keys) {
            guard var current = state.sources[source] else { continue }
            let count = current.items.count
            try repairChannelState(&current)
            if current.items.count != count {
                state.sources[source] = current
                repaired = true
            }
        }
        if repaired { try writeChannelState(state) }
        return try buildChannels(from: state)
    }

    @discardableResult
    public func addChannel(_ value: String) throws -> String {
        try addChannel([value])
    }

    @discardableResult
    public func addChannel(_ values: [String]) throws -> String {
        let normalized = try values.map(normalizedChannelSource)
        let sources = Array(NSOrderedSet(array: normalized).array.compactMap { $0 as? String })
        guard !sources.isEmpty else { throw LibraryError.invalidChannel }
        let groupID = sources.count == 1 ? sources[0] : UUID().uuidString.uppercased()
        var state = readChannelState()
        if sources.count == 1, let existing = state.sources[sources[0]] {
            return existing.groupID ?? sources[0]
        }
        for source in sources {
            guard state.sources[source] == nil else { throw LibraryError.channelAlreadyExists }
            state.sources[source] = .init(
                groupID: groupID,
                schedule: "manual",
                retrievalCount: 5,
                seen: [],
                items: []
            )
        }
        try writeChannelState(state)
        return groupID
    }

    public func updateChannel(
        _ value: String,
        retrievalCount: Int,
        schedule valueSchedule: String
    ) throws {
        let source = try normalizedChannelSource(value)
        guard (1...100).contains(retrievalCount) else {
            throw LibraryError.invalidChannelRetrievalCount
        }
        let schedule = valueSchedule.trimmingCharacters(in: .whitespacesAndNewlines)
        guard validSchedule(schedule.isEmpty ? "manual" : schedule) else {
            throw LibraryError.invalidChannelSchedule
        }
        var state = readChannelState()
        let isDefined = try readVoiceBriefs().contains { $0.sources.contains(source) }
        guard state.sources[source] != nil || isDefined else {
            throw LibraryError.missingChannel
        }
        var current = state.sources[source] ?? .init(seen: [], items: [])
        current.retrievalCount = retrievalCount
        current.schedule = schedule.isEmpty ? "manual" : schedule
        state.sources[source] = current
        try writeChannelState(state)
    }

    public func updateChannelGroup(
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
        var state = readChannelState()
        let previousSources = state.sources.compactMap { source, value in
            (value.groupID ?? source) == groupID ? source : nil
        }
        guard !previousSources.isEmpty else { throw LibraryError.missingChannel }
        let conflicts = sources.filter { source in
            guard let value = state.sources[source] else { return false }
            return (value.groupID ?? source) != groupID
        }
        guard conflicts.isEmpty else { throw LibraryError.channelAlreadyExists }

        for source in Set(previousSources).subtracting(sources) {
            _ = try removeChannel(source)
        }

        state = readChannelState()
        let template = previousSources.compactMap { state.sources[$0] }.first
        for source in sources {
            if state.sources[source] == nil {
                state.sources[source] = .init(
                    groupID: groupID,
                    groupTitle: title,
                    schedule: template?.schedule ?? "manual",
                    retrievalCount: template?.retrievalCount ?? 5,
                    autoSummarize: autoSummarize,
                    seen: [],
                    items: []
                )
            }
            state.sources[source]?.groupID = groupID
            state.sources[source]?.groupTitle = title
            state.sources[source]?.autoSummarize = autoSummarize
        }
        try writeChannelState(state)
        for source in sources {
            try updateChannel(source, retrievalCount: retrievalCount, schedule: schedule)
        }
    }

    @discardableResult
    public func removeChannel(_ value: String) throws -> Int {
        let source = try normalizedChannelSource(value)
        var state = readChannelState()
        let owners = try readVoiceBriefs().filter { $0.sources.contains(source) }
        guard state.sources[source] != nil || !owners.isEmpty else {
            throw LibraryError.missingChannel
        }
        for brief in owners {
            _ = try saveVoiceBrief(
                LibraryVoiceBriefDraft(
                    id: brief.id,
                    title: brief.title,
                    schedule: brief.schedule,
                    length: brief.length,
                    sources: brief.sources.filter { $0 != source },
                    prioritizeForMe: brief.prioritizeForMe == true
                )
            )
        }
        let entryIDs = Set(state.sources[source]?.items.map(\.entryID) ?? [])
            .filter { !$0.isEmpty }
        let documents = entryIDs.compactMap { try? database().getDocument($0) }
        try database().batch(documents.map {
            SQLiteDocumentCommit(
                id: $0.id,
                baseRevision: $0.revision,
                deleted: true
            )
        })
        state.sources.removeValue(forKey: source)
        try database().deleteChannel(source)
        try writeChannelState(state)
        return documents.count
    }

    @discardableResult
    public func removeChannelGroup(_ groupID: String) throws -> Int {
        let sources = readChannelState().sources.compactMap { source, value in
            (value.groupID ?? source) == groupID ? source : nil
        }
        guard !sources.isEmpty else { throw LibraryError.missingChannel }
        var removed = 0
        for source in sources {
            removed += try removeChannel(source)
        }
        return removed
    }

    public func checkChannel(
        _ value: String,
        maximumItems: Int? = nil,
        ingest: @Sendable (LibraryChannelCandidate) async throws -> String
    ) async throws -> LibraryChannelRefresh {
        let source = try normalizedChannelSource(value)
        var state = readChannelState()
        let isDefined = try readVoiceBriefs().contains { $0.sources.contains(source) }
        guard state.sources[source] != nil || isDefined else {
            throw LibraryError.missingChannel
        }
        var current = state.sources[source] ?? .init(seen: [], items: [])
        try repairChannelState(&current)
        let limit = min(100, max(1, maximumItems ?? current.retrievalCount ?? 5))
        var newEntryIDs = [String]()
        var failure: Error?
        do {
            let discovered = try await discoverChannel(source, maximumItems: limit)
            newEntryIDs = try await mergeChannel(
                discovered,
                into: &current,
                limit: limit,
                ingest: ingest
            )
        } catch {
            current.error = error.localizedDescription
            failure = error
        }
        current.lastCheckedAt = Date().iso8601
        current.retrievalCount = current.retrievalCount ?? 5
        state.sources[source] = current
        try writeChannelState(state)
        let channel = try buildChannels(from: state).first { $0.sources.contains(source) }
        guard let channel else { throw LibraryError.missingChannel }
        if let failure { throw failure }
        return LibraryChannelRefresh(channel: channel, newEntryIDs: newEntryIDs)
    }

    public func checkChannelInput(
        _ value: String,
        maximumItems: Int? = nil,
        discover: @Sendable (Int) async throws -> ChannelInputBatch,
        ingest: @Sendable (LibraryChannelCandidate) async throws -> String
    ) async throws -> LibraryChannelRefresh {
        let source = try normalizedChannelSource(value)
        var state = readChannelState()
        let isDefined = try readVoiceBriefs().contains { $0.sources.contains(source) }
        guard state.sources[source] != nil || isDefined else { throw LibraryError.missingChannel }
        var current = state.sources[source] ?? .init(seen: [], items: [])
        try repairChannelState(&current)
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
            let newEntryIDs = try await mergeChannel(
                discovered,
                into: &current,
                limit: limit,
                ingest: ingest
            )
            current.lastCheckedAt = Date().iso8601
            current.retrievalCount = current.retrievalCount ?? 5
            state.sources[source] = current
            try writeChannelState(state)
            guard let channel = try buildChannels(from: state).first(where: { $0.sources.contains(source) }) else {
                throw LibraryError.missingChannel
            }
            return .init(channel: channel, newEntryIDs: newEntryIDs)
        } catch {
            current.error = error.localizedDescription
            current.lastCheckedAt = Date().iso8601
            current.retrievalCount = current.retrievalCount ?? 5
            state.sources[source] = current
            try writeChannelState(state)
            throw error
        }
    }

    public func captureSignedInChannelPage(
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
            items: [
                LibraryChannelCandidate(
                    id: voiceBriefItemKey(value, text),
                    title: title,
                    url: value,
                    content: text
                )
            ],
            ingest: ingest
        )
    }

    public func captureSignedInChannelItems(
        source value: String,
        title: String,
        items: [LibraryChannelCandidate],
        ingest: @Sendable (LibraryChannelCandidate) async throws -> String
    ) async throws -> LibraryChannelRefresh {
        let source = try normalizedChannelSource(value)
        let candidates = items.filter {
            !$0.id.isEmpty &&
                httpURL($0.url) != nil &&
                !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard !candidates.isEmpty else { throw LibraryError.emptyCapture }
        var state = readChannelState()
        let isDefined = try readVoiceBriefs().contains { $0.sources.contains(source) }
        guard state.sources[source] != nil || isDefined else {
            throw LibraryError.missingChannel
        }
        var current = state.sources[source] ?? .init(seen: [], items: [])
        let discovered = DiscoveredChannel(
            title: title.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ??
                channelDisplayTitle(source),
            kind: .page,
            items: candidates.map {
                .init(
                    id: $0.id,
                    title: $0.title.trimmingCharacters(
                        in: .whitespacesAndNewlines
                    ).nilIfEmpty ?? channelDisplayTitle(source),
                    url: $0.url,
                    publishedAt: $0.publishedAt,
                    content: $0.content.trimmingCharacters(
                        in: .whitespacesAndNewlines
                    ),
                    linkedURL: $0.linkedURL
                )
            }
        )
        let limit = min(100, max(current.retrievalCount ?? 5, candidates.count))
        let newEntryIDs = try await mergeChannel(
            discovered,
            into: &current,
            limit: limit,
            ingest: ingest
        )
        current.lastCheckedAt = Date().iso8601
        current.retrievalCount = current.retrievalCount ?? 5
        state.sources[source] = current
        try writeChannelState(state)
        let channel = try buildChannels(from: state).first { $0.sources.contains(source) }
        guard let channel else { throw LibraryError.missingChannel }
        return LibraryChannelRefresh(channel: channel, newEntryIDs: newEntryIDs)
    }

    public func loadMoreChannel(
        _ value: String,
        ingest: @Sendable (LibraryChannelCandidate) async throws -> String
    ) async throws -> LibraryChannelRefresh {
        let source = try normalizedChannelSource(value)
        let state = readChannelState()
        let current = state.sources[source]
        return try await checkChannel(
            source,
            maximumItems: min(
                100,
                (current?.items.count ?? 0) + (current?.retrievalCount ?? 5)
            ),
            ingest: ingest
        )
    }

    public func runVoiceBrief(id: String) async throws -> LibraryVoiceBriefEpisodeResult {
        guard let brief = try readVoiceBriefs().first(where: { $0.id == id }) else {
            throw LibraryError.missingVoiceBrief
        }
        var state = readChannelState()
        var run = state.voiceBriefs[id] ?? .init()
        run.lastAttemptAt = Date().iso8601
        state.voiceBriefs[id] = run
        try writeChannelState(state)
        let consumed = Set(run.consumed)
        let pending = brief.sources.flatMap { source in
            (state.sources[source]?.items ?? [])
                .filter { !consumed.contains(voiceBriefItemKey(source, $0.id)) }
                .map { (source, $0) }
        }
        guard !pending.isEmpty else { throw LibraryError.noVoiceBriefItems }

        let projection = try loadProjection()
        let entries = Dictionary(uniqueKeysWithValues: projection.entries.map { ($0.id, $0) })
        var sections = [LibraryVariant: [String]]()
        var selected = [(String, LibraryChannelItem)]()
        var characterCounts = [LibraryVariant: Int]()
        for (source, item) in pending {
            let entry = entries[item.entryID]
            var included = false
            for variant in [LibraryVariant.concise, .detailed] {
                guard let text = entry?.text(for: variant)?.text?
                    .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty
                else { continue }
                let section = """
                ## \(item.title)

                \(text)
                """
                let count = characterCounts[variant, default: 0]
                guard count < 120_000 else { continue }
                let fitted = String(section.prefix(120_000 - count))
                sections[variant, default: []].append(fitted)
                characterCounts[variant] = count + fitted.count
                included = true
            }
            if included { selected.append((source, item)) }
        }
        guard sections.values.contains(where: { !$0.isEmpty }) else {
            throw LibraryError.noVoiceBriefItems
        }

        run.status = "generating"
        run.message = "Generating \(brief.title)"
        state.voiceBriefs[id] = run
        try writeChannelState(state)
        do {
            let scripts = sections.mapValues {
                "# \(brief.title)\n\n" + $0.joined(separator: "\n\n")
            }
            let entryID = try saveVoiceBriefEpisode(
                brief: brief,
                scripts: scripts,
                sources: selected.map(\.1)
            )
            run.consumed = Array(Set(
                run.consumed + selected.map { voiceBriefItemKey($0.0, $0.1.id) }
            ))
            run.pendingEpisodeID = nil
            run.lastRunAt = Date().iso8601
            run.status = "ready"
            run.message = "Brief ready."
            state.voiceBriefs[id] = run
            try writeChannelState(state)
            return LibraryVoiceBriefEpisodeResult(
                entryID: entryID,
                script: scripts[.concise] ?? scripts[.detailed] ?? ""
            )
        } catch {
            run.status = "error"
            run.message = error.localizedDescription
            state.voiceBriefs[id] = run
            try? writeChannelState(state)
            throw error
        }
    }

    public func queueVoiceBriefRun(id: String) throws {
        guard try readVoiceBriefs().contains(where: { $0.id == id }) else {
            throw LibraryError.missingVoiceBrief
        }
        var state = readChannelState()
        var run = state.voiceBriefs[id] ?? .init()
        if run.pendingEpisodeID == nil {
            run.status = "queued"
            run.message = "Waiting to prepare"
        }
        state.voiceBriefs[id] = run
        try writeChannelState(state)
    }

    public func cancelVoiceBriefRun(id: String) throws {
        guard try readVoiceBriefs().contains(where: { $0.id == id }) else {
            throw LibraryError.missingVoiceBrief
        }
        var state = readChannelState()
        var run = state.voiceBriefs[id] ?? .init()
        run.status = "cancelled"
        run.message = "Preparation cancelled."
        state.voiceBriefs[id] = run
        try writeChannelState(state)
    }

    public func pendingVoiceBriefIDs() throws -> [String] {
        let active = Set(["queued", "generating"])
        return readChannelState().voiceBriefs.compactMap { id, run in
            run.status.map(active.contains) == true ? id : nil
        }
    }

    public func dueVoiceBriefIDs(at date: Date = Date()) throws -> [String] {
        let state = readChannelState()
        return try readVoiceBriefs().compactMap { brief in
            guard let scheduled = mostRecentScheduledDate(brief.schedule, at: date) else {
                return nil
            }
            let run = state.voiceBriefs[brief.id]
            let attempted = [run?.lastAttemptAt, run?.lastRunAt]
                .compactMap { $0.flatMap(ISO8601DateFormatter().date(from:)) }
                .max()
            return attempted == nil || attempted! < scheduled ? brief.id : nil
        }
    }

    public func dueChannelSources(at date: Date = Date()) throws -> [String] {
        try buildChannels(from: readChannelState()).compactMap { channel in
            guard let scheduled = mostRecentScheduledDate(channel.schedule, at: date) else {
                return nil
            }
            let checked = channel.lastCheckedAt.flatMap {
                ISO8601DateFormatter().date(from: $0)
            }
            return checked == nil || checked! < scheduled ? channel.source : nil
        }
    }

    public func markVoiceBriefAttempt(id: String, at date: Date = Date()) throws {
        guard try readVoiceBriefs().contains(where: { $0.id == id }) else {
            throw LibraryError.missingVoiceBrief
        }
        var state = readChannelState()
        var run = state.voiceBriefs[id] ?? .init()
        run.lastAttemptAt = date.iso8601
        state.voiceBriefs[id] = run
        try writeChannelState(state)
    }


    public func loadHighlights() throws -> String {
        (try? database().getDocument("system:highlights").texts[.source]) ?? ""
    }

    public func addHighlight(
        entryID: String,
        variant: LibraryVariant,
        text: String
    ) throws {
        let highlighted = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !highlighted.isEmpty else { throw LibraryError.emptyHighlight }
        guard highlighted.count <= 50_000 else { throw LibraryError.highlightTooLong }

        let document = try database().getDocument(entryID)
        let title = document.title
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
        let quote = highlighted.components(separatedBy: .newlines)
            .map { "> \($0)" }
            .joined(separator: "\n")
        let source = document.sourceURL.map { "\n\n[Open original](\($0))" } ?? ""
        let item = """
        ## \(title)

        \(quote)

        _\(variant.title) · \(Date().formatted(date: .abbreviated, time: .omitted))_\(source)
        """
        let existing = try loadHighlights()
        let output = existing.isEmpty
            ? "# Highlights\n\n\(item)\n"
            : "\(existing)\n\n\(item)\n"
        try saveHighlights(output)
    }

    @discardableResult
    public func removeHighlight(_ text: String) throws -> Bool {
        let target = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { return false }
        let existing = try loadHighlights()
        let parts = existing.components(separatedBy: "\n\n## ")
        guard parts.count > 1 else { return false }
        var kept = [parts[0]]
        var removed = false
        for part in parts.dropFirst() {
            let section = "## \(part)"
            let quote = section.components(separatedBy: .newlines)
                .filter { $0.hasPrefix("> ") }
                .map { String($0.dropFirst(2)) }
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if quote == target {
                removed = true
            } else {
                kept.append(section)
            }
        }
        guard removed else { return false }
        let output = kept.count == 1 ? "" : kept.joined(separator: "\n\n") + "\n"
        try saveHighlights(output)
        return true
    }

    private func saveHighlights(_ text: String) throws {
        let database = try database()
        if let document = try? database.getDocument("system:highlights", includeDeleted: true) {
            try database.commitDocument(SQLiteDocumentCommit(
                id: document.id,
                baseRevision: document.revision,
                texts: [.source: text],
                deleted: false
            ))
        } else if !text.isEmpty {
            _ = try database.createDocument(
                title: "Highlights",
                body: text,
                type: "highlights",
                id: "system:highlights",
                captureID: "HIGHLIGHTS"
            )
        }
    }

    @discardableResult
    public func saveVoiceBrief(_ value: LibraryVoiceBriefDraft) throws -> String {
        let title = value.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.count <= 120 else {
            throw LibraryError.invalidVoiceBriefTitle
        }
        let schedule = value.schedule.trimmingCharacters(in: .whitespacesAndNewlines)
        guard validSchedule(schedule.isEmpty ? "manual" : schedule) else {
            throw LibraryError.invalidVoiceBriefSchedule
        }
        guard value.length.count <= 120 else {
            throw LibraryError.invalidVoiceBriefLength
        }
        let sources = Array(
            Set(value.sources.map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }.filter { !$0.isEmpty })
        ).sorted()
        guard sources.count <= 200, sources.allSatisfy(validChannelSource) else {
            throw LibraryError.invalidChannel
        }

        return try database().saveVoiceBrief(LibraryVoiceBriefDraft(
            id: value.id,
            title: title,
            schedule: schedule.isEmpty ? "manual" : schedule,
            length: value.length.trimmingCharacters(in: .whitespacesAndNewlines),
            sources: sources,
            prioritizeForMe: value.prioritizeForMe
        ))
    }

    public func moveVoiceBriefToTrash(id: String) throws {
        guard try readVoiceBriefs().contains(where: { $0.id == id }) else {
            throw LibraryError.missingVoiceBrief
        }
        try database().deleteVoiceBrief(id)
    }

    public func moveToTrash(entryID: String) throws {
        let document = try database().getDocument(entryID)
        try database().commitDocument(SQLiteDocumentCommit(
            id: entryID,
            baseRevision: document.revision,
            deleted: true
        ))
        var state = readChannelState()
        var removedKeys = Set<String>()
        for source in Array(state.sources.keys) {
            guard var current = state.sources[source] else { continue }
            let removed = current.items.filter { $0.entryID == entryID }
            guard !removed.isEmpty else { continue }
            removedKeys.formUnion(removed.map { voiceBriefItemKey(source, $0.id) })
            let ids = Set(removed.map(\.id))
            current.items.removeAll { ids.contains($0.id) }
            current.seen.removeAll { ids.contains($0) }
            state.sources[source] = current
        }
        if !removedKeys.isEmpty {
            for id in Array(state.voiceBriefs.keys) {
                state.voiceBriefs[id]?.consumed.removeAll { removedKeys.contains($0) }
            }
            try writeChannelState(state)
        }
    }


    public func topicDefinitions() throws -> [LibraryTopicDefinition] {
        try database().topicDefinitions()
    }

    @discardableResult
    public func replaceTopicDefinitions(
        _ definitions: [LibraryTopicDefinition]
    ) throws -> [LibraryTopicDefinition] {
        let current = try topicDefinitions()
        let currentIDs = Set(current.map(\.id))
        let usedIDs = Set(try loadLibraryIndex().entries.flatMap(\.topicIDs))
        var ids = Set<String>()
        var titles = Set<String>()
        var normalized = [LibraryTopicDefinition]()
        for definition in definitions {
            let title = definition.title
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .split(whereSeparator: \.isWhitespace)
                .joined(separator: " ")
            guard !title.isEmpty, title.count <= 48 else {
                throw LibraryError.invalidTopicDefinitions(
                    "Every topic needs a title of 48 characters or fewer."
                )
            }
            guard titles.insert(title.lowercased()).inserted else {
                throw LibraryError.invalidTopicDefinitions(
                    "The topic “\(title)” is duplicated."
                )
            }
            var id = definition.id.trimmingCharacters(in: .whitespacesAndNewlines)
            if id.isEmpty {
                let base = slug(title)
                id = base
                var suffix = 2
                while ids.contains(id) || currentIDs.contains(id) {
                    id = "\(base)-\(suffix)"
                    suffix += 1
                }
            }
            guard
                id.range(
                    of: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$"#,
                    options: .regularExpression
                ) != nil,
                ids.insert(id).inserted
            else {
                throw LibraryError.invalidTopicDefinitions(
                    "Topic IDs must be unique and contain only letters, numbers, dots, dashes, or underscores."
                )
            }
            normalized.append(LibraryTopicDefinition(id: id, title: title))
        }
        if let used = usedIDs.first(where: {
            currentIDs.contains($0) && !ids.contains($0)
        }) {
            throw LibraryError.invalidTopicDefinitions(
                "The topic “\(used)” is still used by library items. Rename it instead."
            )
        }
        try database().replaceTopicDefinitions(normalized)
        return normalized
    }

    public func deleteTopicDefinition(id: String) throws {
        let database = try database()
        let topicID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !topicID.isEmpty else { throw LibraryError.invalidTopic }

        let documents = try database.allDocuments(includeDeleted: true)
        let commits = documents.compactMap { document -> SQLiteDocumentCommit? in
            guard document.topicIDs.contains(topicID) else { return nil }
            return SQLiteDocumentCommit(
                id: document.id,
                baseRevision: document.revision,
                topicIDs: document.topicIDs.filter { $0 != topicID }
            )
        }
        try database.batch(commits)
        try database.replaceTopicDefinitions(
            try database.topicDefinitions().filter { $0.id != topicID }
        )
    }

}
