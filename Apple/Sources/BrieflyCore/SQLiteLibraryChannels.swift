import Foundation
import SQLite3

extension SQLiteLibrary {
    public func channelRecords() throws -> [SQLiteChannelRecord] {
        try locked {
            let rows = try query(
                """
                SELECT c.source_url, COALESCE(c.group_id, c.source_url), c.group_title,
                       c.title, c.kind, c.schedule, s.last_checked_at,
                       s.last_error, c.retrieval_count, c.auto_summarize, s.can_load_more
                FROM channels c LEFT JOIN channel_state s ON s.channel_id = c.id
                WHERE c.deleted_at IS NULL ORDER BY c.source_url
                """
            ) { statement in
                (
                    columnText(statement, 0), columnText(statement, 1),
                    columnOptionalText(statement, 2), columnOptionalText(statement, 3),
                    columnOptionalText(statement, 4), columnText(statement, 5),
                    columnOptionalDate(statement, 6), columnOptionalText(statement, 7),
                    Int(sqlite3_column_int(statement, 8)), sqlite3_column_int(statement, 9) != 0,
                    sqlite3_column_int(statement, 10) != 0
                )
            }
            return try rows.map { source, groupID, groupTitle, title, kind, schedule, checked, error, count, autoSummarize, more in
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
                    source: source, groupID: groupID, groupTitle: groupTitle, title: title,
                    kind: kind.flatMap(LibraryChannelKind.init(rawValue:)),
                    schedule: schedule,
                    lastCheckedAt: checked, error: error, retrievalCount: count,
                    autoSummarize: autoSummarize,
                    canLoadMore: more, seen: seen, items: items
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
                ORDER BY ci.entry_id, c.source_url
                """
            ) { (columnText($0, 0), columnText($0, 1)) }
            var sources = Dictionary(grouping: rows) { $0.0 }.mapValues { values in
                Array(Set(values.map { $0.1 })).sorted()
            }
            let unlinked = try query(
                """
                SELECT d.id, d.type, d.source_url, d.created_at
                FROM documents d
                WHERE NOT EXISTS (
                  SELECT 1 FROM channel_items ci WHERE ci.entry_id = d.id
                )
                """
            ) {
                (
                    columnText($0, 0), columnText($0, 1),
                    columnOptionalText($0, 2), sqlite3_column_double($0, 3)
                )
            }
            let legacyMarkers = unlinked.compactMap { row -> (String, Double)? in
                guard row.1 == "voice_brief_source", let host = legacyChannelHost(row.2) else {
                    return nil
                }
                return (host, row.3)
            }
            for row in unlinked where sources[row.0] == nil {
                guard let host = legacyChannelHost(row.2), row.1 != "voice_brief_source" else {
                    continue
                }
                if legacyMarkers.contains(where: { $0.0 == host && abs($0.1 - row.3) <= 1 }) {
                    sources[row.0] = ["legacy-channel:\(host)"]
                }
            }
            return sources
        }
    }

    @discardableResult
    public func trashDocumentsFromDeletedChannels() throws -> Int {
        let ids = try locked {
            try query(
                """
                SELECT DISTINCT ci.entry_id
                FROM channel_items ci
                JOIN channels c ON c.id = ci.channel_id
                JOIN documents d ON d.id = ci.entry_id
                WHERE c.deleted_at IS NOT NULL AND d.deleted = 0
                UNION
                SELECT d.id
                FROM documents d
                WHERE d.deleted = 0 AND d.type = 'voice_brief_source'
                  AND NOT EXISTS (
                    SELECT 1 FROM channel_items ci WHERE ci.entry_id = d.id
                  )
                """
            ) { columnText($0, 0) }
        }
        let documents = try ids.map { try getDocument($0) }
        try batch(documents.map {
            SQLiteDocumentCommit(id: $0.id, baseRevision: $0.revision, deleted: true)
        })
        return documents.count
    }

    public func saveChannelRecords(_ records: [SQLiteChannelRecord]) throws {
        try locked {
            try transaction {
                for record in records {
                    let existing = try query(
                        "SELECT group_id, group_title, title, kind, schedule, retrieval_count, " +
                            "auto_summarize, revision " +
                            "FROM channels WHERE id = ?",
                        bindings: [.text(record.source)]
                    ) { (columnOptionalText($0, 0), columnOptionalText($0, 1),
                         columnOptionalText($0, 2), columnOptionalText($0, 3),
                         columnText($0, 4), Int(sqlite3_column_int($0, 5)),
                         sqlite3_column_int($0, 6) != 0, sqlite3_column_int64($0, 7)) }.first
                    let changed = existing?.0 != record.groupID || existing?.1 != record.groupTitle ||
                        existing?.2 != record.title || existing?.3 != record.kind?.rawValue ||
                        existing?.4 != record.schedule || existing?.5 != record.retrievalCount ||
                        existing?.6 != record.autoSummarize
                    let revision = (existing?.7 ?? 0) + (changed ? 1 : 0)
                    try run(
                        """
                        INSERT INTO channels(
                          id, source_url, group_id, group_title, title, kind,
                          schedule, retrieval_count, auto_summarize, revision
                        ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?) ON CONFLICT(id) DO UPDATE SET
                          group_id = excluded.group_id, group_title = excluded.group_title,
                          title = excluded.title, kind = excluded.kind,
                          schedule = excluded.schedule,
                          retrieval_count = excluded.retrieval_count,
                          auto_summarize = excluded.auto_summarize,
                          revision = excluded.revision, deleted_at = NULL
                        """,
                        bindings: [
                            .text(record.source), .text(record.source), .text(record.groupID),
                            .optionalText(record.groupTitle),
                            .optionalText(record.title), .optionalText(record.kind?.rawValue),
                            .text(record.schedule), .int(Int64(record.retrievalCount)),
                            .int(record.autoSummarize ? 1 : 0),
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
                    .double(Date().timeIntervalSince1970),
                    .double(Date().timeIntervalSince1970)
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
                    transform: { (columnText($0, 0), sqlite3_column_int($0, 1) != 0,
                                  Int(sqlite3_column_int($0, 2))) }
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

    public func voiceBriefRunStates() throws -> [SQLiteVoiceBriefRunState] {
        try locked {
            try query(
                "SELECT voice_brief_id, last_run_at, last_attempt_at, status, message, consumed, " +
                    "pending_episode_id " +
                    "FROM voice_brief_state"
            ) {
                SQLiteVoiceBriefRunState(
                    voiceBriefID: columnText($0, 0),
                    lastRunAt: columnOptionalDate($0, 1),
                    lastAttemptAt: columnOptionalDate($0, 2),
                    status: columnOptionalText($0, 3),
                    message: columnOptionalText($0, 4),
                    consumed: decodeStrings(columnText($0, 5)),
                    pendingEpisodeID: columnOptionalText($0, 6)
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
                          voice_brief_id, last_run_at, last_attempt_at, status, message,
                          consumed, pending_episode_id
                        ) VALUES(?, ?, ?, ?, ?, ?, ?) ON CONFLICT(voice_brief_id) DO UPDATE SET
                          last_run_at = excluded.last_run_at,
                          last_attempt_at = excluded.last_attempt_at,
                          status = excluded.status, message = excluded.message,
                          consumed = excluded.consumed,
                          pending_episode_id = excluded.pending_episode_id
                        """,
                        bindings: [
                            .text(state.voiceBriefID), .optionalDouble(timestamp(state.lastRunAt)),
                            .optionalDouble(timestamp(state.lastAttemptAt)), .optionalText(state.status),
                            .optionalText(state.message), .text(jsonStrings(state.consumed)),
                            .optionalText(state.pendingEpisodeID)
                        ]
                    )
                }
            }
        }
    }
}
