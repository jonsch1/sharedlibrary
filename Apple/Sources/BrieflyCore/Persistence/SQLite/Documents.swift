import Foundation
import SQLite3

extension SQLiteLibrary {
    public func isEmpty() throws -> Bool {
        try locked { try scalarInt("SELECT count(*) FROM documents") == 0 }
    }

    public func createDocument(
        title: String,
        body: String,
        texts requestedTexts: [LibraryVariant: String]? = nil,
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
        let texts = requestedTexts.map { values in
            values.reduce(into: [LibraryVariant: String]()) { result, value in
                let text = value.value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { result[value.key] = text }
            }
        } ?? [.source: trimmed]
        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !texts.isEmpty, !normalizedTitle.isEmpty else {
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
            texts: texts
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
                SELECT id, title, prioritize_for_me, schedule, length
                FROM voice_briefs WHERE deleted_at IS NULL ORDER BY title COLLATE NOCASE
                """
            ) { statement in
                (
                    columnText(statement, 0), columnText(statement, 1),
                    sqlite3_column_int(statement, 2) != 0,
                    columnText(statement, 3), columnText(statement, 4)
                )
            }
            return try rows.map { id, title, prioritize, schedule, length in
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
                      id, title, prioritize_for_me, schedule, length, revision
                    ) VALUES(?, ?, ?, ?, ?, ?) ON CONFLICT(id) DO UPDATE SET
                      title = excluded.title,
                      prioritize_for_me = excluded.prioritize_for_me,
                      schedule = excluded.schedule, length = excluded.length,
                      revision = excluded.revision, deleted_at = NULL
                    """,
                    bindings: [
                        .text(id), .text(draft.title),
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

    func insert(_ document: SQLiteDocument) throws {
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

    func update(_ document: SQLiteDocument) throws {
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

    func readDocument(_ id: String) throws -> SQLiteDocument? {
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

    func documents(where predicate: String?) throws -> [SQLiteDocument] {
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

    func indexDocuments(where predicate: String?) throws -> [SQLiteDocumentIndex] {
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

    func documentMetadata(where predicate: String?) throws -> [SQLiteDocument] {
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

    func documentIndices(_ documents: [SQLiteDocument]) -> [String: Int] {
        Dictionary(uniqueKeysWithValues: documents.indices.map { (documents[$0].id, $0) })
    }

    func relationSQL(
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

    func decodeDocument(_ statement: OpaquePointer) -> SQLiteDocument {
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

    func upsertText(_ id: String, _ variant: LibraryVariant, _ body: String) throws {
        try run(
            "INSERT INTO document_texts(document_id, variant, body) VALUES(?, ?, ?) " +
                "ON CONFLICT(document_id, variant) DO UPDATE SET body = excluded.body",
            bindings: [.text(id), .text(variant.rawValue), .text(body)]
        )
    }

    func updateStoredExcerpt(_ document: SQLiteDocument) throws {
        let body = document.texts[.concise] ?? document.texts[.detailed] ??
            document.texts[.source] ?? ""
        try run(
            "UPDATE documents SET excerpt = ? WHERE id = ?",
            bindings: [.text(libraryExcerpt(body)), .text(document.id)]
        )
    }

    func backfillExcerpts() throws {
        let rows = try query(
            """
            SELECT t.document_id, substr(t.body, 1, 4096)
            FROM document_texts t
            WHERE t.variant IN ('concise', 'detailed', 'source')
            ORDER BY t.document_id,
              CASE t.variant WHEN 'concise' THEN 0 WHEN 'detailed' THEN 1 ELSE 2 END
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

    func replaceTopics(_ id: String, _ topicIDs: [String]) throws {
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

    func replaceTags(_ id: String, _ tags: [String]) throws {
        try run("DELETE FROM document_tags WHERE document_id = ?", bindings: [.text(id)])
        for tag in Set(tags) {
            try run(
                "INSERT INTO document_tags(document_id, tag) VALUES(?, ?)",
                bindings: [.text(id), .text(tag)]
            )
        }
    }

    func replaceSources(_ document: SQLiteDocument) throws {
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

    func refreshSearch(_ document: SQLiteDocument) throws {
        try run("DELETE FROM document_fts WHERE document_id = ?", bindings: [.text(document.id)])
        guard !document.deleted else { return }
        for (variant, body) in document.texts {
            try run(
                "INSERT INTO document_fts(document_id, variant, title, body) VALUES(?, ?, ?, ?)",
                bindings: [.text(document.id), .text(variant.rawValue), .text(document.title), .text(body)]
            )
        }
    }

    func enqueue(
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

}
