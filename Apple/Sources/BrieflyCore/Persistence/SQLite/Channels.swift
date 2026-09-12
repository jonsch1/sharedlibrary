import Foundation
import SQLite3

extension SQLiteLibrary {
    public func channelSources(documentID: String) throws -> [String] {
        try locked {
            try query(
                "SELECT DISTINCT c.source_url FROM channel_items ci " +
                    "JOIN channels c ON c.id = ci.channel_id " +
                    "WHERE ci.entry_id = ? AND ci.accepted_at IS NOT NULL " +
                    "AND c.deleted_at IS NULL ORDER BY c.source_url",
                bindings: [.text(documentID)],
                transform: { columnText($0, 0) }
            )
        }
    }

    /// Rebuilds only the accepted-item relationship carried by a cloud
    /// document. The document itself is synced separately.
    public func restoreCloudChannelSources(_ sources: [String], for documentID: String) throws {
        try locked {
            guard let document = try readDocument(documentID), !document.deleted else { return }
            try transaction {
                for source in Set(sources) {
                    try run(
                        "INSERT OR IGNORE INTO channels(id, source_url, review_limit) VALUES(?, ?, ?)",
                        bindings: [
                            .text(source), .text(source), .int(Int64(defaultChannelReviewLimit))
                        ]
                    )
                    try run(
                        """
                        INSERT INTO channel_items(
                          channel_id, item_id, title, url, entry_id, accepted_at, ingested_at
                        ) VALUES(?, ?, ?, ?, ?, ?, ?)
                        ON CONFLICT(channel_id, item_id) DO UPDATE SET
                          title = excluded.title, url = excluded.url,
                          entry_id = excluded.entry_id, accepted_at = excluded.accepted_at,
                          ingested_at = excluded.ingested_at
                        """,
                        bindings: [
                            .text(source), .text(documentID), .text(document.title),
                            .text(document.sourceURL ?? source), .text(documentID),
                            .double(document.createdAt.timeIntervalSince1970),
                            .double(document.createdAt.timeIntervalSince1970)
                        ]
                    )
                    try run(
                        "INSERT OR IGNORE INTO channel_seen(channel_id, item_id, seen_at) VALUES(?, ?, ?)",
                        bindings: [
                            .text(source), .text(documentID),
                            .double(document.createdAt.timeIntervalSince1970)
                        ]
                    )
                }
            }
        }
    }

    public func channelRecords() throws -> [SQLiteChannelRecord] {
        try locked {
            let rows = try query(
                """
                SELECT c.source_url, COALESCE(c.group_id, c.source_url), c.group_title,
                       c.title, c.kind, c.schedule, s.last_checked_at,
                       s.last_error, c.review_limit, s.can_load_more
                FROM channels c LEFT JOIN channel_state s ON s.channel_id = c.id
                WHERE c.deleted_at IS NULL ORDER BY c.source_url
                """
            ) { statement in
                (
                    columnText(statement, 0), columnText(statement, 1),
                    columnOptionalText(statement, 2), columnOptionalText(statement, 3),
                    columnOptionalText(statement, 4), columnText(statement, 5),
                    columnOptionalDate(statement, 6), columnOptionalText(statement, 7),
                    Int(sqlite3_column_int(statement, 8)), sqlite3_column_int(statement, 9) != 0
                )
            }
            return try rows.map {
                source, groupID, groupTitle, title, kind, schedule, checked, error, reviewLimit, more in
                let items = try query(
                    """
                    SELECT item_id, title, url, published_at, content, linked_url,
                           preferred_input, media_url, transcript_url, transcript_type,
                           transcript_language, entry_id, accepted_at, ingested_at
                    FROM channel_items
                    WHERE channel_id = ? ORDER BY ingested_at DESC, item_id
                    """,
                    bindings: [.text(source)]
                ) {
                    LibraryChannelItem(
                        id: columnText($0, 0), title: columnText($0, 1),
                        url: columnText($0, 2), publishedAt: columnOptionalDate($0, 3),
                        content: columnOptionalText($0, 4), linkedURL: columnOptionalText($0, 5),
                        preferredInput: columnOptionalText($0, 6).flatMap(ItemInputID.init(rawValue:)),
                        mediaURL: columnOptionalText($0, 7),
                        transcriptURL: columnOptionalText($0, 8),
                        transcriptType: columnOptionalText($0, 9),
                        transcriptLanguage: columnOptionalText($0, 10),
                        entryID: columnOptionalText($0, 11) ?? "",
                        acceptedAt: columnOptionalDate($0, 12),
                        ingestedAt: columnOptionalDate($0, 13) ?? Date().iso8601
                    )
                }
                let seen = try query(
                    "SELECT item_id FROM channel_seen WHERE channel_id = ? ORDER BY seen_at DESC",
                    bindings: [.text(source)], transform: { columnText($0, 0) }
                )
                return SQLiteChannelRecord(
                    source: source,
                    groupID: groupID,
                    groupTitle: groupTitle,
                    title: title,
                    kind: kind.flatMap(LibraryChannelKind.init(rawValue:)),
                    schedule: schedule,
                    lastCheckedAt: checked,
                    error: error,
                    reviewLimit: reviewLimit,
                    canLoadMore: more,
                    seen: seen,
                    items: items
                )
            }
        }
    }

    public func documentChannelSources() throws -> [String: [String]] {
        try locked {
            let rows = try query(
                """
                SELECT ci.entry_id, c.source_url
                FROM channel_items ci JOIN channels c ON c.id = ci.channel_id
                WHERE ci.entry_id IS NOT NULL AND ci.entry_id != ''
                  AND ci.accepted_at IS NOT NULL
                  AND c.deleted_at IS NULL
                ORDER BY ci.entry_id, c.source_url
                """
            ) { (columnText($0, 0), columnText($0, 1)) }
            return Dictionary(grouping: rows) { $0.0 }.mapValues { values in
                Array(Set(values.map(\.1))).sorted()
            }
        }
    }

    public func saveChannelRecords(_ records: [SQLiteChannelRecord]) throws {
        try locked {
            try transaction {
                for record in records {
                    let existing = try query(
                        "SELECT group_id, group_title, title, kind, schedule, review_limit, revision " +
                            "FROM channels WHERE id = ?",
                        bindings: [.text(record.source)]
                    ) {
                        (
                            columnOptionalText($0, 0), columnOptionalText($0, 1),
                            columnOptionalText($0, 2), columnOptionalText($0, 3),
                            columnText($0, 4), Int(sqlite3_column_int($0, 5)),
                            sqlite3_column_int64($0, 6)
                        )
                    }.first
                    let changed = existing?.0 != record.groupID || existing?.1 != record.groupTitle ||
                        existing?.2 != record.title || existing?.3 != record.kind?.rawValue ||
                        existing?.4 != record.schedule || existing?.5 != record.reviewLimit
                    let revision = (existing?.6 ?? 0) + (changed ? 1 : 0)
                    try run(
                        """
                        INSERT INTO channels(
                          id, source_url, group_id, group_title, title, kind,
                          schedule, review_limit, revision
                        ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?) ON CONFLICT(id) DO UPDATE SET
                          group_id = excluded.group_id, group_title = excluded.group_title,
                          title = excluded.title, kind = excluded.kind,
                          schedule = excluded.schedule, review_limit = excluded.review_limit,
                          revision = excluded.revision, deleted_at = NULL
                        """,
                        bindings: [
                            .text(record.source), .text(record.source), .text(record.groupID),
                            .optionalText(record.groupTitle), .optionalText(record.title),
                            .optionalText(record.kind?.rawValue), .text(record.schedule),
                            .int(Int64(record.reviewLimit)), .int(max(1, revision))
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
                              linked_url, preferred_input, media_url, transcript_url,
                              transcript_type, transcript_language, entry_id, accepted_at,
                              ingested_at
                            ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                            """,
                            bindings: [
                                .text(record.source), .text(item.id), .text(item.title), .text(item.url),
                                .optionalDouble(timestamp(item.publishedAt)), .optionalText(item.content),
                                .optionalText(item.linkedURL), .optionalText(item.preferredInput?.rawValue),
                                .optionalText(item.mediaURL), .optionalText(item.transcriptURL),
                                .optionalText(item.transcriptType), .optionalText(item.transcriptLanguage),
                                .optionalText(item.entryID.nilIfEmpty),
                                .optionalDouble(timestamp(item.entryID.isEmpty
                                    ? nil : (item.acceptedAt ?? item.ingestedAt))),
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

    @discardableResult
    public func deleteChannel(_ source: String) throws -> Int {
        try locked {
            let pending = try scalarInt(
                "SELECT count(*) FROM channel_items WHERE channel_id = ? " +
                    "AND (entry_id IS NULL OR entry_id = '')",
                bindings: [.text(source)]
            )
            try transaction {
                try run("DELETE FROM channel_items WHERE channel_id = ?", bindings: [.text(source)])
                try run("DELETE FROM channel_seen WHERE channel_id = ?", bindings: [.text(source)])
                try run("DELETE FROM channel_state WHERE channel_id = ?", bindings: [.text(source)])
                try run(
                    "UPDATE channels SET deleted_at = ?, revision = revision + 1 WHERE id = ?",
                    bindings: [.double(Date().timeIntervalSince1970), .text(source)]
                )
                let revision = try scalarInt(
                    "SELECT revision FROM channels WHERE id = \(sqlLiteral(source))"
                )
                try enqueue(recordType: "channel", id: source, revision: revision, operation: "delete")
            }
            return Int(pending)
        }
    }

    public func channelItem(source: String, itemID: String) throws -> LibraryChannelItem? {
        try locked {
            try query(
                """
                SELECT item_id, title, url, published_at, content, linked_url,
                       preferred_input, media_url, transcript_url, transcript_type,
                       transcript_language, entry_id, accepted_at, ingested_at
                FROM channel_items ci JOIN channels c ON c.id = ci.channel_id
                WHERE c.source_url = ? AND c.deleted_at IS NULL AND ci.item_id = ?
                """,
                bindings: [.text(source), .text(itemID)],
                transform: { statement in
                    LibraryChannelItem(
                        id: columnText(statement, 0), title: columnText(statement, 1),
                        url: columnText(statement, 2), publishedAt: columnOptionalDate(statement, 3),
                        content: columnOptionalText(statement, 4), linkedURL: columnOptionalText(statement, 5),
                        preferredInput: columnOptionalText(statement, 6).flatMap(ItemInputID.init(rawValue:)),
                        mediaURL: columnOptionalText(statement, 7),
                        transcriptURL: columnOptionalText(statement, 8),
                        transcriptType: columnOptionalText(statement, 9),
                        transcriptLanguage: columnOptionalText(statement, 10),
                        entryID: columnOptionalText(statement, 11) ?? "",
                        acceptedAt: columnOptionalDate(statement, 12),
                        ingestedAt: columnOptionalDate(statement, 13) ?? Date().iso8601
                    )
                }
            ).first
        }
    }

    public func acceptChannelItem(source: String, itemID: String, entryID: String) throws {
        try locked {
            try transaction {
                let document = try getDocument(entryID)
                guard try scalarInt(
                    "SELECT count(*) FROM channel_items ci JOIN channels c ON c.id = ci.channel_id " +
                        "WHERE c.source_url = ? AND c.deleted_at IS NULL AND ci.item_id = ? " +
                        "AND (ci.entry_id IS NULL OR ci.entry_id = '')",
                    bindings: [.text(source), .text(itemID)]
                ) == 1 else { throw SQLiteLibraryError.invalidDocument }
                try run(
                    "UPDATE channel_items SET entry_id = ?, accepted_at = ? WHERE channel_id = " +
                        "(SELECT id FROM channels WHERE source_url = ? AND deleted_at IS NULL) " +
                        "AND item_id = ? AND (entry_id IS NULL OR entry_id = '')",
                    bindings: [
                        .text(entryID), .double(Date().timeIntervalSince1970),
                        .text(source), .text(itemID)
                    ]
                )
                // Provenance is part of the document's cloud payload.
                _ = try commitDocument(SQLiteDocumentCommit(
                    id: entryID, baseRevision: document.revision
                ))
            }
        }
    }

    public func rejectChannelItem(source: String, itemID: String) throws {
        try locked {
            try transaction {
                guard try scalarInt(
                    "SELECT count(*) FROM channel_items ci JOIN channels c ON c.id = ci.channel_id " +
                        "WHERE c.source_url = ? AND c.deleted_at IS NULL AND ci.item_id = ? " +
                        "AND (ci.entry_id IS NULL OR ci.entry_id = '')",
                    bindings: [.text(source), .text(itemID)]
                ) == 1 else { throw SQLiteLibraryError.invalidDocument }
                try run(
                    "DELETE FROM channel_items WHERE channel_id = " +
                        "(SELECT id FROM channels WHERE source_url = ? AND deleted_at IS NULL) " +
                        "AND item_id = ? AND (entry_id IS NULL OR entry_id = '')",
                    bindings: [.text(source), .text(itemID)]
                )
            }
        }
    }

    public func enqueueProcessingJob(
        documentID: String,
        selectWhenFinished: Bool
    ) throws {
        try locked {
            try run(
                """
                INSERT INTO processing_jobs(
                  document_id, state, select_when_finished, attempts, created_at, updated_at
                ) VALUES(?, 'queued', ?, 0, ?, ?) ON CONFLICT(document_id) DO UPDATE SET
                  state = 'queued',
                  select_when_finished = MAX(
                    processing_jobs.select_when_finished,
                    excluded.select_when_finished
                  ),
                  last_error = NULL,
                  updated_at = excluded.updated_at
                """,
                bindings: [
                    .text(documentID), .int(selectWhenFinished ? 1 : 0),
                    .double(Date().timeIntervalSince1970), .double(Date().timeIntervalSince1970)
                ]
            )
        }
    }

    public func claimNextProcessingJob() throws -> SQLiteProcessingJob? {
        try locked {
            var claimed: SQLiteProcessingJob?
            try transaction {
                guard let row = try query(
                    """
                    SELECT document_id, select_when_finished, attempts
                    FROM processing_jobs WHERE state = 'queued'
                    ORDER BY created_at, document_id LIMIT 1
                    """,
                    transform: {
                        (columnText($0, 0), sqlite3_column_int($0, 1) != 0,
                         Int(sqlite3_column_int($0, 2)))
                    }
                ).first else { return }
                try run(
                    """
                    UPDATE processing_jobs SET state = 'running', attempts = attempts + 1,
                      updated_at = ? WHERE document_id = ?
                    """,
                    bindings: [.double(Date().timeIntervalSince1970), .text(row.0)]
                )
                claimed = SQLiteProcessingJob(
                    documentID: row.0,
                    selectWhenFinished: row.1,
                    attempts: row.2 + 1
                )
            }
            return claimed
        }
    }

    public func completeProcessingJob(documentID: String) throws {
        try locked {
            try run("DELETE FROM processing_jobs WHERE document_id = ?", bindings: [.text(documentID)])
        }
    }

    public func failProcessingJob(documentID: String, error: String) throws {
        try locked {
            try run(
                """
                UPDATE processing_jobs SET state = 'failed', last_error = ?, updated_at = ?
                WHERE document_id = ?
                """,
                bindings: [
                    .text(String(error.prefix(1_000))),
                    .double(Date().timeIntervalSince1970), .text(documentID)
                ]
            )
        }
    }
}
