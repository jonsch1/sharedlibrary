import Foundation
import SQLite3

public struct SQLiteDocument: Codable, Equatable, Sendable {
    public var id: String
    public var captureID: String
    public var type: String
    public var voiceBriefID: String?
    public var title: String
    public var sourceURL: String?
    public var mediaURL: String?
    public var createdAt: Date
    public var updatedAt: Date
    public var revision: Int64
    public var deleted: Bool
    public var topicIDs: [String]
    public var tags: [String]
    public var sourceIDs: [String]
    public var sourceURLs: [String]
    public var texts: [LibraryVariant: String]
    public var cloudRecordData: Data?

    public init(
        id: String,
        captureID: String,
        type: String = "document",
        voiceBriefID: String? = nil,
        title: String,
        sourceURL: String? = nil,
        mediaURL: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        revision: Int64 = 1,
        deleted: Bool = false,
        topicIDs: [String] = [],
        tags: [String] = [],
        sourceIDs: [String] = [],
        sourceURLs: [String] = [],
        texts: [LibraryVariant: String],
        cloudRecordData: Data? = nil
    ) {
        self.id = id
        self.captureID = captureID
        self.type = type
        self.voiceBriefID = voiceBriefID
        self.title = title
        self.sourceURL = sourceURL
        self.mediaURL = mediaURL
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.revision = revision
        self.deleted = deleted
        self.topicIDs = topicIDs
        self.tags = tags
        self.sourceIDs = sourceIDs
        self.sourceURLs = sourceURLs
        self.texts = texts
        self.cloudRecordData = cloudRecordData
    }
}

struct SQLiteDocumentIndex: Sendable {
    var document: SQLiteDocument
    var variants: [LibraryVariant]
    var excerpt: String
}

public struct SQLiteSearchResult: Equatable, Sendable {
    public let id: String
    public let title: String
    public let variant: LibraryVariant
    public let snippet: String
    public let revision: Int64
}

public struct SQLiteDocumentCommit: Sendable {
    public let id: String
    public let baseRevision: Int64
    public let title: String?
    public let type: String?
    public let voiceBriefID: String?
    public let sourceURL: String?
    public let mediaURL: String?
    public let topicIDs: [String]?
    public let tags: [String]?
    public let texts: [LibraryVariant: String]
    public let deleted: Bool?

    public init(
        id: String,
        baseRevision: Int64,
        title: String? = nil,
        type: String? = nil,
        voiceBriefID: String? = nil,
        sourceURL: String? = nil,
        mediaURL: String? = nil,
        topicIDs: [String]? = nil,
        tags: [String]? = nil,
        texts: [LibraryVariant: String] = [:],
        deleted: Bool? = nil
    ) {
        self.id = id
        self.baseRevision = baseRevision
        self.title = title
        self.type = type
        self.voiceBriefID = voiceBriefID
        self.sourceURL = sourceURL
        self.mediaURL = mediaURL
        self.topicIDs = topicIDs
        self.tags = tags
        self.texts = texts
        self.deleted = deleted
    }
}

public struct SQLiteOutboxItem: Equatable, Sendable {
    public let recordType: String
    public let documentID: String
    public let revision: Int64
    public let operation: String
}

public struct SQLiteLogicalRecord: Sendable {
    public let id: String
    public let revision: Int64
    public let deleted: Bool
    public let payload: Data
    public let cloudRecordData: Data?
}

public struct SQLiteAttachment: Equatable, Sendable {
    public let id: String
    public let documentID: String
    public let kind: String
    public let mimeType: String
    public let data: Data
    public let revision: Int64
    public let cloudRecordData: Data?
}

public struct SQLiteAttachmentMetadata: Sendable {
    public let documentID: String
    public let kind: String
    public let mimeType: String
}

public struct SQLiteChannelRecord: Sendable {
    public var source: String
    public var title: String?
    public var kind: LibraryChannelKind?
    public var schedule: String
    public var lastCheckedAt: String?
    public var error: String?
    public var retrievalCount: Int
    public var canLoadMore: Bool
    public var seen: [String]
    public var items: [LibraryChannelItem]
}

public struct SQLiteVoiceBriefRunState: Sendable {
    public var voiceBriefID: String
    public var lastRunAt: String?
    public var lastAttemptAt: String?
    public var status: String?
    public var message: String?
    public var consumed: [String]
}

public enum SQLiteLibraryError: LocalizedError, Equatable {
    case database(String)
    case missingDocument
    case revisionConflict(current: Int64)
    case invalidDocument

    public var errorDescription: String? {
        switch self {
        case .database(let message): message
        case .missingDocument: "That document no longer exists."
        case .revisionConflict(let current):
            "The document changed since it was read (current revision: \(current))."
        case .invalidDocument: "The document is invalid."
        }
    }
}

/// SQLite is the only writable document store. Markdown is parsed only by the explicit
/// one-time importer.
public final class SQLiteLibrary: @unchecked Sendable {
    private let connection: OpaquePointer
    private let lock = NSRecursiveLock()

    public init(databaseURL: URL) throws {
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var database: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(databaseURL.path, &database, flags, nil) == SQLITE_OK,
              let database else {
            let message = database.map { String(cString: sqlite3_errmsg($0)) } ??
                "SQLite could not open the library."
            if let database { sqlite3_close(database) }
            throw SQLiteLibraryError.database(message)
        }
        connection = database
        do {
            try execute("PRAGMA journal_mode=WAL; PRAGMA foreign_keys=ON; PRAGMA busy_timeout=5000;")
            try execute(Self.schema)
            let columns = try query("PRAGMA table_info(documents)") { columnText($0, 1) }
            if !columns.contains("media_url") {
                try execute("ALTER TABLE documents ADD COLUMN media_url TEXT")
            }
            if !columns.contains("excerpt") {
                try transaction {
                    try execute("ALTER TABLE documents ADD COLUMN excerpt TEXT NOT NULL DEFAULT ''")
                    try backfillExcerpts()
                }
            }
            let channelColumns = try query("PRAGMA table_info(channels)") { columnText($0, 1) }
            if !channelColumns.contains("schedule") {
                try execute("ALTER TABLE channels ADD COLUMN schedule TEXT NOT NULL DEFAULT 'manual'")
            }
            let attachmentParents = try query("PRAGMA foreign_key_list(attachments)") {
                columnText($0, 2)
            }
            if attachmentParents.contains("documents") {
                try transaction {
                    try execute(
                        """
                        ALTER TABLE attachments RENAME TO attachments_with_document_fk;
                        CREATE TABLE attachments(
                          id TEXT PRIMARY KEY,
                          document_id TEXT NOT NULL,
                          kind TEXT NOT NULL,
                          mime_type TEXT NOT NULL,
                          data BLOB NOT NULL,
                          revision INTEGER NOT NULL DEFAULT 1,
                          deleted_at REAL,
                          cloud_record BLOB
                        );
                        INSERT INTO attachments
                        SELECT * FROM attachments_with_document_fk;
                        DROP TABLE attachments_with_document_fk;
                        """
                    )
                }
            }
        } catch {
            sqlite3_close(database)
            throw error
        }
    }

    deinit { sqlite3_close(connection) }

    public func isEmpty() throws -> Bool {
        try locked { try scalarInt("SELECT count(*) FROM documents") == 0 }
    }

    public func createDocument(
        title: String,
        body: String,
        type: String = "document",
        sourceURL: String? = nil,
        mediaURL: String? = nil,
        topicIDs: [String] = [],
        tags: [String] = [],
        voiceBriefID: String? = nil,
        sourceIDs: [String] = [],
        sourceURLs: [String] = [],
        id requestedID: String? = nil,
        captureID requestedCaptureID: String? = nil,
        createdAt: Date = Date(),
        addToOutbox: Bool = true
    ) throws -> SQLiteDocument {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !normalizedTitle.isEmpty else {
            throw SQLiteLibraryError.invalidDocument
        }
        let captureID = requestedCaptureID ?? UUID().uuidString.uppercased()
        let id = requestedID ?? "personal:\(captureID)"
        let document = SQLiteDocument(
            id: id,
            captureID: captureID,
            type: type,
            voiceBriefID: voiceBriefID,
            title: normalizedTitle,
            sourceURL: sourceURL,
            mediaURL: mediaURL,
            createdAt: createdAt,
            updatedAt: createdAt,
            topicIDs: topicIDs,
            tags: tags,
            sourceIDs: sourceIDs,
            sourceURLs: sourceURLs,
            texts: [.source: trimmed]
        )
        return try locked {
            try transaction {
                try insert(document)
                if addToOutbox { try enqueue(id: id, revision: 1, operation: "save") }
            }
            return document
        }
    }

    public func getDocument(_ id: String, includeDeleted: Bool = false) throws -> SQLiteDocument {
        try locked {
            guard let document = try readDocument(id), includeDeleted || !document.deleted else {
                throw SQLiteLibraryError.missingDocument
            }
            return document
        }
    }

    public func allDocuments(includeDeleted: Bool = false) throws -> [SQLiteDocument] {
        try documents(where: includeDeleted ? nil : "deleted = 0")
    }

    public func deletedDocuments() throws -> [SQLiteDocument] {
        try documents(where: "deleted = 1")
    }

    func documentIndex(includeDeleted: Bool = false) throws -> [SQLiteDocumentIndex] {
        try indexDocuments(where: includeDeleted ? nil : "deleted = 0")
    }

    func deletedDocumentIndex() throws -> [SQLiteDocumentIndex] {
        try indexDocuments(where: "deleted = 1")
    }

    public func search(_ text: String, limit: Int = 50) throws -> [SQLiteSearchResult] {
        let queryText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !queryText.isEmpty else { return [] }
        return try locked {
            try query(
                """
                SELECT d.id, d.title, f.variant,
                       snippet(document_fts, 3, '‹', '›', ' … ', 24), d.revision
                FROM document_fts f JOIN documents d ON d.id = f.document_id
                WHERE document_fts MATCH ? AND d.deleted = 0
                ORDER BY bm25(document_fts) LIMIT ?
                """,
                bindings: [.text(queryText), .int(Int64(max(1, min(limit, 500))))]
            ) { statement in
                SQLiteSearchResult(
                    id: columnText(statement, 0),
                    title: columnText(statement, 1),
                    variant: LibraryVariant(rawValue: columnText(statement, 2)) ?? .source,
                    snippet: columnText(statement, 3),
                    revision: sqlite3_column_int64(statement, 4)
                )
            }
        }
    }

    public func topicDefinitions() throws -> [LibraryTopicDefinition] {
        try locked {
            try query(
                "SELECT id, title FROM topics WHERE deleted_at IS NULL ORDER BY title COLLATE NOCASE"
            ) { LibraryTopicDefinition(id: columnText($0, 0), title: columnText($0, 1)) }
        }
    }

    public func replaceTopicDefinitions(_ definitions: [LibraryTopicDefinition]) throws {
        try locked {
            try transaction {
                let active = Set(definitions.map(\.id))
                for definition in definitions {
                    try run(
                        "INSERT INTO topics(id, title) VALUES(?, ?) ON CONFLICT(id) DO UPDATE SET " +
                            "title = excluded.title, revision = topics.revision + 1, deleted_at = NULL",
                        bindings: [.text(definition.id), .text(definition.title)]
                    )
                    let revision = try scalarInt(
                        "SELECT revision FROM topics WHERE id = \(sqlLiteral(definition.id))"
                    )
                    try enqueue(
                        recordType: "topic", id: definition.id,
                        revision: revision, operation: "save"
                    )
                }
                for id in try query(
                    "SELECT id FROM topics WHERE deleted_at IS NULL",
                    transform: { columnText($0, 0) }
                ) where !active.contains(id) {
                    try run(
                        "UPDATE topics SET deleted_at = ?, revision = revision + 1 WHERE id = ?",
                        bindings: [.double(Date().timeIntervalSince1970), .text(id)]
                    )
                    let revision = try scalarInt(
                        "SELECT revision FROM topics WHERE id = \(sqlLiteral(id))"
                    )
                    try enqueue(recordType: "topic", id: id, revision: revision, operation: "delete")
                }
            }
        }
    }

    public func voiceBriefs() throws -> [LibraryVoiceBrief] {
        try locked {
            let rows = try query(
                """
                SELECT id, title, prompt, prioritize_for_me, schedule, length
                FROM voice_briefs WHERE deleted_at IS NULL ORDER BY title COLLATE NOCASE
                """
            ) { statement in
                (
                    columnText(statement, 0), columnText(statement, 1),
                    columnText(statement, 2), sqlite3_column_int(statement, 3) != 0,
                    columnText(statement, 4), columnText(statement, 5)
                )
            }
            return try rows.map { id, title, prompt, prioritize, schedule, length in
                let sources = try query(
                    "SELECT channel_id FROM voice_brief_sources WHERE voice_brief_id = ? " +
                        "ORDER BY channel_id",
                    bindings: [.text(id)], transform: { columnText($0, 0) }
                )
                return LibraryVoiceBrief(
                    id: id,
                    filename: id,
                    title: title,
                    schedule: schedule,
                    length: length,
                    sources: sources,
                    prompt: prompt,
                    prioritizeForMe: prioritize
                )
            }
        }
    }

    @discardableResult
    public func saveVoiceBrief(_ draft: LibraryVoiceBriefDraft) throws -> String {
        try locked {
            let id = draft.id ?? UUID().uuidString.uppercased()
            try transaction {
                let revision = (try query(
                    "SELECT revision FROM voice_briefs WHERE id = ?",
                    bindings: [.text(id)], transform: { sqlite3_column_int64($0, 0) }
                ).first ?? 0) + 1
                try run(
                    """
                    INSERT INTO voice_briefs(
                      id, title, prompt, prioritize_for_me, schedule, length, revision
                    ) VALUES(?, ?, ?, ?, ?, ?, ?) ON CONFLICT(id) DO UPDATE SET
                      title = excluded.title, prompt = excluded.prompt,
                      prioritize_for_me = excluded.prioritize_for_me,
                      schedule = excluded.schedule, length = excluded.length,
                      revision = excluded.revision, deleted_at = NULL
                    """,
                    bindings: [
                        .text(id), .text(draft.title), .text(draft.prompt),
                        .int(draft.prioritizeForMe ? 1 : 0), .text(draft.schedule),
                        .text(draft.length), .int(revision)
                    ]
                )
                try run("DELETE FROM voice_brief_sources WHERE voice_brief_id = ?", bindings: [.text(id)])
                for source in Set(draft.sources) {
                    try run(
                        "INSERT OR IGNORE INTO channels(id, source_url) VALUES(?, ?)",
                        bindings: [.text(source), .text(source)]
                    )
                    try run(
                        "INSERT INTO voice_brief_sources(voice_brief_id, channel_id) VALUES(?, ?)",
                        bindings: [.text(id), .text(source)]
                    )
                }
                try enqueue(recordType: "voice_brief", id: id, revision: revision, operation: "save")
            }
            return id
        }
    }

    public func deleteVoiceBrief(_ id: String) throws {
        try locked {
            try transaction {
                try run(
                    "UPDATE voice_briefs SET deleted_at = ?, revision = revision + 1 WHERE id = ?",
                    bindings: [.double(Date().timeIntervalSince1970), .text(id)]
                )
                let revision = try scalarInt(
                    "SELECT revision FROM voice_briefs WHERE id = \(sqlLiteral(id))"
                )
                try enqueue(recordType: "voice_brief", id: id, revision: revision, operation: "delete")
            }
        }
    }

    public func channelRecords() throws -> [SQLiteChannelRecord] {
        try locked {
            let rows = try query(
                """
                SELECT c.source_url, c.title, c.kind, c.schedule, s.last_checked_at,
                       s.last_error, c.retrieval_count, s.can_load_more
                FROM channels c LEFT JOIN channel_state s ON s.channel_id = c.id
                WHERE c.deleted_at IS NULL ORDER BY c.source_url
                """
            ) { statement in
                (
                    columnText(statement, 0), columnOptionalText(statement, 1),
                    columnOptionalText(statement, 2), columnText(statement, 3),
                    columnOptionalDate(statement, 4), columnOptionalText(statement, 5),
                    Int(sqlite3_column_int(statement, 6)), sqlite3_column_int(statement, 7) != 0
                )
            }
            return try rows.map { source, title, kind, schedule, checked, error, count, more in
                let items = try query(
                    """
                    SELECT item_id, title, url, published_at, content, linked_url,
                           entry_id, ingested_at FROM channel_items
                    WHERE channel_id = ? ORDER BY ingested_at DESC
                    """,
                    bindings: [.text(source)]
                ) {
                    LibraryChannelItem(
                        id: columnText($0, 0), title: columnText($0, 1),
                        url: columnText($0, 2), publishedAt: columnOptionalDate($0, 3),
                        content: columnOptionalText($0, 4), linkedURL: columnOptionalText($0, 5),
                        entryID: columnOptionalText($0, 6) ?? "",
                        ingestedAt: columnOptionalDate($0, 7) ??
                            ISO8601DateFormatter().string(from: Date())
                    )
                }
                let seen = try query(
                    "SELECT item_id FROM channel_seen WHERE channel_id = ? ORDER BY seen_at DESC",
                    bindings: [.text(source)], transform: { columnText($0, 0) }
                )
                return SQLiteChannelRecord(
                    source: source, title: title,
                    kind: kind.flatMap(LibraryChannelKind.init(rawValue:)),
                    schedule: schedule,
                    lastCheckedAt: checked, error: error, retrievalCount: count,
                    canLoadMore: more, seen: seen, items: items
                )
            }
        }
    }

    public func saveChannelRecords(_ records: [SQLiteChannelRecord]) throws {
        try locked {
            try transaction {
                for record in records {
                    let existing = try query(
                        "SELECT title, kind, schedule, retrieval_count, revision FROM channels WHERE id = ?",
                        bindings: [.text(record.source)]
                    ) { (columnOptionalText($0, 0), columnOptionalText($0, 1),
                         columnText($0, 2), Int(sqlite3_column_int($0, 3)),
                         sqlite3_column_int64($0, 4)) }.first
                    let changed = existing?.0 != record.title ||
                        existing?.1 != record.kind?.rawValue || existing?.2 != record.schedule ||
                        existing?.3 != record.retrievalCount
                    let revision = (existing?.4 ?? 0) + (changed ? 1 : 0)
                    try run(
                        """
                        INSERT INTO channels(id, source_url, title, kind, schedule, retrieval_count, revision)
                        VALUES(?, ?, ?, ?, ?, ?, ?) ON CONFLICT(id) DO UPDATE SET
                          title = excluded.title, kind = excluded.kind,
                          schedule = excluded.schedule,
                          retrieval_count = excluded.retrieval_count,
                          revision = excluded.revision, deleted_at = NULL
                        """,
                        bindings: [
                            .text(record.source), .text(record.source),
                            .optionalText(record.title), .optionalText(record.kind?.rawValue),
                            .text(record.schedule), .int(Int64(record.retrievalCount)),
                            .int(max(1, revision))
                        ]
                    )
                    try run(
                        """
                        INSERT INTO channel_state(
                          channel_id, last_checked_at, last_error, can_load_more
                        ) VALUES(?, ?, ?, ?) ON CONFLICT(channel_id) DO UPDATE SET
                          last_checked_at = excluded.last_checked_at,
                          last_error = excluded.last_error,
                          can_load_more = excluded.can_load_more
                        """,
                        bindings: [
                            .text(record.source), .optionalDouble(timestamp(record.lastCheckedAt)),
                            .optionalText(record.error), .int(record.canLoadMore ? 1 : 0)
                        ]
                    )
                    try run("DELETE FROM channel_items WHERE channel_id = ?", bindings: [.text(record.source)])
                    for item in record.items {
                        try run(
                            """
                            INSERT INTO channel_items(
                              channel_id, item_id, title, url, published_at, content,
                              linked_url, entry_id, ingested_at
                            ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?)
                            """,
                            bindings: [
                                .text(record.source), .text(item.id), .text(item.title), .text(item.url),
                                .optionalDouble(timestamp(item.publishedAt)), .optionalText(item.content),
                                .optionalText(item.linkedURL), .optionalText(item.entryID),
                                .optionalDouble(timestamp(item.ingestedAt))
                            ]
                        )
                    }
                    try run("DELETE FROM channel_seen WHERE channel_id = ?", bindings: [.text(record.source)])
                    for (offset, itemID) in record.seen.enumerated() {
                        try run(
                            "INSERT INTO channel_seen(channel_id, item_id, seen_at) VALUES(?, ?, ?)",
                            bindings: [
                                .text(record.source), .text(itemID),
                                .double(Date().addingTimeInterval(Double(-offset)).timeIntervalSince1970)
                            ]
                        )
                    }
                    if changed || existing == nil {
                        try enqueue(
                            recordType: "channel", id: record.source,
                            revision: max(1, revision), operation: "save"
                        )
                    }
                }
            }
        }
    }

    public func deleteChannel(_ source: String) throws {
        try locked {
            try transaction {
                try run(
                    "UPDATE channels SET deleted_at = ?, revision = revision + 1 WHERE id = ?",
                    bindings: [.double(Date().timeIntervalSince1970), .text(source)]
                )
                let revision = try scalarInt(
                    "SELECT revision FROM channels WHERE id = \(sqlLiteral(source))"
                )
                try enqueue(recordType: "channel", id: source, revision: revision, operation: "delete")
            }
        }
    }

    public func voiceBriefRunStates() throws -> [SQLiteVoiceBriefRunState] {
        try locked {
            try query(
                "SELECT voice_brief_id, last_run_at, last_attempt_at, status, message, consumed " +
                    "FROM voice_brief_state"
            ) {
                SQLiteVoiceBriefRunState(
                    voiceBriefID: columnText($0, 0),
                    lastRunAt: columnOptionalDate($0, 1),
                    lastAttemptAt: columnOptionalDate($0, 2),
                    status: columnOptionalText($0, 3),
                    message: columnOptionalText($0, 4),
                    consumed: decodeStrings(columnText($0, 5))
                )
            }
        }
    }

    public func saveVoiceBriefRunStates(_ states: [SQLiteVoiceBriefRunState]) throws {
        try locked {
            try transaction {
                for state in states {
                    guard try scalarInt(
                        "SELECT count(*) FROM voice_briefs WHERE id = \(sqlLiteral(state.voiceBriefID))"
                    ) > 0 else { continue }
                    try run(
                        """
                        INSERT INTO voice_brief_state(
                          voice_brief_id, last_run_at, last_attempt_at, status, message, consumed
                        ) VALUES(?, ?, ?, ?, ?, ?) ON CONFLICT(voice_brief_id) DO UPDATE SET
                          last_run_at = excluded.last_run_at,
                          last_attempt_at = excluded.last_attempt_at,
                          status = excluded.status, message = excluded.message,
                          consumed = excluded.consumed
                        """,
                        bindings: [
                            .text(state.voiceBriefID), .optionalDouble(timestamp(state.lastRunAt)),
                            .optionalDouble(timestamp(state.lastAttemptAt)), .optionalText(state.status),
                            .optionalText(state.message), .text(jsonStrings(state.consumed))
                        ]
                    )
                }
            }
        }
    }

    @discardableResult
    public func commitDocument(_ commit: SQLiteDocumentCommit) throws -> SQLiteDocument {
        try batch([commit]).first!
    }

    @discardableResult
    public func batch(_ commits: [SQLiteDocumentCommit]) throws -> [SQLiteDocument] {
        guard !commits.isEmpty else { return [] }
        return try locked {
            var results = [SQLiteDocument]()
            try transaction {
                for commit in commits {
                    guard var current = try readDocument(commit.id) else {
                        throw SQLiteLibraryError.missingDocument
                    }
                    guard current.revision == commit.baseRevision else {
                        throw SQLiteLibraryError.revisionConflict(current: current.revision)
                    }
                    if let title = commit.title?.trimmingCharacters(in: .whitespacesAndNewlines) {
                        guard !title.isEmpty else { throw SQLiteLibraryError.invalidDocument }
                        current.title = title
                    }
                    if let type = commit.type { current.type = type }
                    if let voiceBriefID = commit.voiceBriefID { current.voiceBriefID = voiceBriefID }
                    if let sourceURL = commit.sourceURL { current.sourceURL = sourceURL }
                    if let mediaURL = commit.mediaURL { current.mediaURL = mediaURL }
                    if let topicIDs = commit.topicIDs { current.topicIDs = topicIDs }
                    if let tags = commit.tags { current.tags = tags }
                    if let deleted = commit.deleted { current.deleted = deleted }
                    for (variant, body) in commit.texts {
                        current.texts[variant] = body.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                    current.revision += 1
                    current.updatedAt = Date()
                    try update(current)
                    try enqueue(
                        id: current.id,
                        revision: current.revision,
                        operation: current.deleted ? "delete" : "save"
                    )
                    results.append(current)
                }
            }
            return results
        }
    }

    public func outbox() throws -> [SQLiteOutboxItem] {
        try locked {
            try query(
                "SELECT record_type, record_id, revision, operation FROM cloud_outbox ORDER BY updated_at"
            ) { statement in
                SQLiteOutboxItem(
                    recordType: columnText(statement, 0),
                    documentID: columnText(statement, 1),
                    revision: sqlite3_column_int64(statement, 2),
                    operation: columnText(statement, 3)
                )
            }
        }
    }

    /// Seeds the durable upload queue on a new installation. A `true` result means an
    /// older build was interrupted after fetching CloudKit records but before recording
    /// that the queue was prepared, so the caller must reconcile the existing outbox.
    @discardableResult
    public func prepareInitialCloudUploadIfNeeded() throws -> Bool {
        try locked {
            let alreadyQueued = try query(
                "SELECT 1 FROM sync_state WHERE key = 'briefly-initial-upload' LIMIT 1"
            ) { _ in true }.first == true
            guard !alreadyQueued else { return false }

            let hasFetchedCloudRecords = try query(
                """
                SELECT 1 FROM documents WHERE cloud_record IS NOT NULL
                UNION ALL SELECT 1 FROM attachments WHERE cloud_record IS NOT NULL
                UNION ALL SELECT 1 FROM topics WHERE cloud_record IS NOT NULL
                UNION ALL SELECT 1 FROM channels WHERE cloud_record IS NOT NULL
                UNION ALL SELECT 1 FROM voice_briefs WHERE cloud_record IS NOT NULL
                LIMIT 1
                """
            ) { _ in true }.first == true
            guard !hasFetchedCloudRecords else { return true }

            try transaction {
                let documents = try query(
                    "SELECT id, revision, deleted FROM documents"
                ) {
                    (columnText($0, 0), sqlite3_column_int64($0, 1), sqlite3_column_int($0, 2) != 0)
                }
                for (id, revision, deleted) in documents {
                    try enqueue(
                        id: id,
                        revision: revision,
                        operation: deleted ? "delete" : "save"
                    )
                }

                let logicalTables = [
                    ("topic", "topics"),
                    ("channel", "channels"),
                    ("voice_brief", "voice_briefs")
                ]
                for (recordType, table) in logicalTables {
                    let records = try query(
                        "SELECT id, revision, deleted_at IS NOT NULL FROM \(table)"
                    ) {
                        (columnText($0, 0), sqlite3_column_int64($0, 1), sqlite3_column_int($0, 2) != 0)
                    }
                    for (id, revision, deleted) in records {
                        try enqueue(
                            recordType: recordType,
                            id: id,
                            revision: revision,
                            operation: deleted ? "delete" : "save"
                        )
                    }
                }

                let attachments = try query(
                    "SELECT id, revision FROM attachments WHERE deleted_at IS NULL"
                ) {
                    (columnText($0, 0), sqlite3_column_int64($0, 1))
                }
                for (id, revision) in attachments {
                    try enqueue(
                        recordType: "attachment",
                        id: id,
                        revision: revision,
                        operation: "save"
                    )
                }
                try markInitialCloudUploadPrepared()
            }
            return false
        }
    }

    public func markInitialCloudUploadPrepared() throws {
        try locked {
            try run(
                "INSERT INTO sync_state(key, value) VALUES('briefly-initial-upload', ?) " +
                    "ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                bindings: [.blob(Data([1]))]
            )
        }
    }

    public func cloudRecordData(recordType: String, id: String) throws -> Data? {
        try locked {
            let table: String
            switch recordType {
            case "document": table = "documents"
            case "attachment": table = "attachments"
            case "topic": table = "topics"
            case "channel": table = "channels"
            case "voice_brief": table = "voice_briefs"
            default: throw SQLiteLibraryError.invalidDocument
            }
            return try query(
                "SELECT cloud_record FROM \(table) WHERE id = ?",
                bindings: [.text(id)],
                transform: { columnOptionalBlob($0, 0) }
            ).first ?? nil
        }
    }

    public func logicalRecord(recordType: String, id: String) throws -> SQLiteLogicalRecord {
        try locked {
            switch recordType {
            case "topic":
                guard let row = try query(
                    "SELECT title, revision, deleted_at, cloud_record FROM topics WHERE id = ?",
                    bindings: [.text(id)],
                    transform: { (columnText($0, 0), sqlite3_column_int64($0, 1),
                        sqlite3_column_type($0, 2) != SQLITE_NULL, columnOptionalBlob($0, 3)) }
                ).first
                else { throw SQLiteLibraryError.invalidDocument }
                return SQLiteLogicalRecord(
                    id: id, revision: row.1, deleted: row.2,
                    payload: try JSONSerialization.data(withJSONObject: ["title": row.0]),
                    cloudRecordData: row.3
                )
            case "channel":
                guard let row = try query(
                    "SELECT source_url, title, kind, schedule, retrieval_count, revision, deleted_at, " +
                        "cloud_record FROM channels WHERE id = ?",
                    bindings: [.text(id)],
                    transform: { (columnText($0, 0), columnOptionalText($0, 1),
                        columnOptionalText($0, 2), columnText($0, 3),
                        Int(sqlite3_column_int($0, 4)), sqlite3_column_int64($0, 5),
                        sqlite3_column_type($0, 6) != SQLITE_NULL, columnOptionalBlob($0, 7)) }
                ).first
                else { throw SQLiteLibraryError.invalidDocument }
                var payload: [String: Any] = [
                    "sourceURL": row.0, "schedule": row.3, "retrievalCount": row.4
                ]
                if let title = row.1 { payload["title"] = title }
                if let kind = row.2 { payload["kind"] = kind }
                return SQLiteLogicalRecord(
                    id: id, revision: row.5, deleted: row.6,
                    payload: try JSONSerialization.data(withJSONObject: payload),
                    cloudRecordData: row.7
                )
            case "voice_brief":
                guard let row = try query(
                    "SELECT title, prompt, prioritize_for_me, schedule, length, revision, " +
                        "deleted_at, cloud_record FROM voice_briefs WHERE id = ?",
                    bindings: [.text(id)],
                    transform: { (columnText($0, 0), columnText($0, 1),
                        sqlite3_column_int($0, 2) != 0, columnText($0, 3), columnText($0, 4),
                        sqlite3_column_int64($0, 5), sqlite3_column_type($0, 6) != SQLITE_NULL,
                        columnOptionalBlob($0, 7)) }
                ).first
                else { throw SQLiteLibraryError.invalidDocument }
                let sources = try query(
                    "SELECT channel_id FROM voice_brief_sources WHERE voice_brief_id = ? ORDER BY channel_id",
                    bindings: [.text(id)], transform: { columnText($0, 0) }
                )
                return SQLiteLogicalRecord(
                    id: id, revision: row.5, deleted: row.6,
                    payload: try JSONSerialization.data(withJSONObject: [
                        "title": row.0, "prompt": row.1, "prioritizeForMe": row.2,
                        "schedule": row.3, "length": row.4, "sources": sources
                    ]), cloudRecordData: row.7
                )
            default:
                throw SQLiteLibraryError.invalidDocument
            }
        }
    }

    public func saveLogicalCloudRecordData(
        recordType: String, id: String, revision: Int64, data: Data
    ) throws {
        let table = try Self.logicalTable(recordType)
        try locked {
            try run(
                "UPDATE \(table) SET cloud_record = ? WHERE id = ? AND revision = ?",
                bindings: [.blob(data), .text(id), .int(revision)]
            )
            try acknowledgeOutbox(recordType: recordType, id: id, revision: revision)
        }
    }

    public func applyRemote(
        recordType: String,
        id: String,
        revision: Int64,
        deleted: Bool,
        payload: Data,
        cloudRecordData: Data
    ) throws {
        let object = try JSONSerialization.jsonObject(with: payload) as? [String: Any] ?? [:]
        let table = try Self.logicalTable(recordType)
        try locked {
            try transaction {
                let current = try query(
                    "SELECT revision FROM \(table) WHERE id = ?",
                    bindings: [.text(id)], transform: { sqlite3_column_int64($0, 0) }
                ).first ?? 0
                guard revision >= current else {
                    try run(
                        "UPDATE \(table) SET cloud_record = ? WHERE id = ?",
                        bindings: [.blob(cloudRecordData), .text(id)]
                    )
                    return
                }
                let deletedAt: Binding = deleted
                    ? .double(Date().timeIntervalSince1970)
                    : .optionalDouble(nil)
                switch recordType {
                case "topic":
                    guard let title = object["title"] as? String else {
                        throw SQLiteLibraryError.invalidDocument
                    }
                    try run(
                        "INSERT INTO topics(id,title,revision,deleted_at,cloud_record) VALUES(?,?,?,?,?) " +
                            "ON CONFLICT(id) DO UPDATE SET title=excluded.title,revision=excluded.revision," +
                            "deleted_at=excluded.deleted_at,cloud_record=excluded.cloud_record",
                        bindings: [.text(id), .text(title), .int(revision), deletedAt, .blob(cloudRecordData)]
                    )
                case "channel":
                    guard let source = object["sourceURL"] as? String else {
                        throw SQLiteLibraryError.invalidDocument
                    }
                    try run(
                        "INSERT INTO channels(id,source_url,title,kind,schedule,retrieval_count,revision," +
                            "deleted_at,cloud_record) VALUES(?,?,?,?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET " +
                            "source_url=excluded.source_url,title=excluded.title,kind=excluded.kind," +
                            "schedule=excluded.schedule,retrieval_count=excluded.retrieval_count," +
                            "revision=excluded.revision," +
                            "deleted_at=excluded.deleted_at,cloud_record=excluded.cloud_record",
                        bindings: [
                            .text(id), .text(source), .optionalText(object["title"] as? String),
                            .optionalText(object["kind"] as? String),
                            .text(object["schedule"] as? String ?? "manual"),
                            .int(Int64(object["retrievalCount"] as? Int ?? 5)), .int(revision),
                            deletedAt, .blob(cloudRecordData)
                        ]
                    )
                case "voice_brief":
                    guard let title = object["title"] as? String,
                          let prompt = object["prompt"] as? String,
                          let schedule = object["schedule"] as? String,
                          let length = object["length"] as? String
                    else { throw SQLiteLibraryError.invalidDocument }
                    try run(
                        "INSERT INTO voice_briefs(id,title,prompt,prioritize_for_me,schedule,length," +
                            "revision,deleted_at,cloud_record) VALUES(?,?,?,?,?,?,?,?,?) " +
                            "ON CONFLICT(id) DO UPDATE SET title=excluded.title,prompt=excluded.prompt," +
                            "prioritize_for_me=excluded.prioritize_for_me,schedule=excluded.schedule," +
                            "length=excluded.length,revision=excluded.revision," +
                            "deleted_at=excluded.deleted_at,cloud_record=excluded.cloud_record",
                        bindings: [
                            .text(id), .text(title), .text(prompt),
                            .int((object["prioritizeForMe"] as? Bool ?? false) ? 1 : 0),
                            .text(schedule), .text(length), .int(revision), deletedAt,
                            .blob(cloudRecordData)
                        ]
                    )
                    try run(
                        "DELETE FROM voice_brief_sources WHERE voice_brief_id = ?",
                        bindings: [.text(id)]
                    )
                    for source in object["sources"] as? [String] ?? [] {
                        try run(
                            "INSERT OR IGNORE INTO channels(id,source_url) VALUES(?,?)",
                            bindings: [.text(source), .text(source)]
                        )
                        try run(
                            "INSERT OR IGNORE INTO voice_brief_sources(voice_brief_id,channel_id) VALUES(?,?)",
                            bindings: [.text(id), .text(source)]
                        )
                    }
                default:
                    throw SQLiteLibraryError.invalidDocument
                }
                try acknowledgeOutbox(recordType: recordType, id: id, revision: revision)
            }
        }
    }

    public func saveAttachment(
        documentID: String,
        kind: String,
        mimeType: String,
        data: Data
    ) throws {
        try locked {
            try transaction {
                let id = "\(documentID):\(kind)"
                let revision = (try query(
                    "SELECT revision FROM attachments WHERE id = ?",
                    bindings: [.text(id)], transform: { sqlite3_column_int64($0, 0) }
                ).first ?? 0) + 1
                try run(
                    """
                    INSERT INTO attachments(id, document_id, kind, mime_type, data, revision)
                    VALUES(?, ?, ?, ?, ?, ?) ON CONFLICT(id) DO UPDATE SET
                      mime_type = excluded.mime_type, data = excluded.data,
                      revision = excluded.revision, deleted_at = NULL
                    """,
                    bindings: [
                        .text(id), .text(documentID), .text(kind), .text(mimeType),
                        .blob(data), .int(revision)
                    ]
                )
                try enqueue(recordType: "attachment", id: id, revision: revision, operation: "save")
            }
        }
    }

    public func attachment(documentID: String, kind: String) throws -> (String, Data)? {
        try locked {
            try query(
                "SELECT mime_type, data FROM attachments WHERE document_id = ? " +
                    "AND kind = ? AND deleted_at IS NULL",
                bindings: [.text(documentID), .text(kind)],
                transform: { (columnText($0, 0), columnBlob($0, 1)) }
            ).first
        }
    }

    public func attachmentMetadata() throws -> [SQLiteAttachmentMetadata] {
        try locked {
            try query(
                "SELECT document_id, kind, mime_type FROM attachments " +
                    "WHERE deleted_at IS NULL"
            ) {
                SQLiteAttachmentMetadata(
                    documentID: columnText($0, 0),
                    kind: columnText($0, 1),
                    mimeType: columnText($0, 2)
                )
            }
        }
    }

    public func attachment(_ id: String) throws -> SQLiteAttachment? {
        try locked {
            try query(
                "SELECT id, document_id, kind, mime_type, data, revision, cloud_record " +
                    "FROM attachments WHERE id = ? AND deleted_at IS NULL",
                bindings: [.text(id)]
            ) {
                SQLiteAttachment(
                    id: columnText($0, 0), documentID: columnText($0, 1),
                    kind: columnText($0, 2), mimeType: columnText($0, 3),
                    data: columnBlob($0, 4), revision: sqlite3_column_int64($0, 5),
                    cloudRecordData: columnOptionalBlob($0, 6)
                )
            }.first
        }
    }

    public func applyRemote(_ attachment: SQLiteAttachment) throws {
        try locked {
            try transaction {
                let currentRevision = try query(
                    "SELECT revision FROM attachments WHERE id = ?",
                    bindings: [.text(attachment.id)],
                    transform: { sqlite3_column_int64($0, 0) }
                ).first ?? 0
                guard attachment.revision >= currentRevision else {
                    try run(
                        "UPDATE attachments SET cloud_record = ? WHERE id = ?",
                        bindings: [
                            .optionalBlob(attachment.cloudRecordData), .text(attachment.id)
                        ]
                    )
                    return
                }
                try run(
                    """
                    INSERT INTO attachments(
                      id, document_id, kind, mime_type, data, revision, cloud_record
                    ) VALUES(?, ?, ?, ?, ?, ?, ?) ON CONFLICT(id) DO UPDATE SET
                      document_id = excluded.document_id, kind = excluded.kind,
                      mime_type = excluded.mime_type, data = excluded.data,
                      revision = excluded.revision, deleted_at = NULL,
                      cloud_record = excluded.cloud_record
                    """,
                    bindings: [
                        .text(attachment.id), .text(attachment.documentID), .text(attachment.kind),
                        .text(attachment.mimeType), .blob(attachment.data), .int(attachment.revision),
                        .optionalBlob(attachment.cloudRecordData)
                    ]
                )
                try acknowledgeOutbox(
                    recordType: "attachment", id: attachment.id, revision: attachment.revision
                )
            }
        }
    }

    public func saveAttachmentCloudRecordData(
        id: String,
        revision: Int64,
        data: Data
    ) throws {
        try locked {
            try run(
                "UPDATE attachments SET cloud_record = ? WHERE id = ? AND revision = ?",
                bindings: [.blob(data), .text(id), .int(revision)]
            )
            try acknowledgeOutbox(recordType: "attachment", id: id, revision: revision)
        }
    }

    public func acknowledgeOutbox(documentID: String, revision: Int64) throws {
        try acknowledgeOutbox(recordType: "document", id: documentID, revision: revision)
    }

    public func acknowledgeOutbox(recordType: String, id: String, revision: Int64) throws {
        try locked {
            try run(
                "DELETE FROM cloud_outbox WHERE record_type = ? " +
                    "AND record_id = ? AND revision <= ?",
                bindings: [.text(recordType), .text(id), .int(revision)]
            )
        }
    }

    public func saveCloudRecordData(
        documentID: String,
        revision: Int64,
        data: Data
    ) throws {
        try locked {
            try run(
                "UPDATE documents SET cloud_record = ? WHERE id = ? AND revision = ?",
                bindings: [.blob(data), .text(documentID), .int(revision)]
            )
            try acknowledgeOutbox(documentID: documentID, revision: revision)
        }
    }

    /// Applies a CloudKit record only when it is newer. Remote changes never enter the outbox.
    public func applyRemote(_ document: SQLiteDocument) throws {
        try locked {
            try transaction {
                if let current = try readDocument(document.id) {
                    guard current.revision < document.revision ||
                        (current.revision == document.revision && current.updatedAt < document.updatedAt)
                    else {
                        try run(
                            "UPDATE documents SET cloud_record = ? WHERE id = ?",
                            bindings: [.optionalBlob(document.cloudRecordData), .text(document.id)]
                        )
                        return
                    }
                    // Keep the parent row alive while replacing its contents. Channel items
                    // can reference this document, so a delete-and-insert replacement violates
                    // their foreign key even though it occurs within one transaction.
                    try update(document)
                } else {
                    try insert(document)
                }
                try acknowledgeOutbox(documentID: document.id, revision: document.revision)
            }
        }
    }

    public func saveSyncState(_ data: Data) throws {
        try locked {
            try run(
                "INSERT INTO sync_state(key, value) VALUES('cksyncengine', ?) " +
                    "ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                bindings: [.blob(data)]
            )
        }
    }

    public func syncState() throws -> Data? {
        try locked {
            try query("SELECT value FROM sync_state WHERE key = 'cksyncengine'") { statement in
                columnBlob(statement, 0)
            }.first
        }
    }

    @discardableResult
    public func ingestMarkdownLibrary(_ root: URL) throws -> Int {
        let library = root.appending(path: "library", directoryHint: .isDirectory)
        let urls = try FileManager.default.contentsOfDirectory(
            at: library,
            includingPropertiesForKeys: [.creationDateKey],
            options: [.skipsHiddenFiles]
        ).filter { $0.pathExtension.lowercased() == "md" }
        return try locked {
            var imported = 0
            try transaction {
                for url in urls {
                    let raw = try String(contentsOf: url, encoding: .utf8)
                    let parsed = parseMarkdown(raw)
                    let captureID = parsed.scalar("id") ?? "legacy:\(url.lastPathComponent)"
                    let id = "personal:\(captureID)"
                    let exists = try readDocument(id) != nil
                    var texts = [LibraryVariant.source: parsed.body]
                    for variant in [LibraryVariant.brief, .concise, .detailed, .comprehensive] {
                        let summary = library
                            .appending(path: "summaries", directoryHint: .isDirectory)
                            .appending(path: variant.rawValue, directoryHint: .isDirectory)
                            .appending(path: url.lastPathComponent)
                        if let text = try? String(contentsOf: summary, encoding: .utf8) {
                            texts[variant] = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        }
                    }
                    let resources = try url.resourceValues(forKeys: [.creationDateKey])
                    let createdAt = parsed.scalar("created_at").flatMap(Self.date) ??
                        resources.creationDate ?? Date()
                    if !exists {
                        try insert(SQLiteDocument(
                            id: id,
                            captureID: captureID,
                            type: parsed.scalar("type") ?? "document",
                            voiceBriefID: parsed.scalar("voice_brief_id"),
                            title: parsed.scalar("title") ?? firstHeading(parsed.body) ??
                                url.deletingPathExtension().lastPathComponent,
                            sourceURL: parsed.scalar("source_url"),
                            createdAt: createdAt,
                            updatedAt: parsed.scalar("updated_at").flatMap(Self.date) ?? createdAt,
                            topicIDs: parsed.array("topics"),
                            tags: parsed.array("tags"),
                            sourceIDs: parsed.array("source_ids"),
                            sourceURLs: parsed.array("source_urls"),
                            texts: texts
                        ))
                        try enqueue(id: id, revision: 1, operation: "save")
                        imported += 1
                    }
                    try importAttachment(
                        documentID: id, kind: "audio",
                        relativePath: parsed.scalar("audio_path"), library: library
                    )
                    try importAttachment(
                        documentID: id, kind: "favicon",
                        relativePath: parsed.scalar("favicon_path"), library: library
                    )
                }
            }
            return imported
        }
    }

    private func importAttachment(
        documentID: String,
        kind: String,
        relativePath: String?,
        library: URL
    ) throws {
        guard let relativePath, !relativePath.hasPrefix("/"), !relativePath.contains("..") else {
            return
        }
        let id = "\(documentID):\(kind)"
        guard try scalarInt(
            "SELECT count(*) FROM attachments WHERE id = \(sqlLiteral(id))"
        ) == 0 else { return }
        let url = library.appending(path: relativePath)
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return }
        let ext = url.pathExtension.lowercased()
        let mime: String
        if kind == "audio" {
            mime = ext == "m4a" ? "audio/mp4" : "audio/\(ext)"
        } else {
            mime = ext == "svg" ? "image/svg+xml" : ext == "jpg" ? "image/jpeg" : "image/\(ext)"
        }
        try run(
            "INSERT INTO attachments(id, document_id, kind, mime_type, data, revision) " +
                "VALUES(?, ?, ?, ?, ?, 1)",
            bindings: [.text(id), .text(documentID), .text(kind), .text(mime), .blob(data)]
        )
        try enqueue(recordType: "attachment", id: id, revision: 1, operation: "save")
    }

    private func insert(_ document: SQLiteDocument) throws {
        try run(
            """
            INSERT INTO documents(
                id, capture_id, type, voice_brief_id, title, source_url, media_url,
                created_at, updated_at, revision, deleted, cloud_record
            ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            bindings: documentBindings(document)
        )
        try replaceTopics(document.id, document.topicIDs)
        try replaceTags(document.id, document.tags)
        try replaceSources(document)
        for (variant, body) in document.texts { try upsertText(document.id, variant, body) }
        try updateStoredExcerpt(document)
        try refreshSearch(document)
    }

    private func update(_ document: SQLiteDocument) throws {
        try run(
            """
            UPDATE documents SET type = ?, voice_brief_id = ?, title = ?, source_url = ?,
                media_url = ?, updated_at = ?, revision = ?, deleted = ?, cloud_record = ? WHERE id = ?
            """,
            bindings: [
                .text(document.type), .optionalText(document.voiceBriefID), .text(document.title),
                .optionalText(document.sourceURL), .optionalText(document.mediaURL),
                .double(document.updatedAt.timeIntervalSince1970), .int(document.revision),
                .int(document.deleted ? 1 : 0), .optionalBlob(document.cloudRecordData),
                .text(document.id)
            ]
        )
        try replaceTopics(document.id, document.topicIDs)
        try replaceTags(document.id, document.tags)
        try replaceSources(document)
        for (variant, body) in document.texts { try upsertText(document.id, variant, body) }
        try updateStoredExcerpt(document)
        try refreshSearch(document)
    }

    private func readDocument(_ id: String) throws -> SQLiteDocument? {
        let documents = try query(
            """
            SELECT id, capture_id, type, voice_brief_id, title, source_url, created_at, updated_at,
                   media_url, revision, deleted, cloud_record FROM documents WHERE id = ?
            """,
            bindings: [.text(id)]
        ) { decodeDocument($0) }
        guard var document = documents.first else { return nil }
        document.topicIDs = try query(
            "SELECT topic_id FROM document_topics WHERE document_id = ? ORDER BY topic_id",
            bindings: [.text(id)], transform: { columnText($0, 0) }
        )
        document.tags = try query(
            "SELECT tag FROM document_tags WHERE document_id = ? ORDER BY tag",
            bindings: [.text(id)], transform: { columnText($0, 0) }
        )
        document.sourceIDs = try query(
            "SELECT source_document_id FROM document_source_documents WHERE document_id = ?",
            bindings: [.text(id)], transform: { columnText($0, 0) }
        )
        document.sourceURLs = try query(
            "SELECT source_url FROM document_source_urls WHERE document_id = ?",
            bindings: [.text(id)], transform: { columnText($0, 0) }
        )
        for (variant, body) in try query(
            "SELECT variant, body FROM document_texts WHERE document_id = ?",
            bindings: [.text(id)],
            transform: { (columnText($0, 0), columnText($0, 1)) }
        ) {
            if let variant = LibraryVariant(rawValue: variant) { document.texts[variant] = body }
        }
        return document
    }

    private func documents(where predicate: String?) throws -> [SQLiteDocument] {
        try locked {
            var documents = try documentMetadata(where: predicate)
            guard !documents.isEmpty else { return [] }
            let indices = documentIndices(documents)
            for (documentID, variant, body) in try query(
                relationSQL(
                    "document_texts",
                    columns: "r.variant, r.body",
                    order: "r.variant",
                    predicate: predicate
                ),
                transform: { (columnText($0, 0), columnText($0, 1), columnText($0, 2)) }
            ) {
                if let index = indices[documentID],
                   let variant = LibraryVariant(rawValue: variant) {
                    documents[index].texts[variant] = body
                }
            }
            return documents
        }
    }

    private func indexDocuments(where predicate: String?) throws -> [SQLiteDocumentIndex] {
        try locked {
            let documents = try documentMetadata(where: predicate)
            let excerpts = Dictionary(uniqueKeysWithValues: try query(
                "SELECT id, excerpt FROM documents" +
                    (predicate.map { " WHERE \($0)" } ?? ""),
                transform: { (columnText($0, 0), columnText($0, 1)) }
            ))
            var entries = documents.map {
                SQLiteDocumentIndex(
                    document: $0,
                    variants: [],
                    excerpt: excerpts[$0.id] ?? ""
                )
            }
            guard !entries.isEmpty else { return [] }
            let indices = documentIndices(documents)
            for (documentID, rawVariant) in try query(
                relationSQL(
                    "document_texts",
                    columns: "r.variant",
                    order: "r.variant",
                    predicate: predicate
                ),
                transform: { (columnText($0, 0), columnText($0, 1)) }
            ) {
                guard
                    let index = indices[documentID],
                    let variant = LibraryVariant(rawValue: rawVariant)
                else { continue }
                entries[index].variants.append(variant)
            }
            return entries
        }
    }

    private func documentMetadata(where predicate: String?) throws -> [SQLiteDocument] {
        let documentSQL =
            "SELECT id, capture_id, type, voice_brief_id, title, source_url, " +
            "created_at, updated_at, media_url, revision, deleted, cloud_record " +
            "FROM documents" +
            (predicate.map { " WHERE \($0)" } ?? "") +
            " ORDER BY updated_at DESC, id"
        var documents = try query(documentSQL) { decodeDocument($0) }
        guard !documents.isEmpty else { return [] }
        let indices = documentIndices(documents)

        for (documentID, topicID) in try query(
            relationSQL(
                "document_topics",
                columns: "r.topic_id",
                order: "r.topic_id",
                predicate: predicate
            ),
            transform: { (columnText($0, 0), columnText($0, 1)) }
        ) {
            if let index = indices[documentID] {
                documents[index].topicIDs.append(topicID)
            }
        }
        for (documentID, tag) in try query(
            relationSQL(
                "document_tags",
                columns: "r.tag",
                order: "r.tag",
                predicate: predicate
            ),
            transform: { (columnText($0, 0), columnText($0, 1)) }
        ) {
            if let index = indices[documentID] {
                documents[index].tags.append(tag)
            }
        }
        for (documentID, sourceID) in try query(
            relationSQL(
                "document_source_documents",
                columns: "r.source_document_id",
                order: "r.source_document_id",
                predicate: predicate
            ),
            transform: { (columnText($0, 0), columnText($0, 1)) }
        ) {
            if let index = indices[documentID] {
                documents[index].sourceIDs.append(sourceID)
            }
        }
        for (documentID, sourceURL) in try query(
            relationSQL(
                "document_source_urls",
                columns: "r.source_url",
                order: "r.source_url",
                predicate: predicate
            ),
            transform: { (columnText($0, 0), columnText($0, 1)) }
        ) {
            if let index = indices[documentID] {
                documents[index].sourceURLs.append(sourceURL)
            }
        }
        return documents
    }

    private func documentIndices(_ documents: [SQLiteDocument]) -> [String: Int] {
        Dictionary(uniqueKeysWithValues: documents.indices.map { (documents[$0].id, $0) })
    }

    private func relationSQL(
        _ table: String,
        columns: String,
        order: String,
        predicate: String?
    ) -> String {
        "SELECT r.document_id, \(columns) FROM \(table) r " +
            "JOIN documents d ON d.id = r.document_id" +
            (predicate.map { " WHERE \($0)" } ?? "") +
            " ORDER BY r.document_id, \(order)"
    }

    private func decodeDocument(_ statement: OpaquePointer) -> SQLiteDocument {
        SQLiteDocument(
            id: columnText(statement, 0),
            captureID: columnText(statement, 1),
            type: columnText(statement, 2),
            voiceBriefID: columnOptionalText(statement, 3),
            title: columnText(statement, 4),
            sourceURL: columnOptionalText(statement, 5),
            mediaURL: columnOptionalText(statement, 8),
            createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 6)),
            updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 7)),
            revision: sqlite3_column_int64(statement, 9),
            deleted: sqlite3_column_int(statement, 10) != 0,
            topicIDs: [],
            tags: [],
            sourceIDs: [],
            sourceURLs: [],
            texts: [:],
            cloudRecordData: columnOptionalBlob(statement, 11)
        )
    }

    private func upsertText(_ id: String, _ variant: LibraryVariant, _ body: String) throws {
        try run(
            "INSERT INTO document_texts(document_id, variant, body) VALUES(?, ?, ?) " +
                "ON CONFLICT(document_id, variant) DO UPDATE SET body = excluded.body",
            bindings: [.text(id), .text(variant.rawValue), .text(body)]
        )
    }

    private func updateStoredExcerpt(_ document: SQLiteDocument) throws {
        let body = document.texts[.brief] ?? document.texts[.concise] ??
            document.texts[.source] ?? ""
        try run(
            "UPDATE documents SET excerpt = ? WHERE id = ?",
            bindings: [.text(libraryExcerpt(body)), .text(document.id)]
        )
    }

    private func backfillExcerpts() throws {
        let rows = try query(
            """
            SELECT t.document_id, substr(t.body, 1, 4096)
            FROM document_texts t
            WHERE t.variant IN ('brief', 'concise', 'source')
            ORDER BY t.document_id,
              CASE t.variant WHEN 'brief' THEN 0 WHEN 'concise' THEN 1 ELSE 2 END
            """,
            transform: { (columnText($0, 0), columnText($0, 1)) }
        )
        var updated = Set<String>()
        for (documentID, body) in rows where updated.insert(documentID).inserted {
            try run(
                "UPDATE documents SET excerpt = ? WHERE id = ?",
                bindings: [.text(libraryExcerpt(body)), .text(documentID)]
            )
        }
    }

    private func replaceTopics(_ id: String, _ topicIDs: [String]) throws {
        try run("DELETE FROM document_topics WHERE document_id = ?", bindings: [.text(id)])
        for topicID in Set(topicIDs) {
            try run(
                "INSERT OR IGNORE INTO topics(id, title) VALUES(?, ?)",
                bindings: [.text(topicID), .text(topicID)]
            )
            try run(
                "INSERT INTO document_topics(document_id, topic_id) VALUES(?, ?)",
                bindings: [.text(id), .text(topicID)]
            )
        }
    }

    private func replaceTags(_ id: String, _ tags: [String]) throws {
        try run("DELETE FROM document_tags WHERE document_id = ?", bindings: [.text(id)])
        for tag in Set(tags) {
            try run(
                "INSERT INTO document_tags(document_id, tag) VALUES(?, ?)",
                bindings: [.text(id), .text(tag)]
            )
        }
    }

    private func replaceSources(_ document: SQLiteDocument) throws {
        try run(
            "DELETE FROM document_source_documents WHERE document_id = ?",
            bindings: [.text(document.id)]
        )
        try run(
            "DELETE FROM document_source_urls WHERE document_id = ?",
            bindings: [.text(document.id)]
        )
        for sourceID in Set(document.sourceIDs) {
            try run(
                "INSERT OR IGNORE INTO document_source_documents(document_id, source_document_id) " +
                    "VALUES(?, ?)",
                bindings: [.text(document.id), .text(sourceID)]
            )
        }
        for sourceURL in Set(document.sourceURLs) {
            try run(
                "INSERT INTO document_source_urls(document_id, source_url) VALUES(?, ?)",
                bindings: [.text(document.id), .text(sourceURL)]
            )
        }
    }

    private func refreshSearch(_ document: SQLiteDocument) throws {
        try run("DELETE FROM document_fts WHERE document_id = ?", bindings: [.text(document.id)])
        guard !document.deleted else { return }
        for (variant, body) in document.texts {
            try run(
                "INSERT INTO document_fts(document_id, variant, title, body) VALUES(?, ?, ?, ?)",
                bindings: [.text(document.id), .text(variant.rawValue), .text(document.title), .text(body)]
            )
        }
    }

    private func enqueue(
        recordType: String = "document",
        id: String,
        revision: Int64,
        operation: String
    ) throws {
        try run(
            """
            INSERT INTO cloud_outbox(record_type, record_id, revision, operation, updated_at)
            VALUES(?, ?, ?, ?, ?) ON CONFLICT(record_type, record_id) DO UPDATE SET
              revision = excluded.revision, operation = excluded.operation,
              updated_at = excluded.updated_at
            """,
            bindings: [
                .text(recordType), .text(id), .int(revision), .text(operation),
                .double(Date().timeIntervalSince1970)
            ]
        )
    }

    private func documentBindings(_ document: SQLiteDocument) -> [Binding] {
        [
            .text(document.id), .text(document.captureID), .text(document.type),
            .optionalText(document.voiceBriefID),
            .text(document.title), .optionalText(document.sourceURL), .optionalText(document.mediaURL),
            .double(document.createdAt.timeIntervalSince1970),
            .double(document.updatedAt.timeIntervalSince1970), .int(document.revision),
            .int(document.deleted ? 1 : 0), .optionalBlob(document.cloudRecordData)
        ]
    }

    private func locked<T>(_ operation: () throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        return try operation()
    }

    private func transaction(_ operation: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            try operation()
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func execute(_ sql: String) throws {
        var message: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(connection, sql, nil, nil, &message) == SQLITE_OK else {
            defer { sqlite3_free(message) }
            throw SQLiteLibraryError.database(
                message.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(connection))
            )
        }
    }

    private func run(_ sql: String, bindings: [Binding] = []) throws {
        _ = try query(sql, bindings: bindings) { _ in () }
    }

    private func scalarInt(_ sql: String) throws -> Int64 {
        try query(sql) { sqlite3_column_int64($0, 0) }.first ?? 0
    }

    private func query<T>(
        _ sql: String,
        bindings: [Binding] = [],
        transform: (OpaquePointer) throws -> T
    ) throws -> [T] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(connection, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { throw databaseError() }
        defer { sqlite3_finalize(statement) }
        for (index, binding) in bindings.enumerated() {
            try binding.apply(to: statement, index: Int32(index + 1), error: databaseError)
        }
        var values = [T]()
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW: values.append(try transform(statement))
            case SQLITE_DONE: return values
            default: throw databaseError()
            }
        }
    }

    private func databaseError() -> SQLiteLibraryError {
        .database(String(cString: sqlite3_errmsg(connection)))
    }

    private func sqlLiteral(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "''"))'"
    }

    private func timestamp(_ value: String?) -> Double? {
        value.flatMap { ISO8601DateFormatter().date(from: $0)?.timeIntervalSince1970 }
    }

    private func jsonStrings(_ values: [String]) -> String {
        String(data: try! JSONEncoder().encode(values), encoding: .utf8)!
    }

    private static func date(_ value: String) -> Date? {
        ISO8601DateFormatter().date(from: value)
    }

    private static func logicalTable(_ recordType: String) throws -> String {
        switch recordType {
        case "topic": "topics"
        case "channel": "channels"
        case "voice_brief": "voice_briefs"
        default: throw SQLiteLibraryError.invalidDocument
        }
    }

    private static let schema = """
    CREATE TABLE IF NOT EXISTS documents(
      id TEXT PRIMARY KEY,
      capture_id TEXT NOT NULL UNIQUE,
      type TEXT NOT NULL,
      voice_brief_id TEXT,
      title TEXT NOT NULL,
      source_url TEXT,
      media_url TEXT,
      excerpt TEXT NOT NULL DEFAULT '',
      created_at REAL NOT NULL,
      updated_at REAL NOT NULL,
      revision INTEGER NOT NULL CHECK(revision > 0),
      deleted INTEGER NOT NULL DEFAULT 0 CHECK(deleted IN (0, 1)),
      cloud_record BLOB
    );
    CREATE TABLE IF NOT EXISTS document_texts(
      document_id TEXT NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
      variant TEXT NOT NULL,
      body TEXT NOT NULL,
      PRIMARY KEY(document_id, variant)
    );
    CREATE TABLE IF NOT EXISTS topics(
      id TEXT PRIMARY KEY,
      title TEXT NOT NULL,
      revision INTEGER NOT NULL DEFAULT 1,
      deleted_at REAL,
      cloud_record BLOB
    );
    CREATE TABLE IF NOT EXISTS document_topics(
      document_id TEXT NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
      topic_id TEXT NOT NULL REFERENCES topics(id),
      PRIMARY KEY(document_id, topic_id)
    );
    CREATE TABLE IF NOT EXISTS document_tags(
      document_id TEXT NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
      tag TEXT NOT NULL,
      PRIMARY KEY(document_id, tag)
    );
    CREATE TABLE IF NOT EXISTS document_source_documents(
      document_id TEXT NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
      source_document_id TEXT NOT NULL,
      PRIMARY KEY(document_id, source_document_id)
    );
    CREATE TABLE IF NOT EXISTS document_source_urls(
      document_id TEXT NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
      source_url TEXT NOT NULL,
      PRIMARY KEY(document_id, source_url)
    );
    CREATE TABLE IF NOT EXISTS channels(
      id TEXT PRIMARY KEY,
      source_url TEXT NOT NULL UNIQUE,
      title TEXT,
      kind TEXT,
      schedule TEXT NOT NULL DEFAULT 'manual',
      retrieval_count INTEGER NOT NULL DEFAULT 5,
      revision INTEGER NOT NULL DEFAULT 1,
      deleted_at REAL,
      cloud_record BLOB
    );
    CREATE TABLE IF NOT EXISTS channel_state(
      channel_id TEXT PRIMARY KEY REFERENCES channels(id) ON DELETE CASCADE,
      last_checked_at REAL,
      pagination_cursor TEXT,
      last_error TEXT,
      can_load_more INTEGER NOT NULL DEFAULT 0
    );
    CREATE TABLE IF NOT EXISTS channel_items(
      channel_id TEXT NOT NULL REFERENCES channels(id) ON DELETE CASCADE,
      item_id TEXT NOT NULL,
      title TEXT NOT NULL,
      url TEXT NOT NULL,
      published_at REAL,
      content TEXT,
      linked_url TEXT,
      entry_id TEXT REFERENCES documents(id),
      seen_at REAL,
      ingested_at REAL,
      PRIMARY KEY(channel_id, item_id)
    );
    CREATE TABLE IF NOT EXISTS channel_seen(
      channel_id TEXT NOT NULL REFERENCES channels(id) ON DELETE CASCADE,
      item_id TEXT NOT NULL,
      seen_at REAL NOT NULL,
      PRIMARY KEY(channel_id, item_id)
    );
    CREATE TABLE IF NOT EXISTS voice_briefs(
      id TEXT PRIMARY KEY,
      title TEXT NOT NULL,
      prompt TEXT NOT NULL,
      prioritize_for_me INTEGER NOT NULL DEFAULT 0,
      schedule TEXT NOT NULL DEFAULT 'manual',
      length TEXT NOT NULL DEFAULT '',
      revision INTEGER NOT NULL DEFAULT 1,
      deleted_at REAL,
      cloud_record BLOB
    );
    CREATE TABLE IF NOT EXISTS voice_brief_sources(
      voice_brief_id TEXT NOT NULL REFERENCES voice_briefs(id) ON DELETE CASCADE,
      channel_id TEXT NOT NULL REFERENCES channels(id),
      PRIMARY KEY(voice_brief_id, channel_id)
    );
    CREATE TABLE IF NOT EXISTS voice_brief_runs(
      id TEXT PRIMARY KEY,
      voice_brief_id TEXT NOT NULL REFERENCES voice_briefs(id) ON DELETE CASCADE,
      started_at REAL NOT NULL,
      completed_at REAL,
      status TEXT NOT NULL,
      message TEXT,
      episode_document_id TEXT REFERENCES documents(id)
    );
    CREATE TABLE IF NOT EXISTS voice_brief_state(
      voice_brief_id TEXT PRIMARY KEY REFERENCES voice_briefs(id) ON DELETE CASCADE,
      last_run_at REAL,
      last_attempt_at REAL,
      status TEXT,
      message TEXT,
      consumed TEXT NOT NULL DEFAULT '[]'
    );
    CREATE TABLE IF NOT EXISTS voice_brief_consumed_items(
      voice_brief_id TEXT NOT NULL REFERENCES voice_briefs(id) ON DELETE CASCADE,
      channel_id TEXT NOT NULL,
      item_id TEXT NOT NULL,
      consumed_at REAL NOT NULL,
      PRIMARY KEY(voice_brief_id, channel_id, item_id),
      FOREIGN KEY(channel_id, item_id) REFERENCES channel_items(channel_id, item_id)
    );
    CREATE TABLE IF NOT EXISTS attachments(
      id TEXT PRIMARY KEY,
      document_id TEXT NOT NULL,
      kind TEXT NOT NULL,
      mime_type TEXT NOT NULL,
      data BLOB NOT NULL,
      revision INTEGER NOT NULL DEFAULT 1,
      deleted_at REAL,
      cloud_record BLOB
    );
    CREATE INDEX IF NOT EXISTS attachments_document_kind_idx
      ON attachments(document_id, kind, deleted_at);
    CREATE VIRTUAL TABLE IF NOT EXISTS document_fts USING fts5(
      document_id UNINDEXED, variant UNINDEXED, title, body,
      tokenize = 'unicode61 remove_diacritics 2'
    );
    CREATE TABLE IF NOT EXISTS cloud_outbox(
      record_type TEXT NOT NULL,
      record_id TEXT NOT NULL,
      revision INTEGER NOT NULL,
      operation TEXT NOT NULL CHECK(operation IN ('save', 'delete')),
      updated_at REAL NOT NULL,
      PRIMARY KEY(record_type, record_id)
    );
    CREATE TABLE IF NOT EXISTS sync_state(key TEXT PRIMARY KEY, value BLOB NOT NULL);
    """
}

private enum Binding {
    case text(String)
    case optionalText(String?)
    case int(Int64)
    case double(Double)
    case optionalDouble(Double?)
    case blob(Data)
    case optionalBlob(Data?)

    func apply(
        to statement: OpaquePointer,
        index: Int32,
        error: () -> SQLiteLibraryError
    ) throws {
        let result: Int32
        switch self {
        case .text(let value):
            result = sqlite3_bind_text(statement, index, value, -1, SQLITE_TRANSIENT)
        case .optionalText(let value):
            if let value {
                result = sqlite3_bind_text(statement, index, value, -1, SQLITE_TRANSIENT)
            } else {
                result = sqlite3_bind_null(statement, index)
            }
        case .int(let value): result = sqlite3_bind_int64(statement, index, value)
        case .double(let value): result = sqlite3_bind_double(statement, index, value)
        case .optionalDouble(let value):
            result = value.map { sqlite3_bind_double(statement, index, $0) } ??
                sqlite3_bind_null(statement, index)
        case .blob(let value):
            result = value.withUnsafeBytes {
                sqlite3_bind_blob(statement, index, $0.baseAddress, Int32(value.count), SQLITE_TRANSIENT)
            }
        case .optionalBlob(let value):
            if let value {
                result = value.withUnsafeBytes {
                    sqlite3_bind_blob(statement, index, $0.baseAddress, Int32(value.count), SQLITE_TRANSIENT)
                }
            } else {
                result = sqlite3_bind_null(statement, index)
            }
        }
        guard result == SQLITE_OK else { throw error() }
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

private func columnText(_ statement: OpaquePointer, _ index: Int32) -> String {
    sqlite3_column_text(statement, index).map { String(cString: $0) } ?? ""
}

private func columnOptionalText(_ statement: OpaquePointer, _ index: Int32) -> String? {
    sqlite3_column_type(statement, index) == SQLITE_NULL ? nil : columnText(statement, index)
}

private func columnOptionalDate(_ statement: OpaquePointer, _ index: Int32) -> String? {
    guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
    return ISO8601DateFormatter().string(
        from: Date(timeIntervalSince1970: sqlite3_column_double(statement, index))
    )
}

private func columnBlob(_ statement: OpaquePointer, _ index: Int32) -> Data {
    guard let bytes = sqlite3_column_blob(statement, index) else { return Data() }
    return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, index)))
}

private func columnOptionalBlob(_ statement: OpaquePointer, _ index: Int32) -> Data? {
    sqlite3_column_type(statement, index) == SQLITE_NULL ? nil : columnBlob(statement, index)
}

private func decodeStrings(_ value: String) -> [String] {
    (try? JSONDecoder().decode([String].self, from: Data(value.utf8))) ?? []
}
