import Foundation
import SQLite3

/// SQLite is the only writable document store. Markdown is parsed only by the explicit
/// one-time importer.
public final class SQLiteLibrary: @unchecked Sendable {
    let connection: OpaquePointer
    let lock = NSRecursiveLock()

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
            try SQLiteLibraryMigrator.migrate(self)
        } catch {
            sqlite3_close(database)
            throw error
        }
    }

    deinit { sqlite3_close(connection) }
}
