import Foundation
import SQLite3

extension SQLiteLibrary {
    @discardableResult
    public func ingestMarkdownLibrary(_ root: URL) throws -> Int {
        let library = root.appending(path: "library", directoryHint: .isDirectory)
        let urls = try FileManager.default.contentsOfDirectory(
            at: library,
            includingPropertiesForKeys: [.creationDateKey],
            options: [.skipsHiddenFiles]
        ).filter { $0.pathExtension.lowercased() == "md" }
        return try locked {
            var imported = 0
            try transaction {
                for url in urls {
                    let raw = try String(contentsOf: url, encoding: .utf8)
                    let parsed = parseMarkdown(raw)
                    let captureID = parsed.scalar("id") ?? "legacy:\(url.lastPathComponent)"
                    let id = "personal:\(captureID)"
                    let exists = try readDocument(id) != nil
                    var texts = [LibraryVariant.source: parsed.body]
                    for variant in [LibraryVariant.concise, .detailed] {
                        let summary = library
                            .appending(path: "summaries", directoryHint: .isDirectory)
                            .appending(path: variant.rawValue, directoryHint: .isDirectory)
                            .appending(path: url.lastPathComponent)
                        if let text = try? String(contentsOf: summary, encoding: .utf8) {
                            texts[variant] = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        }
                    }
                    let resources = try url.resourceValues(forKeys: [.creationDateKey])
                    let createdAt = parsed.scalar("created_at").flatMap(Self.date) ??
                        resources.creationDate ?? Date()
                    if !exists {
                        try insert(SQLiteDocument(
                            id: id,
                            captureID: captureID,
                            type: normalizedDocumentType(parsed.scalar("type") ?? "document"),
                            title: parsed.scalar("title") ?? firstHeading(parsed.body) ??
                                url.deletingPathExtension().lastPathComponent,
                            sourceURL: parsed.scalar("source_url"),
                            createdAt: createdAt,
                            updatedAt: parsed.scalar("updated_at").flatMap(Self.date) ?? createdAt,
                            topicIDs: parsed.array("topics"),
                            tags: normalizedDocumentTags(parsed.array("tags")),
                            sourceIDs: parsed.array("source_ids"),
                            sourceURLs: parsed.array("source_urls"),
                            texts: texts
                        ))
                        try enqueue(id: id, revision: 1, operation: "save")
                        imported += 1
                    }
                    try importAttachment(
                        documentID: id, kind: "audio",
                        relativePath: parsed.scalar("audio_path"), library: library
                    )
                    try importAttachment(
                        documentID: id, kind: "favicon",
                        relativePath: parsed.scalar("favicon_path"), library: library
                    )
                }
            }
            return imported
        }
    }

    private func importAttachment(
        documentID: String,
        kind: String,
        relativePath: String?,
        library: URL
    ) throws {
        guard let relativePath, !relativePath.hasPrefix("/"), !relativePath.contains("..") else {
            return
        }
        let id = "\(documentID):\(kind)"
        guard try scalarInt(
            "SELECT count(*) FROM attachments WHERE id = \(sqlLiteral(id))"
        ) == 0 else { return }
        let url = library.appending(path: relativePath)
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return }
        let ext = url.pathExtension.lowercased()
        let mime: String
        if kind == "audio" {
            mime = ext == "m4a" ? "audio/mp4" : "audio/\(ext)"
        } else {
            mime = ext == "svg" ? "image/svg+xml" : ext == "jpg" ? "image/jpeg" : "image/\(ext)"
        }
        try run(
            "INSERT INTO attachments(id, document_id, kind, mime_type, data, revision) " +
                "VALUES(?, ?, ?, ?, ?, 1)",
            bindings: [.text(id), .text(documentID), .text(kind), .text(mime), .blob(data)]
        )
        try enqueue(recordType: "attachment", id: id, revision: 1, operation: "save")
    }
}
