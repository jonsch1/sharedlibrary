import Foundation
import SQLite3

extension SQLiteLibrary {
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
                    ("channel", "channels")
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

    /// Re-uploads channel-derived documents once so older libraries gain the channel
    /// provenance added to the cloud document payload.
    public func prepareChannelProvenanceUploadIfNeeded() throws {
        try locked {
            let key = "briefly-channel-provenance-upload-v1"
            let prepared = try query(
                "SELECT 1 FROM sync_state WHERE key = ? LIMIT 1",
                bindings: [.text(key)],
                transform: { _ in true }
            ).first == true
            guard !prepared else { return }
            try transaction {
                let documents = try query(
                    """
                    SELECT DISTINCT d.id, d.revision
                    FROM documents d JOIN channel_items ci ON ci.entry_id = d.id
                    WHERE ci.accepted_at IS NOT NULL
                      AND d.deleted = 0
                    """
                ) { (columnText($0, 0), sqlite3_column_int64($0, 1)) }
                for (id, revision) in documents {
                    try enqueue(id: id, revision: revision, operation: "save")
                }
                try run(
                    "INSERT INTO sync_state(key, value) VALUES(?, ?)",
                    bindings: [.text(key), .blob(Data([1]))]
                )
            }
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
                    "SELECT source_url, group_id, group_title, title, kind, schedule, " +
                        "review_limit, revision, deleted_at, " +
                        "cloud_record FROM channels WHERE id = ?",
                    bindings: [.text(id)],
                    transform: { (columnText($0, 0), columnOptionalText($0, 1),
                        columnOptionalText($0, 2), columnOptionalText($0, 3),
                        columnOptionalText($0, 4), columnText($0, 5),
                        Int(sqlite3_column_int($0, 6)), sqlite3_column_int64($0, 7),
                        sqlite3_column_type($0, 8) != SQLITE_NULL, columnOptionalBlob($0, 9)) }
                ).first
                else { throw SQLiteLibraryError.invalidDocument }
                var payload: [String: Any] = [
                    "sourceURL": row.0, "groupID": row.1 ?? row.0,
                    "schedule": row.5, "reviewLimit": row.6
                ]
                if let groupTitle = row.2 { payload["groupTitle"] = groupTitle }
                if let title = row.3 { payload["title"] = title }
                if let kind = row.4 { payload["kind"] = kind }
                return SQLiteLogicalRecord(
                    id: id, revision: row.7, deleted: row.8,
                    payload: try JSONSerialization.data(withJSONObject: payload),
                    cloudRecordData: row.9
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
                        "INSERT INTO channels(id,source_url,group_id,group_title,title,kind,schedule," +
                            "review_limit,revision,deleted_at,cloud_record) " +
                            "VALUES(?,?,?,?,?,?,?,?,?,?,?) " +
                            "ON CONFLICT(id) DO UPDATE SET source_url=excluded.source_url," +
                            "group_id=excluded.group_id,group_title=excluded.group_title," +
                            "title=excluded.title,kind=excluded.kind," +
                            "schedule=excluded.schedule,review_limit=excluded.review_limit," +
                            "revision=excluded.revision," +
                            "deleted_at=excluded.deleted_at,cloud_record=excluded.cloud_record",
                        bindings: [
                            .text(id), .text(source),
                            .text(object["groupID"] as? String ?? source),
                            .optionalText(object["groupTitle"] as? String),
                            .optionalText(object["title"] as? String),
                            .optionalText(object["kind"] as? String),
                            .text(object["schedule"] as? String ?? "manual"),
                            .int(Int64(min(50, max(1, object["reviewLimit"] as? Int ?? 50)))),
                            .int(revision),
                            deletedAt, .blob(cloudRecordData)
                        ]
                    )
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
                guard try readDocument(documentID)?.isPermanentlyDeleted != true else {
                    throw SQLiteLibraryError.missingDocument
                }
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
                if try rejectAttachmentForPurgedDocument(attachment) { return }
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
    public func applyRemote(_ value: SQLiteDocument) throws {
        var document = value
        document.type = normalizedDocumentType(document.type)
        document.tags = normalizedDocumentTags(document.tags)
        try locked {
            try transaction {
                if document.isPermanentlyDeleted {
                    if var current = try readDocument(document.id), current.isPermanentlyDeleted,
                       current.revision > document.revision {
                        current.cloudRecordData = document.cloudRecordData
                        try update(current)
                        return
                    }
                    try eraseDocumentContent(document)
                    try acknowledgeOutbox(documentID: document.id, revision: document.revision)
                    return
                }
                if let current = try readDocument(document.id) {
                    if current.isPermanentlyDeleted {
                        // Keep deletion authoritative, even if a disconnected device edited the old item.
                        var marker = current
                        marker.revision = max(current.revision, document.revision) + 1
                        marker.cloudRecordData = document.cloudRecordData
                        try update(marker)
                        try enqueue(id: marker.id, revision: marker.revision, operation: "delete")
                        return
                    }
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
                    try run(
                        "DELETE FROM document_texts WHERE document_id = ?",
                        bindings: [.text(document.id)]
                    )
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

}
