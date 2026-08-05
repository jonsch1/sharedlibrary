import Foundation
#if os(macOS)
import Darwin
#endif

public func spokenVoiceBriefText(_ markdown: String) -> String {
    var text = markdown
    for (pattern, replacement) in [
        (#"!\[[^\]]*\]\([^)]+\)"#, ""),
        (#"\[([^\]]+)\]\([^)]+\)"#, "$1"),
        (#"(?m)^#{1,6}\s+"#, ""),
        (#"[>*_~`]"#, ""),
        (#"(?m)^\s*[-+]\s+"#, ""),
        (#"\s+"#, " ")
    ] {
        text = text.replacingOccurrences(
            of: pattern,
            with: replacement,
            options: .regularExpression
        )
    }
    return text.trimmingCharacters(in: .whitespacesAndNewlines)
}

public let defaultProcessingCommand =
    "codex exec --ephemeral --ignore-user-config --sandbox read-only " +
    "--skip-git-repo-check --color never -"
public let defaultProcessingPrompt = """
Summarize one captured source for a private knowledge library.
Always write both summaries in English, regardless of the language of the source.
Return only valid JSON matching the required schema.
summaries.detailed: Provide a clear, thorough summary that preserves the source’s most important information and nuance. Include names, dates, and figures only when they are important for understanding.
summaries.concise: Condense the detailed summary into its essential ideas without introducing new information.
Write for both reading and listening. Use natural language, short paragraphs, clear headings, and smooth transitions. Avoid tables, footnotes, citation markers, raw URLs, and unexplained abbreviations.
short_filename: Use 2–6 lowercase words in kebab case, without a file extension.
topic_name: Reuse the most suitable existing topic or create a reusable topic name of 2–4 words.
Existing topics:
{{topics}}
Source:
{{source}}
"""

public struct ProcessingSuggestion: Codable, Equatable, Sendable {
    public struct Summaries: Codable, Equatable, Sendable {
        public var concise: String
        public var detailed: String

        public init(
            concise: String,
            detailed: String
        ) {
            self.concise = concise
            self.detailed = detailed
        }

        fileprivate func text(for variant: LibraryVariant) -> String? {
            switch variant {
            case .concise: concise
            case .detailed: detailed
            case .source: nil
            }
        }
    }

    public var shortFilename: String
    public var topicName: String
    public var summaries: Summaries

    public init(
        shortFilename: String,
        topicName: String,
        summaries: Summaries
    ) {
        self.shortFilename = shortFilename
        self.topicName = topicName
        self.summaries = summaries
    }

    public static func decode(_ output: String) throws -> Self {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        let payload = regexCapture(
            trimmed,
            pattern: #"^```(?:json)?\s*([\s\S]*?)\s*```$"#
        ) ?? trimmed
        guard let data = payload.data(using: .utf8) else {
            throw LibraryError.invalidProcessingOutput
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let value = try? decoder.decode(Self.self, from: data) else {
            throw LibraryError.invalidProcessingOutput
        }
        let summaries = [
            value.summaries.concise,
            value.summaries.detailed
        ]
        guard
            !value.shortFilename.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            !value.topicName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            summaries.allSatisfy({
                !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            })
        else {
            throw LibraryError.invalidProcessingOutput
        }
        return value
    }
}

public func runProcessingCommand(
    _ command: String,
    prompt: String,
    timeout: TimeInterval = 300
) async throws -> String {
    #if os(macOS)
    let normalized = command.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty, normalized.count <= 4_000 else {
        throw LibraryError.invalidProcessingCommand
    }
    let fileManager = FileManager.default
    let directory = fileManager.temporaryDirectory.appending(
        path: "briefly-process-\(UUID().uuidString)",
        directoryHint: .isDirectory
    )
    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: directory) }
    let outputURL = directory.appending(path: "stdout")
    let errorURL = directory.appending(path: "stderr")
    guard
        fileManager.createFile(atPath: outputURL.path, contents: nil),
        fileManager.createFile(atPath: errorURL.path, contents: nil)
    else {
        throw LibraryError.processingFailed("Briefly could not prepare AI output files.")
    }
    let outputHandle = try FileHandle(forWritingTo: outputURL)
    let errorHandle = try FileHandle(forWritingTo: errorURL)
    defer {
        try? outputHandle.close()
        try? errorHandle.close()
    }
    let input = Pipe()
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/zsh")
    process.arguments = ["-lc", normalized]
    process.currentDirectoryURL = directory
    process.standardInput = input
    process.standardOutput = outputHandle
    process.standardError = errorHandle
    var environment = ProcessInfo.processInfo.environment
    let userHomePath = environment["HOME"] ?? environment["USERPROFILE"] ?? ""
    let additions = [
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "/usr/bin",
        "/bin",
        userHomePath.isEmpty ? "" : "\(userHomePath)/.local/bin",
        userHomePath.isEmpty ? "" : "\(userHomePath)/.npm-global/bin"
    ].filter { !$0.isEmpty }
    let existing = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
    environment["PATH"] = NSOrderedSet(array: existing + additions).array
        .compactMap { $0 as? String }
        .joined(separator: ":")
    process.environment = environment

    let stop = try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<ProcessingStop, Error>) in
        let state = ProcessingProcessState()
        let monitor = DispatchSource.makeTimerSource(queue: .global())
        process.terminationHandler = { _ in
            monitor.cancel()
            if let reason = state.finish() {
                continuation.resume(returning: reason)
            }
        }
        do {
            try process.run()
        } catch {
            monitor.cancel()
            _ = state.finish()
            continuation.resume(throwing: error)
            return
        }
        monitor.schedule(deadline: .now() + 0.25, repeating: 0.25)
        monitor.setEventHandler {
            let size = (try? fileSize(outputURL)) ?? 0
            if size > 10_000_000, state.request(.outputTooLarge) {
                process.terminate()
            }
        }
        monitor.resume()
        do {
            try input.fileHandleForWriting.write(contentsOf: Data(prompt.utf8))
            try input.fileHandleForWriting.close()
        } catch {
            if state.request(.inputFailed(error.localizedDescription)) {
                process.terminate()
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
            if process.isRunning, state.request(.timedOut) {
                process.terminate()
                DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                    if process.isRunning {
                        Darwin.kill(process.processIdentifier, SIGKILL)
                    }
                }
            }
        }
    }
    try? outputHandle.close()
    try? errorHandle.close()
    switch stop {
    case .finished:
        break
    case .timedOut:
        throw LibraryError.processingTimedOut
    case .outputTooLarge:
        throw LibraryError.processingOutputTooLarge
    case .inputFailed(let message):
        throw LibraryError.processingFailed(message)
    }
    let outputSize = try fileSize(outputURL)
    guard outputSize <= 10_000_000 else {
        throw LibraryError.processingOutputTooLarge
    }
    let output = try String(contentsOf: outputURL, encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard process.terminationStatus == 0 else {
        throw LibraryError.processingFailed(
            try conciseProcessError(errorURL)
        )
    }
    guard !output.isEmpty else {
        throw LibraryError.processingFailed(
            "The AI command returned no output."
        )
    }
    return output
    #else
    throw LibraryError.processingUnavailable
    #endif
}

#if os(macOS)
private enum ProcessingStop {
    case finished
    case timedOut
    case outputTooLarge
    case inputFailed(String)
}

private final class ProcessingProcessState: @unchecked Sendable {
    private let lock = NSLock()
    private var reason = ProcessingStop.finished
    private var didFinish = false

    func request(_ value: ProcessingStop) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !didFinish else { return false }
        reason = value
        return true
    }

    func finish() -> ProcessingStop? {
        lock.lock()
        defer { lock.unlock() }
        guard !didFinish else { return nil }
        didFinish = true
        return reason
    }
}

private func fileSize(_ url: URL) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    return (attributes[.size] as? NSNumber)?.intValue ?? 0
}

private func conciseProcessError(_ url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    let size = try fileSize(url)
    if size > 100_000 {
        try handle.seek(toOffset: UInt64(size - 100_000))
    }
    let data = try handle.readToEnd() ?? Data()
    let lines = String(decoding: data, as: UTF8.self)
        .components(separatedBy: .newlines)
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
    let message = lines.last?
        .replacingOccurrences(of: #"^ERROR:\s*"#, with: "", options: .regularExpression) ??
        "The AI command could not process this capture."
    return message.count > 320
        ? "\(message.prefix(319).trimmingCharacters(in: .whitespaces))…"
        : message
}
#endif

private struct VoiceBriefWatcherState: Codable {
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

struct DiscoveredChannel {
    struct Item {
        var id: String
        var title: String
        var url: String
        var publishedAt: String? = nil
        var content: String? = nil
        var linkedURL: String? = nil
        var preferredInput: ItemInputID? = nil
        var mediaURL: String? = nil
        var transcriptURL: String? = nil
        var transcriptType: String? = nil
        var transcriptLanguage: String? = nil
    }

    var title: String
    var kind: LibraryChannelKind
    var items: [Item]
}

public actor SQLiteLibraryStore {
    public let databaseURL: URL
    private let fileManager = FileManager.default
    private var sqliteLibrary: SQLiteLibrary?

    public init(databaseURL: URL) {
        self.databaseURL = databaseURL.standardizedFileURL
    }

    private func database() throws -> SQLiteLibrary {
        if let sqliteLibrary { return sqliteLibrary }
        let database = try SQLiteLibrary(databaseURL: databaseURL)
        try database.trashDocumentsFromDeletedChannels()
        sqliteLibrary = database
        return database
    }

    public func documentDatabase() throws -> SQLiteLibrary { try database() }

    public func loadProjection(includeDeleted: Bool = false) throws -> LibraryProjection {
        let database = try database()
        let (topicNames, attachmentsByDocument, channelSourcesByDocument) =
            try projectionResources(database)
        let entries = projectEntries(
            try database.allDocuments(includeDeleted: includeDeleted),
            topicNames: topicNames,
            attachmentsByDocument: attachmentsByDocument,
            channelSourcesByDocument: channelSourcesByDocument
        )
        return LibraryProjection(
            schemaVersion: librarySchemaVersion,
            generatedAt: Date().iso8601,
            files: [],
            entries: entries,
            voiceBriefs: try readVoiceBriefs()
        )
    }

    public func loadLibraryIndex(includeDeleted: Bool = false) throws -> LibraryProjection {
        let database = try database()
        let (topicNames, attachmentsByDocument, channelSourcesByDocument) =
            try projectionResources(database)
        let entries = projectIndexEntries(
            try database.documentIndex(includeDeleted: includeDeleted),
            topicNames: topicNames,
            attachmentsByDocument: attachmentsByDocument,
            channelSourcesByDocument: channelSourcesByDocument
        )
        return LibraryProjection(
            schemaVersion: librarySchemaVersion,
            generatedAt: Date().iso8601,
            files: [],
            entries: entries,
            voiceBriefs: try readVoiceBriefs()
        )
    }

    public func loadTrash() throws -> [LibraryEntry] {
        let database = try database()
        let (topicNames, attachmentsByDocument, channelSourcesByDocument) =
            try projectionResources(database)
        return projectEntries(
            try database.deletedDocuments(),
            topicNames: topicNames,
            attachmentsByDocument: attachmentsByDocument,
            channelSourcesByDocument: channelSourcesByDocument
        )
    }

    public func loadTrashIndex() throws -> [LibraryEntry] {
        let database = try database()
        let (topicNames, attachmentsByDocument, channelSourcesByDocument) =
            try projectionResources(database)
        return projectIndexEntries(
            try database.deletedDocumentIndex(),
            topicNames: topicNames,
            attachmentsByDocument: attachmentsByDocument,
            channelSourcesByDocument: channelSourcesByDocument
        )
    }

    private func projectionResources(
        _ database: SQLiteLibrary
    ) throws -> (
        [String: String],
        [String: [SQLiteAttachmentMetadata]],
        [String: [String]]
    ) {
        let topicNames = Dictionary(uniqueKeysWithValues: try database.topicDefinitions().map {
            ($0.id, $0.title)
        })
        let attachments = Dictionary(
            grouping: try database.attachmentMetadata(),
            by: \.documentID
        )
        return (topicNames, attachments, try database.documentChannelSources())
    }

    private func projectEntries(
        _ documents: [SQLiteDocument],
        topicNames: [String: String],
        attachmentsByDocument: [String: [SQLiteAttachmentMetadata]],
        channelSourcesByDocument: [String: [String]]
    ) -> [LibraryEntry] {
        documents.map { document in
            let references: [LibraryText] = LibraryVariant.allCases.compactMap { variant in
                guard let text = document.texts[variant] else { return nil }
                return LibraryText(variant: variant, text: text)
            }
            let excerptBody = references.first {
                $0.variant == .concise || $0.variant == .detailed
            }?.text ?? document.texts[.source] ?? ""
            return projectEntry(
                document,
                references: references,
                excerptText: libraryExcerpt(excerptBody),
                topicNames: topicNames,
                attachments: attachmentsByDocument[document.id] ?? [],
                channelSources: channelSourcesByDocument[document.id] ?? []
            )
        }
    }

    private func projectIndexEntries(
        _ entries: [SQLiteDocumentIndex],
        topicNames: [String: String],
        attachmentsByDocument: [String: [SQLiteAttachmentMetadata]],
        channelSourcesByDocument: [String: [String]]
    ) -> [LibraryEntry] {
        entries.map { entry in
            let variants = Set(entry.variants)
            let references = LibraryVariant.allCases.compactMap { variant in
                variants.contains(variant) ? LibraryText(variant: variant) : nil
            }
            return projectEntry(
                entry.document,
                references: references,
                excerptText: entry.excerpt,
                topicNames: topicNames,
                attachments: attachmentsByDocument[entry.document.id] ?? [],
                channelSources: channelSourcesByDocument[entry.document.id] ?? []
            )
        }
    }

    private func projectEntry(
        _ document: SQLiteDocument,
        references: [LibraryText],
        excerptText: String,
        topicNames: [String: String],
        attachments: [SQLiteAttachmentMetadata],
        channelSources: [String]
    ) -> LibraryEntry {
        let audio = attachments.contains { $0.kind == "audio" }
        let favicon = attachments.first { $0.kind == "favicon" }
        return LibraryEntry(
            id: document.id,
            captureID: document.captureID,
            entryType: document.type,
            voiceBriefID: document.voiceBriefID,
            title: document.title,
            excerpt: excerptText,
            topicIDs: document.topicIDs,
            topicNames: document.topicIDs.map {
                topicNames[$0] ?? titleize($0)
            },
            tags: document.tags,
            sourceURL: document.sourceURL,
            mediaURL: document.mediaURL,
            faviconFile: favicon.map {
                "\(document.captureID).\(fileExtension(for: $0.mimeType))"
            },
            audio: nil,
            favicon: nil,
            sourceIDs: document.sourceIDs,
            sourceURLs: document.sourceURLs,
            channelSources: channelSources,
            hasAudio: audio,
            createdAt: document.createdAt.iso8601,
            updatedAt: document.updatedAt.iso8601,
            reviewedAt: nil,
            origin: .personal,
            sharedByUsername: nil,
            sharedByDisplayName: nil,
            inboxReferenceID: nil,
            texts: references
        )
    }

    @discardableResult
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

    public func attachAudio(entryID: String, file source: URL) throws {
        let fileExtension = source.pathExtension.lowercased()
        guard ["m4a", "wav"].contains(fileExtension) else {
            throw LibraryError.invalidAudio
        }
        let data = try Data(contentsOf: source, options: .mappedIfSafe)
        guard !data.isEmpty, data.count <= 100_000_000 else {
            throw LibraryError.invalidAudio
        }
        _ = try database().getDocument(entryID)
        try database().saveAttachment(
            documentID: entryID,
            kind: "audio",
            mimeType: fileExtension == "m4a" ? "audio/mp4" : "audio/wav",
            data: data
        )
    }

    public func enqueueProcessingJob(
        entryID: String,
        selectWhenFinished: Bool
    ) throws {
        _ = try database().getDocument(entryID)
        try database().enqueueProcessingJob(
            documentID: entryID,
            selectWhenFinished: selectWhenFinished
        )
    }

    public func claimNextProcessingJob() throws -> SQLiteProcessingJob? {
        try database().claimNextProcessingJob()
    }

    public func completeProcessingJob(entryID: String) throws {
        try database().completeProcessingJob(documentID: entryID)
    }

    public func failProcessingJob(entryID: String, error: String) throws {
        try database().failProcessingJob(documentID: entryID, error: error)
    }

    public func processingPrompt(
        entryID: String,
        template: String = defaultProcessingPrompt
    ) throws -> String {
        let normalized = template.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            normalized.contains("{{topics}}"),
            normalized.contains("{{source}}")
        else {
            throw LibraryError.invalidProcessingPrompt
        }
        let englishInstruction =
            "Always write both summaries in English, regardless of the language of the source."
        let enforcedTemplate = normalized.contains(englishInstruction)
            ? normalized
            : englishInstruction + "\n" + normalized
        let document = try database().getDocument(entryID)
        var source: [String: Any] = [
            "title": document.title,
            "source_text": document.texts[.source] ?? ""
        ]
        if let sourceURL = document.sourceURL {
            source["source_url"] = sourceURL
        }
        let topics = try database().topicDefinitions().map(\.title).sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
        return enforcedTemplate
            .replacingOccurrences(
                of: "{{topics}}",
                with: try json(topics)
            )
            .replacingOccurrences(
                of: "{{source}}",
                with: try json(source)
            )
    }

    @discardableResult
    public func applyProcessingSuggestion(
        entryID: String,
        suggestion: ProcessingSuggestion
    ) throws -> String {
        let document = try database().getDocument(entryID)
        let topicID = try ensureTopic(named: suggestion.topicName)
        let requestedBase = slug(suggestion.shortFilename)
        var texts = [LibraryVariant: String]()
        for variant in [LibraryVariant.concise, .detailed] {
            guard
                let summary = suggestion.summaries.text(for: variant)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                !summary.isEmpty
            else {
                throw LibraryError.invalidProcessingOutput
            }
            texts[variant] = summary
        }
        try database().commitDocument(SQLiteDocumentCommit(
            id: entryID,
            baseRevision: document.revision,
            title: firstHeading(document.texts[.source] ?? "") ??
                requestedBase.replacingOccurrences(of: "-", with: " ").capitalized,
            topicIDs: [topicID],
            texts: texts
        ))
        return entryID
    }

    private func saveCapture(
        title: String,
        content: String,
        sourceURL: URL?,
        mediaURL: URL? = nil,
        entryType: String,
        faviconData: Data? = nil,
        faviconFileExtension: String? = nil,
        audioData: Data? = nil,
        audioMimeType: String? = nil
    ) throws -> String {
        // Media remains an immutable attachment concern; the Markdown record itself is
        // committed once, locally, with its CloudKit outbox entry in the same transaction.
        let database = try database()
        let document = try database.createDocument(
            title: title,
            body: content,
            type: entryType,
            sourceURL: sourceURL?.absoluteString,
            mediaURL: mediaURL?.absoluteString
        )
        try saveDraftAttachments(
            ItemDraft(
                inputID: .text,
                title: title,
                content: content,
                faviconData: faviconData,
                faviconFileExtension: faviconFileExtension,
                audioData: audioData,
                audioMimeType: audioMimeType
            ),
            documentID: document.id,
            database: database
        )
        return document.id
    }

    private func saveDraftAttachments(
        _ draft: ItemDraft,
        documentID: String,
        database: SQLiteLibrary
    ) throws {
        if let data = draft.faviconData,
           let ext = draft.faviconFileExtension?.lowercased(),
           data.count <= 1_000_000, validFavicon(data, fileExtension: ext) {
            try database.saveAttachment(
                documentID: documentID,
                kind: "favicon",
                mimeType: ext == "svg" ? "image/svg+xml" : ext == "jpg" ? "image/jpeg" : "image/\(ext)",
                data: data
            )
        }
        if let data = draft.audioData, !data.isEmpty, data.count <= 100_000_000,
           let mime = draft.audioMimeType, mime.lowercased().hasPrefix("audio/") {
            try database.saveAttachment(
                documentID: documentID,
                kind: "audio",
                mimeType: mime,
                data: data
            )
        }
    }

    public func writeText(
        entryID: String,
        variant: LibraryVariant,
        text: String
    ) throws {
        let document = try database().getDocument(entryID)
        guard document.texts[variant] != nil else {
            throw LibraryError.missingVariant
        }
        try database().commitDocument(SQLiteDocumentCommit(
            id: entryID,
            baseRevision: document.revision,
            texts: [variant: text]
        ))
    }

    public func search(_ query: String, limit: Int = 50) throws -> [SQLiteSearchResult] {
        try database().search(query, limit: limit)
    }

    public func getDocument(
        _ id: String,
        includeDeleted: Bool = false
    ) throws -> SQLiteDocument {
        try database().getDocument(id, includeDeleted: includeDeleted)
    }

    @discardableResult
    public func commitDocument(
        _ id: String,
        baseRevision: Int64,
        texts: [LibraryVariant: String],
        title: String? = nil
    ) throws -> SQLiteDocument {
        try database().commitDocument(SQLiteDocumentCommit(
            id: id,
            baseRevision: baseRevision,
            title: title,
            texts: texts
        ))
    }

    @discardableResult
    public func batch(_ commits: [SQLiteDocumentCommit]) throws -> [SQLiteDocument] {
        try database().batch(commits)
    }

    @discardableResult
    public func ingestMarkdownLibrary(from root: URL) throws -> Int {
        let database = try database()
        let topics = try readTopics(from: root).map {
            LibraryTopicDefinition(id: $0.key, title: $0.value)
        }
        if !topics.isEmpty { try database.replaceTopicDefinitions(topics) }
        let imported = try database.ingestMarkdownLibrary(root)
        let voiceBriefDirectory = root.appending(path: "voice-briefs", directoryHint: .isDirectory)
        if let urls = try? fileManager.contentsOfDirectory(
            at: voiceBriefDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) {
            for url in urls where
                url.pathExtension.lowercased() == "md" &&
                url.deletingPathExtension().lastPathComponent.lowercased() != "readme"
            {
                let parsed = parseMarkdown(try String(contentsOf: url, encoding: .utf8))
                _ = try database.saveVoiceBrief(LibraryVoiceBriefDraft(
                    id: parsed.scalar("id") ?? "file:\(url.lastPathComponent)",
                    title: parsed.scalar("name") ?? parsed.scalar("title") ??
                        url.deletingPathExtension().lastPathComponent,
                    schedule: parsed.scalar("schedule") ?? "manual",
                    length: parsed.scalar("length") ?? "",
                    sources: parsed.array("sources"),
                    prioritizeForMe: parsed.scalar("prioritize_for_me")?.lowercased() == "true"
                ))
            }
        }
        if
            let data = try? Data(contentsOf: channelStateURL(for: root)),
            let state = try? JSONDecoder().decode(VoiceBriefWatcherState.self, from: data),
            state.schemaVersion == 1
        {
            try writeChannelState(state)
        }
        return imported
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

    public func audioURL(entryID: String) throws -> URL? {
        try attachmentURL(entryID: entryID, kind: "audio")
    }

    public func faviconURL(entryID: String) throws -> URL? {
        try attachmentURL(entryID: entryID, kind: "favicon")
    }

    private func attachmentURL(entryID: String, kind: String) throws -> URL? {
        guard let (mime, data) = try database().attachment(documentID: entryID, kind: kind) else {
            return nil
        }
        let directory = fileManager.temporaryDirectory
            .appending(path: "briefly-attachments", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "\(slug(entryID))-\(kind).\(fileExtension(for: mime))")
        try data.write(to: url, options: .atomic)
        return url
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

    private func readTopics(from root: URL) throws -> [String: String] {
        let url = root.appending(path: "topics.md")
        guard fileManager.fileExists(atPath: url.path) else { return [:] }
        let lines = try String(contentsOf: url, encoding: .utf8)
            .components(separatedBy: .newlines)
        var currentID: String?
        var result = [String: String]()
        for line in lines {
            if let value = regexCapture(line, pattern: #"^\s*-\s+id:\s*(.+?)\s*$"#) {
                currentID = unquote(value)
            } else if
                let id = currentID,
                let value = regexCapture(line, pattern: #"^\s+title:\s*(.+?)\s*$"#)
            {
                result[id] = unquote(value)
                currentID = nil
            }
        }
        return result
    }

    private func ensureTopic(named value: String) throws -> String {
        let title = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        guard !title.isEmpty, title.count <= 48 else {
            throw LibraryError.invalidTopic
        }
        var topics = try database().topicDefinitions()
        if let existing = topics.first(where: {
            $0.title.localizedCaseInsensitiveCompare(title) == .orderedSame
        }) {
            return existing.id
        }
        let base = slug(title)
        var id = base
        var suffix = 2
        while topics.contains(where: { $0.id == id }) {
            id = "\(base)-\(suffix)"
            suffix += 1
        }
        topics.append(LibraryTopicDefinition(id: id, title: title))
        try database().replaceTopicDefinitions(topics)
        return id
    }

    private func readVoiceBriefs() throws -> [LibraryVoiceBrief] {
        try database().voiceBriefs()
    }

    private func saveVoiceBriefEpisode(
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
        let sourceList = sources.map {
            "- [\($0.title)](\($0.url))"
        }.joined(separator: "\n")
        let texts = scripts.mapValues { script in
            """
            \(script.trimmingCharacters(in: .whitespacesAndNewlines))

            ## Sources

            \(sourceList)
            """
        }
        return try database().createDocument(
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

    private func mergeChannel(
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

    private func repairChannelState(_ current: inout VoiceBriefWatcherState.Source) throws {
        let missing = Set(current.items.compactMap { item in
            (try? database().getDocument(item.entryID)) == nil ? item.id : nil
        })
        guard !missing.isEmpty else { return }
        current.items.removeAll { missing.contains($0.id) }
        current.seen.removeAll { missing.contains($0) }
    }

    private func readChannelState() -> VoiceBriefWatcherState {
        guard let database = try? database() else { return .empty }
        let sources = (try? database.channelRecords()) ?? []
        let runs = (try? database.voiceBriefRunStates()) ?? []
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

    private func writeChannelState(_ state: VoiceBriefWatcherState) throws {
        let database = try database()
        try database.saveChannelRecords(state.sources.map { source, value in
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
        try database.saveVoiceBriefRunStates(state.voiceBriefs.map { id, value in
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

    private func channelStateURL(for root: URL) -> URL {
        root
            .appending(path: ".shared-library", directoryHint: .isDirectory)
            .appending(path: "voice-brief-state.json")
    }

    private func buildChannels(
        from state: VoiceBriefWatcherState
    ) throws -> [LibraryChannel] {
        let definitions = try readVoiceBriefs()
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
        .sorted {
            $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
    }

}

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

struct ParsedMarkdown {
    var metadata: [String: [String]]
    var frontmatter: String?
    var body: String

    func scalar(_ key: String) -> String? {
        metadata[key]?.first.flatMap { $0.isEmpty ? nil : $0 }
    }

    func array(_ key: String) -> [String] {
        metadata[key] ?? []
    }
}

func parseMarkdown(_ text: String) -> ParsedMarkdown {
    guard text.hasPrefix("---\n") || text.hasPrefix("---\r\n") else {
        return ParsedMarkdown(metadata: [:], frontmatter: nil, body: text)
    }
    let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
    guard
        let end = normalized.range(
            of: "\n---",
            range: normalized.index(normalized.startIndex, offsetBy: 4)..<normalized.endIndex
        )
    else {
        return ParsedMarkdown(metadata: [:], frontmatter: nil, body: text)
    }
    let metadataText = String(
        normalized[normalized.index(normalized.startIndex, offsetBy: 4)..<end.lowerBound]
    )
    let endIndex = normalized.index(end.lowerBound, offsetBy: 4)
    var body = String(normalized[endIndex...])
    body = body.trimmingCharacters(in: .whitespacesAndNewlines)
    var metadata = [String: [String]]()
    var activeList: String?
    for line in metadataText.components(separatedBy: "\n") {
        if
            let colon = line.firstIndex(of: ":"),
            !line[..<colon].contains(where: \.isWhitespace)
        {
            let key = String(line[..<colon])
            let value = String(line[line.index(after: colon)...])
                .trimmingCharacters(in: .whitespaces)
            metadata[key] = parseValues(value)
            activeList = value.isEmpty ? key : nil
        } else if
            let activeList,
            let value = regexCapture(line, pattern: #"^\s+-\s*(.*?)\s*$"#)
        {
            metadata[activeList, default: []].append(unquote(value))
        }
    }
    return ParsedMarkdown(
        metadata: metadata,
        frontmatter: String(normalized[..<endIndex]),
        body: body
    )
}

private func parseValues(_ value: String) -> [String] {
    let trimmed = value.trimmingCharacters(in: .whitespaces)
    if trimmed.isEmpty || trimmed == "[]" { return [] }
    if
        trimmed.hasPrefix("["),
        let data = trimmed.data(using: .utf8),
        let decoded = try? JSONDecoder().decode([String].self, from: data)
    {
        return decoded
    }
    return [unquote(trimmed)]
}

private func regexCapture(_ value: String, pattern: String) -> String? {
    guard
        let expression = try? NSRegularExpression(pattern: pattern),
        let match = expression.firstMatch(
            in: value,
            range: NSRange(value.startIndex..., in: value)
        ),
        let range = Range(match.range(at: 1), in: value)
    else {
        return nil
    }
    return String(value[range])
}

private func unquote(_ value: String) -> String {
    let trimmed = value.trimmingCharacters(in: .whitespaces)
    if
        trimmed.hasPrefix("\""),
        let data = trimmed.data(using: .utf8),
        let decoded = try? JSONDecoder().decode(String.self, from: data)
    {
        return decoded
    }
    return trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "'"))
}

private func quoted(_ value: String) -> String {
    let data = try? JSONEncoder().encode(value)
    return data.flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
}

private func json(_ value: Any) throws -> String {
    let data = try JSONSerialization.data(
        withJSONObject: value,
        options: [.prettyPrinted, .sortedKeys]
    )
    guard let text = String(data: data, encoding: .utf8) else {
        throw LibraryError.invalidProcessingPrompt
    }
    return text
}

private func serializeMetadata(_ metadata: [String: [String]]) -> String {
    let arrays: Set<String> = [
        "tags",
        "topics",
        "source_ids",
        "source_urls"
    ]
    let preferred = [
        "id",
        "type",
        "title",
        "created_at",
        "updated_at",
        "tags",
        "topics",
        "source_url",
        "media_url",
        "audio_path",
        "voice_brief_id",
        "voice_brief_title",
        "source_ids",
        "source_urls"
    ]
    let keys = preferred.filter { metadata[$0] != nil } +
        metadata.keys.filter { !preferred.contains($0) }.sorted()
    let lines = keys.flatMap { key -> [String] in
        let values = metadata[key] ?? []
        if arrays.contains(key) || values.count != 1 {
            return values.isEmpty
                ? ["\(key): []"]
                : ["\(key):"] + values.map { "  - \(quoted($0))" }
        }
        return ["\(key): \(quoted(values[0]))"]
    }
    return (["---"] + lines + ["---"]).joined(separator: "\n")
}

private func writeAtomically(_ text: String, to url: URL) throws {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try Data(text.utf8).write(to: url, options: .atomic)
}

func firstHeading(_ text: String) -> String? {
    text.components(separatedBy: .newlines)
        .first { $0.hasPrefix("# ") }
        .map { String($0.dropFirst(2)).trimmingCharacters(in: .whitespaces) }
}

private func fileExtension(for mimeType: String) -> String {
    switch mimeType {
    case "image/svg+xml": "svg"
    case "image/jpeg": "jpg"
    case "audio/mp4": "m4a"
    default: mimeType.split(separator: "/").last.map(String.init) ?? "bin"
    }
}

private func firstUsefulLine(_ text: String) -> String {
    text.components(separatedBy: .newlines)
        .map {
            String(
                $0.trimmingCharacters(in: .whitespaces)
                    .drop(while: { $0 == "#" })
            )
            .trimmingCharacters(in: .whitespaces)
        }
        .first(where: { !$0.isEmpty })
        .map { String($0.prefix(80)) } ?? "Clipboard capture"
}

private func httpURL(_ value: String) -> URL? {
    guard
        !value.contains(where: \.isWhitespace),
        let url = URL(string: value),
        url.scheme == "http" || url.scheme == "https",
        url.host != nil,
        url.user == nil,
        url.password == nil
    else {
        return nil
    }
    return url
}

func libraryExcerpt(_ text: String) -> String {
    // The result is at most 240 characters; do not run every regex over a full document.
    var result = String(text.prefix(4_096))
    for (pattern, replacement) in [
        (#"```[\s\S]*?```"#, " "),
        (#"!\[[^\]]*\]\([^)]+\)"#, " "),
        (#"\[([^\]]+)\]\([^)]+\)"#, "$1"),
        (#"[#>*_~`-]"#, " "),
        (#"\s+"#, " ")
    ] {
        result = result.replacingOccurrences(
            of: pattern,
            with: replacement,
            options: .regularExpression
        )
    }
    result = result.trimmingCharacters(in: .whitespacesAndNewlines)
    return result.count > 240 ? "\(result.prefix(237).trimmingCharacters(in: .whitespaces))…" : result
}

private func slug(_ value: String) -> String {
    let folded = value.folding(
        options: [.diacriticInsensitive, .caseInsensitive],
        locale: .current
    )
    let components = folded.components(separatedBy: CharacterSet.alphanumerics.inverted)
    let value = components.filter { !$0.isEmpty }.joined(separator: "-").lowercased()
    return String(value.prefix(64)).isEmpty ? "capture" : String(value.prefix(64))
}

private func titleize(_ value: String) -> String {
    value.replacingOccurrences(of: "-", with: " ")
        .replacingOccurrences(of: "_", with: " ")
        .capitalized
}

private func normalizedChannelSource(_ value: String) throws -> String {
    let source = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard
        !source.isEmpty,
        source.count <= 2_048,
        validChannelSource(source)
    else {
        throw LibraryError.invalidChannel
    }
    return source
}

private func voiceBriefItemKey(_ source: String, _ itemID: String) -> String {
    "\(source)\n\(itemID)"
}

private func channelDisplayTitle(_ source: String) -> String {
    guard let url = URL(string: source) else { return source }
    let path = url.path
        .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        .replacingOccurrences(of: "/", with: " · ")
    return path.isEmpty
        ? url.host?.replacingOccurrences(of: "www.", with: "") ?? source
        : path
}

private func discoverChannel(
    _ source: String,
    maximumItems: Int
) async throws -> DiscoveredChannel {
    guard let url = httpURL(source) else { throw LibraryError.invalidChannel }
    let requestURL: URL
    if
        url.host?.lowercased().hasSuffix("reddit.com") == true,
        url.path.range(of: #"/r/[^/]+/?$"#, options: .regularExpression) != nil
    {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.path = url.path.trimmingCharacters(
            in: CharacterSet(charactersIn: "/")
        ) + "/.rss"
        components.path = "/" + components.path
        components.queryItems = [URLQueryItem(
            name: "limit",
            value: String(maximumItems)
        )]
        requestURL = components.url!
    } else {
        requestURL = url
    }

    if let feedURL = youtubeFeedURL(in: "", relativeTo: requestURL) {
        let (feedData, _) = try await fetchChannelURL(feedURL)
        return limitedChannel(
            try parseFeed(
                feedData,
                fallbackTitle: channelDisplayTitle(source),
                baseURL: feedURL
            ),
            maximumItems: maximumItems
        )
    }

    let (data, response) = try await fetchChannelURL(requestURL)
    let finalURL = response.url ?? requestURL
    if looksLikeFeed(data: data, response: response) {
        return limitedChannel(
            try parseFeed(
                data,
                fallbackTitle: channelDisplayTitle(source),
                baseURL: finalURL
            ),
            maximumItems: maximumItems
        )
    }
    let html = String(decoding: data, as: UTF8.self)
    if let hackerNews = parseHackerNews(
        html,
        sourceURL: finalURL,
        maximumItems: maximumItems
    ) {
        return hackerNews
    }
    let feedURLs = [
        youtubeFeedURL(in: html, relativeTo: finalURL),
        await applePodcastFeedURL(for: finalURL),
        discoveredFeedURL(in: html, relativeTo: finalURL)
    ].compactMap { $0 }
    for feedURL in NSOrderedSet(array: feedURLs).array.compactMap({ $0 as? URL }) {
        do {
            let (feedData, _) = try await fetchChannelURL(feedURL)
            return limitedChannel(
                try parseFeed(
                    feedData,
                    fallbackTitle: channelDisplayTitle(source),
                    baseURL: feedURL
                ),
                maximumItems: maximumItems
            )
        } catch {
            continue
        }
    }
    let title = regexCapture(
        html,
        pattern: #"(?is)<title[^>]*>\s*(.*?)\s*</title>"#
    ).map(decodeHTML) ?? channelDisplayTitle(source)
    let content = stripHTML(html)
    guard !content.isEmpty else {
        throw LibraryError.channelFailed(
            "The channel did not contain a feed or readable page."
        )
    }
    return DiscoveredChannel(
        title: title,
        kind: .page,
        items: [.init(
            id: finalURL.absoluteString,
            title: title,
            url: finalURL.absoluteString,
            content: content
        )]
    )
}

private func limitedChannel(
    _ channel: DiscoveredChannel,
    maximumItems: Int
) -> DiscoveredChannel {
    var channel = channel
    channel.items = channel.items.enumerated()
        .map { (item: $0.element, index: $0.offset, date: channelDate($0.element.publishedAt)) }
        .sorted {
            if let left = $0.date, let right = $1.date { return left > right }
            return $0.index < $1.index
        }
        .prefix(maximumItems)
        .map(\.item)
    return channel
}

private func channelDate(_ value: String?) -> Date? {
    guard let value else { return nil }
    if let date = ISO8601DateFormatter().date(from: value) { return date }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    for format in ["EEE, dd MMM yyyy HH:mm:ss Z", "EEE, dd MMM yyyy HH:mm Z"] {
        formatter.dateFormat = format
        if let date = formatter.date(from: value) { return date }
    }
    return nil
}

private func fetchChannelURL(_ url: URL) async throws -> (Data, HTTPURLResponse) {
    var request = URLRequest(url: url, timeoutInterval: 30)
    request.setValue(
        "application/atom+xml, application/rss+xml, application/xml, text/html;q=0.9",
        forHTTPHeaderField: "Accept"
    )
    request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
    request.setValue(
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) " +
            "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/123.0 Safari/537.36",
        forHTTPHeaderField: "User-Agent"
    )
    let (data, response) = try await URLSession.shared.data(for: request)
    guard
        let response = response as? HTTPURLResponse,
        (200..<300).contains(response.statusCode)
    else {
        throw LibraryError.channelFailed("The channel returned an invalid response.")
    }
    guard data.count <= 12_000_000 else {
        throw LibraryError.channelFailed("The channel response is larger than 12 MB.")
    }
    return (data, response)
}

private func looksLikeFeed(data: Data, response: HTTPURLResponse) -> Bool {
    let contentType = response.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
    if contentType.contains("rss") ||
        contentType.contains("atom") ||
        contentType.contains("xml") {
        return true
    }
    let prefix = String(decoding: data.prefix(1_000), as: UTF8.self).lowercased()
    return prefix.contains("<rss") ||
        prefix.contains("<feed") ||
        prefix.contains("<rdf:rdf")
}

private func discoveredFeedURL(in html: String, relativeTo base: URL) -> URL? {
    guard let expression = try? NSRegularExpression(pattern: #"(?is)<link\b[^>]*>"#) else {
        return nil
    }
    for match in expression.matches(
        in: html,
        range: NSRange(html.startIndex..., in: html)
    ) {
        guard let range = Range(match.range, in: html) else { continue }
        let tag = String(html[range])
        let type = htmlAttribute("type", in: tag).lowercased()
        guard type.contains("rss") || type.contains("atom") else { continue }
        if
            let href = htmlAttribute("href", in: tag).nilIfEmpty,
            let url = URL(string: decodeHTML(href), relativeTo: base)?.absoluteURL,
            url.scheme == "http" || url.scheme == "https"
        {
            return url
        }
    }
    return nil
}

func youtubeFeedURL(in html: String, relativeTo pageURL: URL) -> URL? {
    let host = pageURL.host?.lowercased() ?? ""
    guard host == "youtube.com" || host.hasSuffix(".youtube.com") else {
        return nil
    }
    let parts = pageURL.path.split(separator: "/").map(String.init)
    let pathID = parts.first == "channel" ? parts.dropFirst().first : nil
    let channelID = pathID ?? regexCapture(
        html,
        pattern: #"(?is)<meta\b(?=[^>]*\bitemprop=["']channelId["'])[^>]*\bcontent=["']([^"']+)["']"#
    ) ?? regexCapture(
        html,
        pattern: #"["']channelId["']\s*:\s*["']([^"']+)["']"#
    )
    guard
        let channelID,
        channelID.range(
            of: #"^[A-Za-z0-9_-]{10,64}$"#,
            options: .regularExpression
        ) != nil
    else {
        return nil
    }
    var components = URLComponents(string: "https://www.youtube.com/feeds/videos.xml")!
    components.queryItems = [URLQueryItem(name: "channel_id", value: channelID)]
    return components.url
}

private func applePodcastFeedURL(for pageURL: URL) async -> URL? {
    guard
        pageURL.host?.lowercased() == "podcasts.apple.com",
        let id = regexCapture(pageURL.path, pattern: #"/id(\d+)(?:/|$)"#)
    else {
        return nil
    }
    var components = URLComponents(string: "https://itunes.apple.com/lookup")!
    components.queryItems = [
        URLQueryItem(name: "id", value: id),
        URLQueryItem(name: "entity", value: "podcast")
    ]
    guard
        let url = components.url,
        let (data, _) = try? await fetchChannelURL(url),
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let results = object["results"] as? [[String: Any]],
        let value = results.first(where: { $0["kind"] as? String == "podcast" })?["feedUrl"]
            as? String,
        let feedURL = httpURL(value)
    else {
        return nil
    }
    return feedURL
}

func parseHackerNews(
    _ html: String,
    sourceURL: URL,
    maximumItems: Int = 5
) -> DiscoveredChannel? {
    guard
        sourceURL.host?.lowercased() == "news.ycombinator.com",
        ["", "/", "/front"].contains(sourceURL.path),
        let rows = try? NSRegularExpression(pattern: #"(?is)<tr\b([^>]*)>(.*?)</tr>"#),
        let links = try? NSRegularExpression(
            pattern: #"(?is)<span\b[^>]*class=["'][^"']*\btitleline\b[^"']*["'][^>]*>.*?<a\b([^>]*)>(.*?)</a>"#
        )
    else {
        return nil
    }
    var items = [DiscoveredChannel.Item]()
    for row in rows.matches(
        in: html,
        range: NSRange(location: 0, length: html.utf16.count)
    ) {
        guard
            row.numberOfRanges == 3,
            let attributesRange = Range(row.range(at: 1), in: html),
            let bodyRange = Range(row.range(at: 2), in: html)
        else {
            continue
        }
        let attributes = String(html[attributesRange])
        let classes = htmlAttribute("class", in: attributes)
            .split(whereSeparator: \.isWhitespace)
        guard classes.contains("athing") else { continue }
        let body = String(html[bodyRange])
        guard
            let link = links.firstMatch(
                in: body,
                range: NSRange(location: 0, length: body.utf16.count)
            ),
            let linkAttributesRange = Range(link.range(at: 1), in: body),
            let titleRange = Range(link.range(at: 2), in: body),
            let href = htmlAttribute(
                "href",
                in: String(body[linkAttributesRange])
            ).nilIfEmpty,
            let itemURL = URL(string: decodeHTML(href), relativeTo: sourceURL)?.absoluteURL,
            httpURL(itemURL.absoluteString) != nil
        else {
            continue
        }
        let id = htmlAttribute("id", in: attributes).nilIfEmpty ?? itemURL.absoluteString
        items.append(.init(
            id: id,
            title: decodeHTML(stripHTML(String(body[titleRange]))),
            url: itemURL.absoluteString
        ))
        if items.count == maximumItems { break }
    }
    return items.isEmpty ? nil : DiscoveredChannel(
        title: "Hacker News front page",
        kind: .feed,
        items: items
    )
}

private func htmlAttribute(_ name: String, in tag: String) -> String {
    regexCapture(
        tag,
        pattern: #"(?is)\b\#(name)\s*=\s*["']([^"']*)["']"#
    ) ?? ""
}

func parseFeed(
    _ data: Data,
    fallbackTitle: String,
    baseURL: URL? = nil
) throws -> DiscoveredChannel {
    let delegate = FeedParser(baseURL: baseURL)
    let parser = XMLParser(data: data)
    parser.delegate = delegate
    guard parser.parse(), !delegate.items.isEmpty else {
        throw LibraryError.channelFailed(
            parser.parserError?.localizedDescription ??
                "The feed did not contain any items."
        )
    }
    return DiscoveredChannel(
        title: delegate.channelTitle.nilIfEmpty ?? fallbackTitle,
        kind: delegate.isPodcast ? .podcast : .feed,
        items: delegate.items
    )
}

private final class FeedParser: NSObject, XMLParserDelegate {
    private let baseURL: URL?
    private var inItem = false
    private var activeElement = ""
    private var text = ""
    private var item = DiscoveredChannel.Item(id: "", title: "", url: "")
    var channelTitle = ""
    var isPodcast = false
    var items = [DiscoveredChannel.Item]()

    init(baseURL: URL?) {
        self.baseURL = baseURL
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        let name = localName(elementName)
        activeElement = name
        text = ""
        if name == "item" || name == "entry" {
            inItem = true
            item = .init(id: "", title: "", url: "")
        } else if inItem, name == "link", let href = attributeDict["href"] {
            if attributeDict["rel"] == "enclosure" {
                item.linkedURL = href
                item.mediaURL = href
                isPodcast = attributeDict["type"]?.lowercased().hasPrefix("audio/") == true || isPodcast
            } else if item.url.isEmpty || attributeDict["rel"] == "alternate" {
                item.url = href
            }
        } else if inItem, name == "enclosure", let url = attributeDict["url"] {
            item.linkedURL = url
            item.mediaURL = url
            isPodcast = attributeDict["type"]?.lowercased().hasPrefix("audio/") == true || isPodcast
        } else if inItem, name == "transcript", let url = attributeDict["url"] {
            let type = nativeTranscriptType(attributeDict["type"], url: url)
            if nativeTranscriptRank(type) > nativeTranscriptRank(item.transcriptType) {
                item.transcriptURL = url
                item.transcriptType = type
                item.transcriptLanguage = attributeDict["language"]
            }
            isPodcast = true
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        text += String(decoding: CDATABlock, as: UTF8.self)
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let name = localName(elementName)
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if inItem {
            switch name {
            case "title":
                item.title = decodeHTML(stripHTML(value))
            case "guid", "id":
                item.id = value
            case "link" where item.url.isEmpty:
                item.url = value
            case "pubdate", "published", "updated":
                item.publishedAt = value.nilIfEmpty
            case "description", "summary", "content", "encoded":
                let content = stripHTML(value)
                if content.count > (item.content?.count ?? 0) {
                    item.content = content.nilIfEmpty
                }
            default:
                break
            }
        } else if name == "title", channelTitle.isEmpty {
            channelTitle = decodeHTML(stripHTML(value))
        }
        if name == "item" || name == "entry" {
            if item.url.isEmpty, httpURL(item.id) != nil {
                item.url = item.id
            }
            if item.url.isEmpty, let mediaURL = item.mediaURL {
                item.url = mediaURL
            }
            if
                let baseURL,
                let url = URL(string: item.url, relativeTo: baseURL)?.absoluteURL
            {
                item.url = url.absoluteString
            }
            if
                let linkedURL = item.linkedURL,
                let url = URL(string: linkedURL, relativeTo: baseURL)?.absoluteURL
            {
                item.linkedURL = url.absoluteString
                item.mediaURL = url.absoluteString
            }
            if
                let transcriptURL = item.transcriptURL,
                let url = URL(string: transcriptURL, relativeTo: baseURL)?.absoluteURL
            {
                item.transcriptURL = url.absoluteString
            }
            if item.id.isEmpty { item.id = item.url }
            if item.title.isEmpty { item.title = item.content?.prefix(100).description ?? "Untitled" }
            if httpURL(item.url) != nil, !item.id.isEmpty {
                items.append(item)
            }
            inItem = false
        }
        activeElement = ""
        text = ""
    }

    private func localName(_ value: String) -> String {
        value.split(separator: ":").last?.lowercased() ?? value.lowercased()
    }
}

private func stripHTML(_ value: String) -> String {
    var text = value
    for pattern in [
        #"(?is)<(script|style)\b[^>]*>.*?</\1>"#,
        #"(?i)<br\s*/?>"#,
        #"(?i)</p\s*>"#,
        #"(?is)<[^>]+>"#
    ] {
        text = text.replacingOccurrences(
            of: pattern,
            with: pattern.contains("br") || pattern.contains("/p") ? "\n" : " ",
            options: .regularExpression
        )
    }
    return decodeHTML(text)
        .replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
        .replacingOccurrences(of: #"\n\s*\n\s*\n+"#, with: "\n\n", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

private func decodeHTML(_ value: String) -> String {
    var text = value
    for (entity, replacement) in [
        ("&amp;", "&"),
        ("&lt;", "<"),
        ("&gt;", ">"),
        ("&quot;", "\""),
        ("&#39;", "'"),
        ("&apos;", "'"),
        ("&nbsp;", " ")
    ] {
        text = text.replacingOccurrences(
            of: entity,
            with: replacement,
            options: .caseInsensitive
        )
    }
    return text
}

private func validFavicon(_ data: Data, fileExtension: String) -> Bool {
    let bytes = [UInt8](data.prefix(12))
    switch fileExtension {
    case "png":
        return bytes.starts(with: [0x89, 0x50, 0x4e, 0x47])
    case "jpg":
        return bytes.starts(with: [0xff, 0xd8, 0xff])
    case "gif":
        return bytes.starts(with: Array("GIF8".utf8))
    case "ico":
        return bytes.starts(with: [0x00, 0x00, 0x01, 0x00])
    case "webp":
        return bytes.starts(with: Array("RIFF".utf8)) &&
            bytes.dropFirst(8).starts(with: Array("WEBP".utf8))
    case "svg":
        let prefix = String(decoding: data.prefix(1_024), as: UTF8.self).lowercased()
        return prefix.contains("<svg")
    default:
        return false
    }
}

private func validChannelSource(_ source: String) -> Bool {
    httpURL(source) != nil
}

private func validSchedule(_ value: String) -> Bool {
    let normalized = value.lowercased()
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    if normalized == "manual" { return true }
    let patterns = [
        #"^hourly(?: at)? :([0-5][0-9])$"#,
        #"^daily(?: at)? ([01]?[0-9]|2[0-3]):([0-5][0-9])$"#,
        #"^weekly (mon|tue|wed|thu|fri|sat|sun)(?:day)?(?: at)? ([01]?[0-9]|2[0-3]):([0-5][0-9])$"#
    ]
    return patterns.contains {
        normalized.range(of: $0, options: .regularExpression) != nil
    }
}

private func mostRecentScheduledDate(_ value: String, at date: Date) -> Date? {
    let normalized = value.lowercased()
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    guard normalized != "manual" else { return nil }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .current

    if normalized.hasPrefix("hourly") {
        guard
            let minuteText = regexCapture(normalized, pattern: #":([0-5][0-9])$"#),
            let minute = Int(minuteText)
        else {
            return nil
        }
        var components = calendar.dateComponents(
            [.year, .month, .day, .hour],
            from: date
        )
        components.minute = minute
        components.second = 0
        guard var candidate = calendar.date(from: components) else { return nil }
        if candidate > date {
            candidate = calendar.date(byAdding: .hour, value: -1, to: candidate)!
        }
        return candidate
    }

    guard
        let time = regexCapture(
            normalized,
            pattern: #"((?:[01]?[0-9]|2[0-3]):[0-5][0-9])$"#
        )
    else {
        return nil
    }
    let parts = time.split(separator: ":").compactMap { Int($0) }
    guard parts.count == 2 else { return nil }
    var components = calendar.dateComponents([.year, .month, .day], from: date)
    components.hour = parts[0]
    components.minute = parts[1]
    components.second = 0
    guard var candidate = calendar.date(from: components) else { return nil }

    if normalized.hasPrefix("daily") {
        if candidate > date {
            candidate = calendar.date(byAdding: .day, value: -1, to: candidate)!
        }
        return candidate
    }

    guard
        let weekdayText = regexCapture(
            normalized,
            pattern: #"^weekly (mon|tue|wed|thu|fri|sat|sun)"#
        ),
        let targetWeekday = [
            "sun": 1,
            "mon": 2,
            "tue": 3,
            "wed": 4,
            "thu": 5,
            "fri": 6,
            "sat": 7
        ][weekdayText]
    else {
        return nil
    }
    let weekday = calendar.component(.weekday, from: date)
    let daysBack = (weekday - targetWeekday + 7) % 7
    candidate = calendar.date(byAdding: .day, value: -daysBack, to: candidate)!
    if candidate > date {
        candidate = calendar.date(byAdding: .day, value: -7, to: candidate)!
    }
    return candidate
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

private extension Date {
    var iso8601: String {
        ISO8601DateFormatter().string(from: self)
    }
}
