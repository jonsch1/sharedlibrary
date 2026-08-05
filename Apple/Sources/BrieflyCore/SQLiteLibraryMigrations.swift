import Foundation

enum SQLiteLibraryMigrator {
    static func migrate(_ library: SQLiteLibrary) throws {
        try library.execute(
            "PRAGMA journal_mode=WAL; PRAGMA foreign_keys=ON; PRAGMA busy_timeout=5000;"
        )
        try library.execute(SQLiteLibrarySchema.sql)
        let columns = try library.query("PRAGMA table_info(documents)") { columnText($0, 1) }
        if !columns.contains("media_url") {
            try library.execute("ALTER TABLE documents ADD COLUMN media_url TEXT")
        }
        if !columns.contains("excerpt") {
            try library.transaction {
                try library.execute("ALTER TABLE documents ADD COLUMN excerpt TEXT NOT NULL DEFAULT ''")
                try library.backfillExcerpts()
            }
        }
        let channelColumns = try library.query("PRAGMA table_info(channels)") { columnText($0, 1) }
        if !channelColumns.contains("schedule") {
            try library.execute("ALTER TABLE channels ADD COLUMN schedule TEXT NOT NULL DEFAULT 'manual'")
        }
        if !channelColumns.contains("group_id") {
            try library.execute("ALTER TABLE channels ADD COLUMN group_id TEXT")
            try library.execute("UPDATE channels SET group_id = source_url WHERE group_id IS NULL")
        }
        if !channelColumns.contains("group_title") {
            try library.execute("ALTER TABLE channels ADD COLUMN group_title TEXT")
        }
        if !channelColumns.contains("auto_summarize") {
            try library.execute(
                "ALTER TABLE channels ADD COLUMN auto_summarize INTEGER NOT NULL DEFAULT 1"
            )
        }
        let voiceBriefColumns = try library.query(
            "PRAGMA table_info(voice_briefs)"
        ) { columnText($0, 1) }
        if voiceBriefColumns.contains("prompt") {
            try library.execute("ALTER TABLE voice_briefs DROP COLUMN prompt")
        }
        let voiceBriefStateColumns = try library.query(
            "PRAGMA table_info(voice_brief_state)"
        ) { columnText($0, 1) }
        if !voiceBriefStateColumns.contains("pending_episode_id") {
            try library.execute("ALTER TABLE voice_brief_state ADD COLUMN pending_episode_id TEXT")
        }
        try library.execute("UPDATE processing_jobs SET state = 'queued' WHERE state = 'running'")
        let attachmentParents = try library.query("PRAGMA foreign_key_list(attachments)") {
            columnText($0, 2)
        }
        if attachmentParents.contains("documents") {
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
        try removeLegacyReadmeVoiceBrief(from: library)
    }

    private static func removeLegacyReadmeVoiceBrief(from library: SQLiteLibrary) throws {
        let ids = try library.query(
            "SELECT id FROM voice_briefs WHERE deleted_at IS NULL AND lower(id) = 'file:readme.md'"
        ) { columnText($0, 0) }
        for id in ids {
            try library.transaction {
                try library.run(
                    "UPDATE voice_briefs SET deleted_at = ?, revision = revision + 1 WHERE id = ?",
                    bindings: [.double(Date().timeIntervalSince1970), .text(id)]
                )
                let revision = try library.scalarInt(
                    "SELECT revision FROM voice_briefs WHERE id = \(library.sqlLiteral(id))"
                )
                try library.enqueue(
                    recordType: "voice_brief", id: id, revision: revision, operation: "delete"
                )
            }
        }
    }
}

private enum SQLiteLibrarySchema {
    static let sql = """
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
      group_id TEXT,
      group_title TEXT,
      title TEXT,
      kind TEXT,
      schedule TEXT NOT NULL DEFAULT 'manual',
      retrieval_count INTEGER NOT NULL DEFAULT 5,
      auto_summarize INTEGER NOT NULL DEFAULT 1,
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
    CREATE TABLE IF NOT EXISTS processing_jobs(
      document_id TEXT PRIMARY KEY REFERENCES documents(id) ON DELETE CASCADE,
      state TEXT NOT NULL CHECK(state IN ('queued', 'running', 'failed')),
      select_when_finished INTEGER NOT NULL DEFAULT 0,
      attempts INTEGER NOT NULL DEFAULT 0,
      last_error TEXT,
      created_at REAL NOT NULL,
      updated_at REAL NOT NULL
    );
    CREATE TABLE IF NOT EXISTS voice_briefs(
      id TEXT PRIMARY KEY,
      title TEXT NOT NULL,
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
      consumed TEXT NOT NULL DEFAULT '[]',
      pending_episode_id TEXT
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
