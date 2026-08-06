import Foundation

enum SQLiteLibraryMigrator {
    static func migrate(_ library: SQLiteLibrary) throws {
        try library.execute(
            "PRAGMA journal_mode=WAL; PRAGMA foreign_keys=ON; PRAGMA busy_timeout=5000;"
        )
        try library.execute(SQLiteLibrarySchema.sql)
        try migrateDocuments(library)
        try migrateChannels(library)
        try migrateChannelItems(library)
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
        // Preserve old content as ordinary library entries before dropping the
        // retired generated-content discriminator. The type cleanup also handles
        // partially migrated libraries where the old column is already gone.
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
                "ALTER TABLE channels ADD COLUMN review_limit INTEGER NOT NULL DEFAULT 50 " +
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
            "UPDATE channels SET review_limit = MIN(50, MAX(1, COALESCE(review_limit, 50)))"
        )
    }

    private static func migrateChannelItems(_ library: SQLiteLibrary) throws {
        let columns = try library.query("PRAGMA table_info(channel_items)") { columnText($0, 1) }
        let additions = [
            ("preferred_input", "TEXT"),
            ("media_url", "TEXT"),
            ("transcript_url", "TEXT"),
            ("transcript_type", "TEXT"),
            ("transcript_language", "TEXT")
        ]
        for (name, type) in additions where !columns.contains(name) {
            try library.execute("ALTER TABLE channel_items ADD COLUMN \(name) \(type)")
        }
        try library.run("UPDATE channel_items SET entry_id = NULL WHERE entry_id = ''")
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
      review_limit INTEGER NOT NULL DEFAULT 50 CHECK(review_limit BETWEEN 1 AND 50),
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
