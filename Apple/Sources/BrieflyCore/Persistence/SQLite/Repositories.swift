import Foundation

/// Focused persistence accessors keep application workflows independent from the
/// SQL-shaped surface of `SQLiteLibrary`. They intentionally contain no
/// discovery, processing, or projection policy.
struct SQLiteLibraryRepositories {
    let documents: SQLiteDocumentRepository
    let channels: SQLiteChannelRepository
    let attachments: SQLiteAttachmentRepository
    let processing: SQLiteProcessingRepository

    init(database: SQLiteLibrary) {
        documents = SQLiteDocumentRepository(database: database)
        channels = SQLiteChannelRepository(database: database)
        attachments = SQLiteAttachmentRepository(database: database)
        processing = SQLiteProcessingRepository(database: database)
    }
}

struct SQLiteDocumentRepository {
    let database: SQLiteLibrary

    func isEmpty() throws -> Bool { try database.isEmpty() }

    func create(
        title: String,
        body: String,
        texts: [LibraryVariant: String]? = nil,
        type: String = "document",
        sourceURL: String? = nil,
        mediaURL: String? = nil,
        topicIDs: [String] = [],
        tags: [String] = [],
        voiceBriefID: String? = nil,
        sourceIDs: [String] = [],
        sourceURLs: [String] = [],
        id: String? = nil,
        captureID: String? = nil,
        createdAt: Date = Date()
    ) throws -> SQLiteDocument {
        try database.createDocument(
            title: title,
            body: body,
            texts: texts,
            type: type,
            sourceURL: sourceURL,
            mediaURL: mediaURL,
            topicIDs: topicIDs,
            tags: tags,
            voiceBriefID: voiceBriefID,
            sourceIDs: sourceIDs,
            sourceURLs: sourceURLs,
            id: id,
            captureID: captureID,
            createdAt: createdAt
        )
    }

    func get(_ id: String, includeDeleted: Bool = false) throws -> SQLiteDocument {
        try database.getDocument(id, includeDeleted: includeDeleted)
    }

    func all(includeDeleted: Bool = false) throws -> [SQLiteDocument] {
        try database.allDocuments(includeDeleted: includeDeleted)
    }

    func deleted() throws -> [SQLiteDocument] { try database.deletedDocuments() }

    func index(includeDeleted: Bool = false) throws -> [SQLiteDocumentIndex] {
        try database.documentIndex(includeDeleted: includeDeleted)
    }

    func deletedIndex() throws -> [SQLiteDocumentIndex] {
        try database.deletedDocumentIndex()
    }

    func search(_ text: String, limit: Int = 50) throws -> [SQLiteSearchResult] {
        try database.search(text, limit: limit)
    }

    func commit(_ commit: SQLiteDocumentCommit) throws -> SQLiteDocument {
        try database.commitDocument(commit)
    }

    func batch(_ commits: [SQLiteDocumentCommit]) throws -> [SQLiteDocument] {
        try database.batch(commits)
    }

    func topics() throws -> [LibraryTopicDefinition] { try database.topicDefinitions() }

    func replaceTopics(_ definitions: [LibraryTopicDefinition]) throws {
        try database.replaceTopicDefinitions(definitions)
    }

    func voiceBriefs() throws -> [LibraryVoiceBrief] { try database.voiceBriefs() }

    func saveVoiceBrief(_ draft: LibraryVoiceBriefDraft) throws -> String {
        try database.saveVoiceBrief(draft)
    }

    func deleteVoiceBrief(_ id: String) throws { try database.deleteVoiceBrief(id) }

    func channelSourcesByDocument() throws -> [String: [String]] {
        try database.documentChannelSources()
    }

    func ingestMarkdownLibrary(_ root: URL) throws -> Int {
        try database.ingestMarkdownLibrary(root)
    }
}

struct SQLiteChannelRepository {
    let database: SQLiteLibrary

    func records() throws -> [SQLiteChannelRecord] { try database.channelRecords() }

    func runStates() throws -> [SQLiteVoiceBriefRunState] {
        try database.voiceBriefRunStates()
    }

    func saveRecords(_ records: [SQLiteChannelRecord]) throws {
        try database.saveChannelRecords(records)
    }

    func saveRunStates(_ states: [SQLiteVoiceBriefRunState]) throws {
        try database.saveVoiceBriefRunStates(states)
    }

    func delete(_ source: String) throws { try database.deleteChannel(source) }

    @discardableResult
    func removeItemsFromDeletedChannels() throws -> Int {
        try database.trashDocumentsFromDeletedChannels()
    }
}

struct SQLiteAttachmentRepository {
    let database: SQLiteLibrary

    func save(
        documentID: String,
        kind: String,
        mimeType: String,
        data: Data
    ) throws {
        try database.saveAttachment(
            documentID: documentID,
            kind: kind,
            mimeType: mimeType,
            data: data
        )
    }

    func data(documentID: String, kind: String) throws -> (String, Data)? {
        try database.attachment(documentID: documentID, kind: kind)
    }

    func metadata() throws -> [SQLiteAttachmentMetadata] {
        try database.attachmentMetadata()
    }
}

struct SQLiteProcessingRepository {
    let database: SQLiteLibrary

    func enqueue(documentID: String, selectWhenFinished: Bool) throws {
        try database.enqueueProcessingJob(
            documentID: documentID,
            selectWhenFinished: selectWhenFinished
        )
    }

    func claimNext() throws -> SQLiteProcessingJob? {
        try database.claimNextProcessingJob()
    }

    func complete(documentID: String) throws {
        try database.completeProcessingJob(documentID: documentID)
    }

    func fail(documentID: String, error: String) throws {
        try database.failProcessingJob(documentID: documentID, error: error)
    }
}
