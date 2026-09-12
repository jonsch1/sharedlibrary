import Foundation
import SQLite3

extension SQLiteLibrary {
    func documentBindings(_ document: SQLiteDocument) -> [Binding] {
        [
            .text(document.id), .text(document.captureID), .text(document.type),
            .text(document.title), .optionalText(document.sourceURL), .optionalText(document.mediaURL),
            .double(document.createdAt.timeIntervalSince1970),
            .double(document.updatedAt.timeIntervalSince1970), .int(document.revision),
            .int(document.deleted ? 1 : 0), .optionalBlob(document.cloudRecordData)
        ]
    }

    func locked<T>(_ operation: () throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        return try operation()
    }

    func transaction<T>(_ operation: () throws -> T) throws -> T {
        // Repository operations may participate in a larger capture or channel commit.
        let savepoint = sqlite3_get_autocommit(connection) == 0
            ? "nested_" + UUID().uuidString.replacingOccurrences(of: "-", with: "") : nil
        try execute(savepoint.map { "SAVEPOINT \($0)" } ?? "BEGIN IMMEDIATE")
        do {
            let result = try operation()
            try execute(savepoint.map { "RELEASE SAVEPOINT \($0)" } ?? "COMMIT")
            return result
        } catch {
            try? execute(savepoint.map { "ROLLBACK TO SAVEPOINT \($0)" } ?? "ROLLBACK")
            if let savepoint { try? execute("RELEASE SAVEPOINT \(savepoint)") }
            throw error
        }
    }

    func execute(_ sql: String) throws {
        var message: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(connection, sql, nil, nil, &message) == SQLITE_OK else {
            defer { sqlite3_free(message) }
            throw SQLiteLibraryError.database(
                message.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(connection))
            )
        }
    }

    func run(_ sql: String, bindings: [Binding] = []) throws {
        _ = try query(sql, bindings: bindings) { _ in () }
    }

    func scalarInt(_ sql: String) throws -> Int64 {
        try query(sql) { sqlite3_column_int64($0, 0) }.first ?? 0
    }

    func scalarInt(_ sql: String, bindings: [Binding]) throws -> Int64 {
        try query(sql, bindings: bindings) { sqlite3_column_int64($0, 0) }.first ?? 0
    }

    func query<T>(
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

    func databaseError() -> SQLiteLibraryError {
        .database(String(cString: sqlite3_errmsg(connection)))
    }

    func sqlLiteral(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "''"))'"
    }

    func timestamp(_ value: String?) -> Double? {
        value.flatMap { ISO8601DateFormatter().date(from: $0)?.timeIntervalSince1970 }
    }

    func jsonStrings(_ values: [String]) -> String {
        String(data: try! JSONEncoder().encode(values), encoding: .utf8)!
    }

    static func date(_ value: String) -> Date? {
        ISO8601DateFormatter().date(from: value)
    }

    static func logicalTable(_ recordType: String) throws -> String {
        switch recordType {
        case "topic": "topics"
        case "channel": "channels"
        default: throw SQLiteLibraryError.invalidDocument
        }
    }
}

enum Binding {
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


let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

func columnText(_ statement: OpaquePointer, _ index: Int32) -> String {
    sqlite3_column_text(statement, index).map { String(cString: $0) } ?? ""
}

func columnOptionalText(_ statement: OpaquePointer, _ index: Int32) -> String? {
    sqlite3_column_type(statement, index) == SQLITE_NULL ? nil : columnText(statement, index)
}

func columnOptionalDate(_ statement: OpaquePointer, _ index: Int32) -> String? {
    guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
    return ISO8601DateFormatter().string(
        from: Date(timeIntervalSince1970: sqlite3_column_double(statement, index))
    )
}

func columnBlob(_ statement: OpaquePointer, _ index: Int32) -> Data {
    guard let bytes = sqlite3_column_blob(statement, index) else { return Data() }
    return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, index)))
}

func columnOptionalBlob(_ statement: OpaquePointer, _ index: Int32) -> Data? {
    sqlite3_column_type(statement, index) == SQLITE_NULL ? nil : columnBlob(statement, index)
}

func decodeStrings(_ value: String) -> [String] {
    (try? JSONDecoder().decode([String].self, from: Data(value.utf8))) ?? []
}

func legacyChannelHost(_ value: String?) -> String? {
    guard var host = value.flatMap({ URL(string: $0)?.host })?.lowercased() else {
        return nil
    }
    if host.hasPrefix("www.") { host.removeFirst(4) }
    return host
}
