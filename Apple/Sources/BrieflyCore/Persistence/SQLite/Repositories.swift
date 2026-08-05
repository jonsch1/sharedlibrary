import Foundation

/// Persistence access for library documents. Application workflows depend on
/// this capability instead of the SQL-shaped surface of `SQLiteLibrary`.
struct SQLiteDocumentRepository {
    let database: SQLiteLibrary

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
}

/// Persistence access for the user-maintained topic catalog.
struct SQLiteTopicRepository {
    let database: SQLiteLibrary

    func all() throws -> [LibraryTopicDefinition] {
        try database.topicDefinitions()
    }

    func replace(_ definitions: [LibraryTopicDefinition]) throws {
        try database.replaceTopicDefinitions(definitions)
    }
}

/// Persistence access for voice-brief definitions and durable run state.
struct SQLiteVoiceBriefRepository {
    let database: SQLiteLibrary

    func all() throws -> [LibraryVoiceBrief] { try database.voiceBriefs() }

    func save(_ draft: LibraryVoiceBriefDraft) throws -> String {
        try database.saveVoiceBrief(draft)
    }

    func delete(_ id: String) throws { try database.deleteVoiceBrief(id) }

    func runStates() throws -> [SQLiteVoiceBriefRunState] {
        try database.voiceBriefRunStates()
    }

    func saveRunStates(_ states: [SQLiteVoiceBriefRunState]) throws {
        try database.saveVoiceBriefRunStates(states)
    }
}

/// Persistence access for channel definitions, items, and channel-derived
/// document relationships.
struct SQLiteChannelRepository {
    let database: SQLiteLibrary

    func records() throws -> [SQLiteChannelRecord] { try database.channelRecords() }

    func sourcesByDocument() throws -> [String: [String]] {
        try database.documentChannelSources()
    }

    func saveRecords(_ records: [SQLiteChannelRecord]) throws {
        try database.saveChannelRecords(records)
    }

    func delete(_ source: String) throws { try database.deleteChannel(source) }

    @discardableResult
    func removeItemsFromDeletedChannels() throws -> Int {
        try database.trashDocumentsFromDeletedChannels()
    }
}

/// Persistence access for binary document attachments.
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

/// Persistence access for the local processing queue.
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

/// Persistence access for the explicit one-time Markdown import.
struct SQLiteMarkdownRepository {
    let database: SQLiteLibrary

    func ingest(from root: URL) throws -> Int {
        try database.ingestMarkdownLibrary(root)
    }
}
