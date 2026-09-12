import Foundation

public enum LibraryError: LocalizedError {
    case emptyCapture
    case emptyDocument
    case emptyHighlight
    case highlightTooLong
    case invalidAudio
    case missingEntry
    case missingChannel
    case missingChannelItem
    case channelAlreadyExists
    case missingVariant
    case invalidChannel
    case invalidChannelTitle
    case invalidChannelReviewLimit
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
    case invalidSynchronizedFile(String)

    public var errorDescription: String? {
        switch self {
        case .emptyCapture: "The clipboard does not contain text."
        case .emptyDocument: "The PDF does not contain extractable text."
        case .emptyHighlight: "Select some document text before highlighting."
        case .highlightTooLong: "A highlight must be 50,000 characters or fewer."
        case .invalidAudio: "Briefly could not save the generated audio."
        case .missingEntry: "The selected library item no longer exists."
        case .missingChannel: "The selected channel no longer exists."
        case .missingChannelItem: "That channel item is no longer pending."
        case .channelAlreadyExists: "One of these sources is already in a channel."
        case .missingVariant: "That document version is not available."
        case .invalidChannel: "Channels must be HTTP(S) URLs or arXiv queries."
        case .invalidChannelTitle: "Channel names must contain 1–120 characters."
        case .invalidChannelReviewLimit: "The channel review window must contain between 1 and 50 items."
        case .invalidChannelSchedule:
            "Schedule must be manual, daily HH:MM, or weekly MON HH:MM."
        case .channelFailed(let message): message
        case .invalidProcessingOutput:
            "AI processing did not return the required summaries and topic."
        case .invalidProcessingPrompt:
            "The processing prompt must include {{topics}} and {{source}}."
        case .invalidProcessingCommand: "The AI command must contain 1–4,000 characters."
        case .invalidTopic: "Topic titles must contain 1–48 characters."
        case .invalidTopicDefinitions(let message): message
        case .processingFailed(let message): message
        case .processingOutputTooLarge: "The AI command returned more than 10 MB of output."
        case .processingTimedOut: "AI processing timed out after 5 minutes."
        case .processingUnavailable: "Local AI commands are only available in the macOS app."
        case .invalidSynchronizedFile(let path): "The synchronized copy of \(path) is invalid."
        }
    }
}

/// Public application facade. The actor serializes workflows while the
/// composition root delegates to focused capture, channel, projection,
/// processing, and import services.
public actor SQLiteLibraryStore {
    public let databaseURL: URL
    let fileManager = FileManager.default
    private var sqliteLibrary: SQLiteLibrary?
    private var components: LibraryStoreComponents?

    public init(databaseURL: URL) {
        self.databaseURL = databaseURL.standardizedFileURL
    }

    func database() throws -> SQLiteLibrary {
        if let sqliteLibrary { return sqliteLibrary }
        let database = try SQLiteLibrary(databaseURL: databaseURL)
        sqliteLibrary = database
        return database
    }

    private func services() throws -> LibraryStoreComponents {
        if let components { return components }
        let value = LibraryStoreComponents(database: try database(), fileManager: fileManager)
        components = value
        return value
    }

    public func documentDatabase() throws -> SQLiteLibrary { try database() }

    public func capture(_ value: String) throws -> String {
        try services().capture.capture(value)
    }

    @discardableResult
    public func captureWebPage(
        title: String,
        content: String,
        sourceURL: URL,
        faviconData: Data? = nil,
        faviconFileExtension: String? = nil
    ) throws -> String {
        try services().capture.captureWebPage(
            title: title,
            content: content,
            sourceURL: sourceURL,
            faviconData: faviconData,
            faviconFileExtension: faviconFileExtension
        )
    }

    @discardableResult
    public func captureDocument(title: String, content: String) throws -> String {
        try services().capture.captureDocument(title: title, content: content)
    }

    @discardableResult
    public func captureItem(_ draft: ItemDraft, captureID: String? = nil) throws -> String {
        try services().capture.captureItem(draft, captureID: captureID)
    }

    public func loadChannels() throws -> [LibraryChannel] {
        try services().channels.loadChannels()
    }

    @discardableResult
    public func addChannel(_ value: String) throws -> String {
        try services().channels.addChannel([value])
    }

    @discardableResult
    public func addChannel(_ values: [String]) throws -> String {
        try services().channels.addChannel(values)
    }

    public func updateChannel(
        _ value: String,
        reviewLimit: Int,
        schedule: String
    ) throws {
        try services().channels.updateChannel(
            value,
            reviewLimit: reviewLimit,
            schedule: schedule
        )
    }

    public func updateChannelGroup(
        _ groupID: String,
        title: String,
        sources: [String],
        reviewLimit: Int,
        schedule: String
    ) throws {
        try services().channels.updateChannelGroup(
            groupID,
            title: title,
            sources: sources,
            reviewLimit: reviewLimit,
            schedule: schedule
        )
    }

    @discardableResult
    public func removeChannel(_ value: String) throws -> Int {
        try services().channels.removeChannel(value)
    }

    @discardableResult
    public func removeChannelGroup(_ groupID: String) throws -> Int {
        try services().channels.removeChannelGroup(groupID)
    }

    public func checkChannel(
        _ value: String,
        maximumItems: Int? = nil
    ) async throws -> LibraryChannelRefresh {
        try await services().channels.checkChannel(value, maximumItems: maximumItems)
    }

    public func checkChannelInput(
        _ value: String,
        maximumItems: Int? = nil,
        discover: @Sendable (Int) async throws -> ChannelInputBatch
    ) async throws -> LibraryChannelRefresh {
        try await services().channels.checkChannelInput(
            value,
            maximumItems: maximumItems,
            discover: discover
        )
    }

    public func captureSignedInChannelPage(
        source: String,
        title: String,
        content: String
    ) async throws -> LibraryChannelRefresh {
        try await services().channels.captureSignedInChannelPage(
            source: source, title: title, content: content
        )
    }

    public func captureSignedInChannelItems(
        source: String,
        title: String,
        items: [LibraryChannelCandidate]
    ) async throws -> LibraryChannelRefresh {
        try await services().channels.captureSignedInChannelItems(
            source: source, title: title, items: items
        )
    }

    public func loadMoreChannel(
        _ value: String
    ) async throws -> LibraryChannelRefresh {
        try await services().channels.loadMoreChannel(value)
    }

    public func dueChannelSources(at date: Date = Date()) throws -> [String] {
        try services().channels.dueChannelSources(at: date)
    }

    public func loadHighlights() throws -> String {
        try services().content.loadHighlights()
    }

    public func addHighlight(entryID: String, variant: LibraryVariant, text: String) throws {
        try services().content.addHighlight(entryID: entryID, variant: variant, text: text)
    }

    @discardableResult
    public func removeHighlight(_ text: String) throws -> Bool {
        try services().content.removeHighlight(text)
    }

    public func acceptChannelItem(
        channelID: String,
        itemID: String,
        ingest: @Sendable (LibraryChannelCandidate) async throws -> String
    ) async throws -> String {
        try await services().channels.acceptChannelItem(
            channelID: channelID, itemID: itemID, ingest: ingest
        )
    }

    public func rejectChannelItem(channelID: String, itemID: String) throws {
        try services().channels.rejectChannelItem(channelID: channelID, itemID: itemID)
    }

    public func moveToTrash(entryID: String) throws {
        try services().content.moveToTrash(entryID: entryID)
    }

    public func topicDefinitions() throws -> [LibraryTopicDefinition] {
        try services().content.topicDefinitions()
    }

    @discardableResult
    public func replaceTopicDefinitions(
        _ definitions: [LibraryTopicDefinition]
    ) throws -> [LibraryTopicDefinition] {
        try services().content.replaceTopicDefinitions(definitions)
    }

    public func deleteTopicDefinition(id: String) throws {
        try services().content.deleteTopicDefinition(id: id)
    }

    public func loadProjection(includeDeleted: Bool = false) throws -> LibraryProjection {
        try services().projection.loadProjection(includeDeleted: includeDeleted)
    }

    public func loadLibraryIndex(includeDeleted: Bool = false) throws -> LibraryProjection {
        try services().projection.loadLibraryIndex(includeDeleted: includeDeleted)
    }

    public func loadTrash() throws -> [LibraryEntry] {
        try services().projection.loadTrash()
    }

    public func loadTrashIndex() throws -> [LibraryEntry] {
        try services().projection.loadTrashIndex()
    }

    public func attachAudio(entryID: String, file source: URL) throws {
        try services().capture.attachAudio(entryID: entryID, file: source)
    }

    public func writeText(entryID: String, variant: LibraryVariant, text: String) throws {
        try services().capture.writeText(entryID: entryID, variant: variant, text: text)
    }

    public func search(_ query: String, limit: Int = 50) throws -> [SQLiteSearchResult] {
        try services().capture.search(query, limit: limit)
    }

    public func getDocument(_ id: String, includeDeleted: Bool = false) throws -> SQLiteDocument {
        try services().capture.getDocument(id, includeDeleted: includeDeleted)
    }

    @discardableResult
    public func commitDocument(
        _ id: String,
        baseRevision: Int64,
        texts: [LibraryVariant: String],
        removedTexts: Set<LibraryVariant> = [],
        title: String? = nil
    ) throws -> SQLiteDocument {
        try services().capture.commitDocument(
            id,
            baseRevision: baseRevision,
            texts: texts,
            removedTexts: removedTexts,
            title: title
        )
    }

    @discardableResult
    public func batch(_ commits: [SQLiteDocumentCommit]) throws -> [SQLiteDocument] {
        try services().capture.batch(commits)
    }

    public func audioURL(entryID: String) throws -> URL? {
        try services().capture.audioURL(entryID: entryID)
    }

    public func faviconURL(entryID: String) throws -> URL? {
        try services().capture.faviconURL(entryID: entryID)
    }

    public func ingestMarkdownLibrary(from root: URL) throws -> Int {
        try services().markdown.ingest(from: root)
    }

    public func enqueueProcessingJob(entryID: String, selectWhenFinished: Bool) throws {
        try services().processing.enqueue(
            entryID: entryID,
            selectWhenFinished: selectWhenFinished
        )
    }

    public func claimNextProcessingJob() throws -> SQLiteProcessingJob? {
        try services().processing.claimNext()
    }

    public func completeProcessingJob(entryID: String) throws {
        try services().processing.complete(entryID: entryID)
    }

    public func failProcessingJob(entryID: String, error: String) throws {
        try services().processing.fail(entryID: entryID, error: error)
    }

    public func processingPrompt(
        entryID: String,
        template: String = defaultProcessingPrompt
    ) throws -> String {
        try services().processing.prompt(entryID: entryID, template: template)
    }

    @discardableResult
    public func applyProcessingSuggestion(
        entryID: String,
        suggestion: ProcessingSuggestion
    ) throws -> String {
        try services().processing.apply(entryID: entryID, suggestion: suggestion)
    }
}
