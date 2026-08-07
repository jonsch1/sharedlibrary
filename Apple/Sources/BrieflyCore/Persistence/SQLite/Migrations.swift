import Foundation
import SQLite3

enum SQLiteLibraryMigrator {
    static func migrate(_ library: SQLiteLibrary) throws {
        try library.execute(
            "PRAGMA journal_mode=WAL; PRAGMA foreign_keys=ON; PRAGMA busy_timeout=5000;"
        )
        try library.execute(SQLiteLibrarySchema.sql)
        try migrateChannels(library)
        try migrateChannelItems(library)
        try migrateDocuments(library)
        try migrateAttachments(library)
        try library.execute("UPDATE processing_jobs SET state = 'queued' WHERE state = 'running'")
        try removeRetiredGeneratedSchema(from: library)
    }

    private static func migrateDocuments(_ library: SQLiteLibrary) throws {
        var columns = try library.query("PRAGMA table_info(documents)") { columnText($0, 1) }
        if !columns.contains("media_url") {
            try library.execute("ALTER TABLE documents ADD COLUMN media_url TEXT")
            columns.append("media_url")
        }
        if !columns.contains("excerpt") {
            try library.transaction {
                try library.execute("ALTER TABLE documents ADD COLUMN excerpt TEXT NOT NULL DEFAULT ''")
                try library.backfillExcerpts()
            }
            columns.append("excerpt")
        }
        // Preserve old generated episodes as ordinary library entries before dropping
        // the retired discriminator. Legacy channel imports were returned to the review
        // queue by migrateChannelItems before this type cleanup runs.
        try library.transaction {
            try library.run(
                "UPDATE documents SET type = 'document' WHERE type = 'voice_brief_episode'"
            )
            try library.run(
                "UPDATE documents SET type = 'link' WHERE type = 'voice_brief_source'"
            )
            try library.run("DELETE FROM document_tags WHERE lower(tag) = 'voice-brief'")
            if columns.contains("voice_brief_id") {
                try library.execute("ALTER TABLE documents DROP COLUMN voice_brief_id")
            }
        }
    }

    private static func migrateChannels(_ library: SQLiteLibrary) throws {
        let columns = try library.query("PRAGMA table_info(channels)") { columnText($0, 1) }
        if !columns.contains("schedule") {
            try library.execute("ALTER TABLE channels ADD COLUMN schedule TEXT NOT NULL DEFAULT 'manual'")
        }
        if !columns.contains("group_id") {
            try library.execute("ALTER TABLE channels ADD COLUMN group_id TEXT")
            try library.execute("UPDATE channels SET group_id = source_url WHERE group_id IS NULL")
        }
        if !columns.contains("group_title") {
            try library.execute("ALTER TABLE channels ADD COLUMN group_title TEXT")
        }
        if !columns.contains("review_limit") {
            try library.execute(
                "ALTER TABLE channels ADD COLUMN review_limit INTEGER NOT NULL DEFAULT 20 " +
                    "CHECK(review_limit BETWEEN 1 AND 50)"
            )
            if columns.contains("retrieval_count") {
                try library.execute(
                    "UPDATE channels SET review_limit = MIN(50, MAX(1, retrieval_count))"
                )
            }
        }
        let refreshedColumns = try library.query("PRAGMA table_info(channels)") { columnText($0, 1) }
        if refreshedColumns.contains("retrieval_count") {
            try library.execute("ALTER TABLE channels DROP COLUMN retrieval_count")
        }
        if refreshedColumns.contains("auto_summarize") {
            try library.execute("ALTER TABLE channels DROP COLUMN auto_summarize")
        }
        try library.run(
            "UPDATE channels SET review_limit = MIN(50, MAX(1, COALESCE(review_limit, 20)))"
        )
    }

    private static func migrateChannelItems(_ library: SQLiteLibrary) throws {
        var columns = try library.query("PRAGMA table_info(channel_items)") { columnText($0, 1) }
        let additions = [
            ("preferred_input", "TEXT"),
            ("media_url", "TEXT"),
            ("transcript_url", "TEXT"),
            ("transcript_type", "TEXT"),
            ("transcript_language", "TEXT"),
            ("accepted_at", "REAL")
        ]
        for (name, type) in additions where !columns.contains(name) {
            try library.execute("ALTER TABLE channel_items ADD COLUMN \(name) \(type)")
            columns.append(name)
        }
        try library.run("UPDATE channel_items SET entry_id = NULL WHERE entry_id = ''")
        try migrateLegacyChannelItems(library)
    }

    private static let channelReviewAcceptanceMigrationKey =
        "briefly-channel-review-acceptance-v1"

    /// The durable review queue was introduced after older channel checks had already
    /// created documents. Existing channel links therefore mean "imported by the old
    /// channel workflow" until the new explicit acceptance marker exists. Clear only
    /// those pre-marker links, retain their text as pending candidate content, and
    /// tombstone the auto-created documents so they cannot remain in the main library.
    private static func migrateLegacyChannelItems(_ library: SQLiteLibrary) throws {
        let migrated = try library.query(
            "SELECT 1 FROM sync_state WHERE key = ? LIMIT 1",
            bindings: [.text(channelReviewAcceptanceMigrationKey)],
            transform: { _ in true }
        ).first == true
        guard !migrated else { return }

        let targets = try library.query(
            """
            SELECT d.id,
                   EXISTS(
                     SELECT 1 FROM channel_items accepted
                     WHERE accepted.entry_id = d.id AND accepted.accepted_at IS NOT NULL
                   )
            FROM documents d
            WHERE EXISTS(
                SELECT 1 FROM channel_items linked
                WHERE linked.entry_id = d.id AND linked.accepted_at IS NULL
            )
            ORDER BY d.id
            """
        ) { statement in
            (
                columnText(statement, 0), sqlite3_column_int(statement, 1) != 0
            )
        }

        try library.transaction {
            for (documentID, hasAcceptedLink) in targets {
                let document = try library.query(
                    "SELECT title, source_url, deleted, revision FROM documents WHERE id = ?",
                    bindings: [.text(documentID)]
                ) { statement in
                    (
                        columnText(statement, 0), columnOptionalText(statement, 1),
                        sqlite3_column_int(statement, 2) != 0,
                        sqlite3_column_int64(statement, 3)
                    )
                }.first

                let sourceBody = try library.query(
                    """
                    SELECT body FROM document_texts
                    WHERE document_id = ?
                    ORDER BY CASE variant
                      WHEN 'source' THEN 0 WHEN 'detailed' THEN 1 WHEN 'concise' THEN 2 ELSE 3
                    END
                    LIMIT 1
                    """,
                    bindings: [.text(documentID)],
                    transform: { columnText($0, 0) }
                ).first?.nilIfEmpty

                let items = try library.query(
                    """
                    SELECT item_id, title, url, content
                    FROM channel_items
                    WHERE entry_id = ? AND accepted_at IS NULL
                    """,
                    bindings: [.text(documentID)]
                ) { statement in
                    (
                        columnText(statement, 0), columnText(statement, 1),
                        columnText(statement, 2), columnOptionalText(statement, 3)
                    )
                }

                for (itemID, title, url, content) in items {
                    let candidateContent = content?.nilIfEmpty ?? sourceBody
                    let candidateTitle = title.nilIfEmpty ?? document?.0 ?? title
                    let candidateURL = url.nilIfEmpty ?? document?.1 ?? url
                    try library.run(
                        """
                        UPDATE channel_items
                        SET title = ?, url = ?, content = ?, entry_id = NULL, accepted_at = NULL
                        WHERE item_id = ? AND entry_id = ? AND accepted_at IS NULL
                        """,
                        bindings: [
                            .text(candidateTitle), .text(candidateURL),
                            .optionalText(candidateContent), .text(itemID), .text(documentID)
                        ]
                    )
                }

                guard !hasAcceptedLink, let document
                else { continue }

                if !document.2 {
                    let revision = document.3 + 1
                    try library.run(
                        "UPDATE documents SET deleted = 1, updated_at = ?, revision = ? WHERE id = ?",
                        bindings: [
                            .double(Date().timeIntervalSince1970), .int(revision), .text(documentID)
                        ]
                    )
                    try library.run(
                        "DELETE FROM document_fts WHERE document_id = ?",
                        bindings: [.text(documentID)]
                    )
                    try library.enqueue(
                        id: documentID, revision: revision, operation: "delete"
                    )
                }
                try library.run(
                    "DELETE FROM processing_jobs WHERE document_id = ?",
                    bindings: [.text(documentID)]
                )
            }

            // A stale relationship without a document cannot be accepted and must not
            // keep an item out of the review queue.
            try library.run(
                """
                UPDATE channel_items SET entry_id = NULL, accepted_at = NULL
                WHERE entry_id IS NOT NULL AND accepted_at IS NULL
                  AND NOT EXISTS (SELECT 1 FROM documents d WHERE d.id = channel_items.entry_id)
                """
            )

            // Rehydrate only the configured rolling review window. channel_seen remains
            // intact so discarded historical rows are not rediscovered indefinitely.
            try library.run(
                """
                DELETE FROM channel_items
                WHERE rowid IN (
                  SELECT item_rowid FROM (
                    SELECT ci.rowid AS item_rowid,
                           ROW_NUMBER() OVER (
                             PARTITION BY COALESCE(c.group_id, c.source_url)
                             ORDER BY COALESCE(ci.ingested_at, ci.published_at, 0) DESC, ci.item_id
                           ) AS item_position,
                           MIN(c.review_limit) OVER (
                             PARTITION BY COALESCE(c.group_id, c.source_url)
                           ) AS review_limit
                    FROM channel_items ci
                    JOIN channels c ON c.id = ci.channel_id
                    WHERE ci.entry_id IS NULL AND ci.accepted_at IS NULL
                      AND c.deleted_at IS NULL
                  )
                  WHERE item_position > review_limit
                )
                """
            )

            try library.run(
                "INSERT INTO sync_state(key, value) VALUES(?, ?) " +
                    "ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                bindings: [.text(channelReviewAcceptanceMigrationKey), .blob(Data([1]))]
            )
        }
    }

    private static func migrateAttachments(_ library: SQLiteLibrary) throws {
        let attachmentParents = try library.query("PRAGMA foreign_key_list(attachments)") {
            columnText($0, 2)
        }
        guard attachmentParents.contains("documents") else { return }
        try library.transaction {
            try library.execute(
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

    private static func removeRetiredGeneratedSchema(from library: SQLiteLibrary) throws {
        try library.transaction {
            try library.execute("DROP TABLE IF EXISTS voice_brief_consumed_items")
            try library.execute("DROP TABLE IF EXISTS voice_brief_sources")
            try library.execute("DROP TABLE IF EXISTS voice_brief_runs")
            try library.execute("DROP TABLE IF EXISTS voice_brief_state")
            try library.execute("DROP TABLE IF EXISTS voice_briefs")
            try library.run("DELETE FROM cloud_outbox WHERE record_type = 'voice_brief'")
        }
    }
}

private enum SQLiteLibrarySchema {
    static let sql = """
    CREATE TABLE IF NOT EXISTS documents(
      id TEXT PRIMARY KEY,
      capture_id TEXT NOT NULL UNIQUE,
      type TEXT NOT NULL,
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
      group_id TEXT,
      group_title TEXT,
      title TEXT,
      kind TEXT,
      schedule TEXT NOT NULL DEFAULT 'manual',
      review_limit INTEGER NOT NULL DEFAULT 20 CHECK(review_limit BETWEEN 1 AND 50),
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
      preferred_input TEXT,
      media_url TEXT,
      transcript_url TEXT,
      transcript_type TEXT,
      transcript_language TEXT,
      entry_id TEXT REFERENCES documents(id),
      accepted_at REAL,
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
    CREATE TABLE IF NOT EXISTS processing_jobs(
      document_id TEXT PRIMARY KEY REFERENCES documents(id) ON DELETE CASCADE,
      state TEXT NOT NULL CHECK(state IN ('queued', 'running', 'failed')),
      select_when_finished INTEGER NOT NULL DEFAULT 0,
      attempts INTEGER NOT NULL DEFAULT 0,
      last_error TEXT,
      created_at REAL NOT NULL,
      updated_at REAL NOT NULL
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
