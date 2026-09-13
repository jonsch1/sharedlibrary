import CryptoKit
import Foundation
import SQLite3

public enum LibraryExportFormat: String, CaseIterable, Sendable {
    case sqlite, markdown

    public var filename: String {
        switch self {
        case .sqlite: "Briefly Library.sqlite3"
        case .markdown: "Briefly Library"
        }
    }
}

extension SQLiteLibraryStore {
    /// Produces a complete snapshot without copying an open database's WAL files.
    /// The destination must not exist. A failed export never replaces user files.
    public func exportLibrary(as format: LibraryExportFormat, to destination: URL) throws {
        let manager = FileManager.default
        let staging = manager.temporaryDirectory.appending(path: "briefly-export-\(UUID())")
        try manager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: staging) }
        let snapshot = staging.appending(path: "snapshot.sqlite3")
        try database().writeSnapshot(to: snapshot)
        switch format {
        case .sqlite:
            try publishExport(snapshot, to: destination)
        case .markdown:
            let folder = staging.appending(path: "Markdown")
            try SQLiteLibrary(databaseURL: snapshot).writeMarkdownExport(to: folder)
            try publishExport(folder, to: destination)
        }
    }
}

extension SQLiteLibrary {
    private func exportError(_ connection: OpaquePointer) -> SQLiteLibraryError {
        .database(String(cString: sqlite3_errmsg(connection)))
    }

    fileprivate func writeSnapshot(to url: URL) throws {
        try locked {
            var output: OpaquePointer?
            guard sqlite3_open_v2(url.path, &output, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
                  let output else {
                if let output { sqlite3_close(output) }
                throw SQLiteLibraryError.database("Could not create the library export.")
            }
            defer { sqlite3_close(output) }
            guard let backup = sqlite3_backup_init(output, "main", connection, "main") else {
                throw exportError(output)
            }
            let status = sqlite3_backup_step(backup, -1)
            let finish = sqlite3_backup_finish(backup)
            guard status == SQLITE_DONE, finish == SQLITE_OK else { throw exportError(output) }
            // A standalone file must not depend on sidecar files.
            guard sqlite3_exec(output, "PRAGMA journal_mode=DELETE", nil, nil, nil) == SQLITE_OK else {
                throw exportError(output)
            }
        }
    }

    fileprivate func writeMarkdownExport(to folder: URL) throws {
        let manager = FileManager.default
        let metadataFolder = folder.appending(path: "Metadata")
        try manager.createDirectory(at: metadataFolder, withIntermediateDirectories: true)
        var documentFolders: [String: String] = [:]
        for document in try allDocuments(includeDeleted: true) {
            let relative = "\(document.deleted ? "Trash" : "Items")/\(exportName(document.title))-\(exportDigest(document.id))"
            documentFolders[document.id] = relative
            let directory = folder.appending(path: relative)
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
            for (variant, body) in document.texts {
                try body.write(to: directory.appending(path: "\(variant.rawValue).md"), atomically: true, encoding: .utf8)
            }
            if let capture = document.captureRequest {
                let original: String
                switch capture.payload {
                case .url(let url): original = url
                case .text(let text): original = text
                case .pdf(let filename): original = "Original file: \(filename)\n\nSee the Attachments folder."
                }
                try original.write(to: directory.appending(path: "capture.md"), atomically: true, encoding: .utf8)
            }
            var metadata = document
            metadata.cloudRecordData = nil
            // Text lives in the Markdown files; preserve the rest as portable metadata.
            metadata.texts = [:]
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(metadata).write(to: directory.appending(path: "metadata.json"))
        }
        try writeExportJSON(documentFolders, to: metadataFolder.appending(path: "item-paths.json"))

        // Preserve all persisted metadata, including highlights, reading state, channels,
        // topics, and tombstones. FTS tables are derived indexes, not library content.
        let tables = try query("SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name") {
            columnText($0, 0)
        }.filter { !$0.hasPrefix("sqlite_") && !$0.hasPrefix("document_fts") }
        for table in tables {
            let quoted = table.replacingOccurrences(of: "\"", with: "\"\"")
            let rows: [[String: Any]] = try query("SELECT * FROM \"\(quoted)\"") { statement in
                var row: [String: Any] = [:]
                for index in 0..<sqlite3_column_count(statement) {
                    let name = String(cString: sqlite3_column_name(statement, index))
                    switch sqlite3_column_type(statement, index) {
                    case SQLITE_INTEGER: row[name] = NSNumber(value: sqlite3_column_int64(statement, index))
                    case SQLITE_FLOAT: row[name] = NSNumber(value: sqlite3_column_double(statement, index))
                    case SQLITE_TEXT: row[name] = columnText(statement, index)
                    case SQLITE_BLOB: row[name] = ["base64": columnBlob(statement, index).base64EncodedString()]
                    default: row[name] = NSNull()
                    }
                }
                if table == "attachments", let encoded = row["data"] as? [String: String],
                   let base64 = encoded["base64"], let bytes = Data(base64Encoded: base64),
                   let id = row["id"] as? String {
                    let documentID = row["document_id"] as? String ?? ""
                    let kind = row["kind"] as? String ?? "attachment"
                    let mimeType = row["mime_type"] as? String ?? "application/octet-stream"
                    let ext = exportName(fileExtension(for: mimeType))
                    let parent = documentFolders[documentID] ?? "Attachments"
                    let relative = "\(parent)/Attachments/\(exportName(kind))-\(exportDigest(id)).\(ext)"
                    let file = folder.appending(path: relative)
                    try manager.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try bytes.write(to: file)
                    row["data"] = ["file": relative]
                }
                return row
            }
            try writeExportJSON(rows, to: metadataFolder.appending(path: "\(table).json"))
        }
        try """
        # Briefly library

        Each item has a folder in Items, with source.md, concise.md, and detailed.md when available.
        Original queued input is in capture.md. Attachments are stored alongside each item.
        Deleted items are in Trash. metadata.json records the item's title, dates, URLs, tags,
        topics, and queue status. Metadata contains the full persisted library records,
        including highlights, reading state, channels, and pending items. item-paths.json maps
        document IDs to folders. Binary metadata uses base64; attachment data uses relative file paths.

        This is a snapshot of what was stored on this device at export time. Changes or
        attachments that have not synced to this device are not included.
        """.write(to: folder.appending(path: "README.md"), atomically: true, encoding: .utf8)
    }
}

private func writeExportJSON(_ value: Any, to url: URL) throws {
    try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]).write(to: url)
}

private func exportName(_ value: String) -> String {
    let name = value.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? String($0) : "-" }.joined()
    return String(name.prefix(64)).nilIfEmpty ?? "item"
}

private func exportDigest(_ value: String) -> String {
    SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
}

private func publishExport(_ source: URL, to destination: URL) throws {
    let manager = FileManager.default
    guard !manager.fileExists(atPath: destination.path) else {
        throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: destination.path])
    }
    let temporary = destination.deletingLastPathComponent().appending(path: ".briefly-export-\(UUID())")
    defer { try? manager.removeItem(at: temporary) }
    try manager.copyItem(at: source, to: temporary)
    try manager.moveItem(at: temporary, to: destination)
}
