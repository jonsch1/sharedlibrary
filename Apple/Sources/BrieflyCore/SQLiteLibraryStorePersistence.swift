import Foundation

extension SQLiteLibraryStore {
    public func attachAudio(entryID: String, file source: URL) throws {
        let fileExtension = source.pathExtension.lowercased()
        guard ["m4a", "wav"].contains(fileExtension) else {
            throw LibraryError.invalidAudio
        }
        let data = try Data(contentsOf: source, options: .mappedIfSafe)
        guard !data.isEmpty, data.count <= 100_000_000 else {
            throw LibraryError.invalidAudio
        }
        _ = try database().getDocument(entryID)
        try database().saveAttachment(
            documentID: entryID,
            kind: "audio",
            mimeType: fileExtension == "m4a" ? "audio/mp4" : "audio/wav",
            data: data
        )
    }

    func saveCapture(
        title: String,
        content: String,
        sourceURL: URL?,
        mediaURL: URL? = nil,
        entryType: String,
        faviconData: Data? = nil,
        faviconFileExtension: String? = nil,
        audioData: Data? = nil,
        audioMimeType: String? = nil
    ) throws -> String {
        // Media remains an immutable attachment concern; the Markdown record itself is
        // committed once, locally, with its CloudKit outbox entry in the same transaction.
        let database = try database()
        let document = try database.createDocument(
            title: title,
            body: content,
            type: entryType,
            sourceURL: sourceURL?.absoluteString,
            mediaURL: mediaURL?.absoluteString
        )
        try saveDraftAttachments(
            ItemDraft(
                inputID: .text,
                title: title,
                content: content,
                faviconData: faviconData,
                faviconFileExtension: faviconFileExtension,
                audioData: audioData,
                audioMimeType: audioMimeType
            ),
            documentID: document.id,
            database: database
        )
        return document.id
    }

    func saveDraftAttachments(
        _ draft: ItemDraft,
        documentID: String,
        database: SQLiteLibrary
    ) throws {
        if let data = draft.faviconData,
           let ext = draft.faviconFileExtension?.lowercased(),
           data.count <= 1_000_000, validFavicon(data, fileExtension: ext) {
            try database.saveAttachment(
                documentID: documentID,
                kind: "favicon",
                mimeType: ext == "svg" ? "image/svg+xml" : ext == "jpg" ? "image/jpeg" : "image/\(ext)",
                data: data
            )
        }
        if let data = draft.audioData, !data.isEmpty, data.count <= 100_000_000,
           let mime = draft.audioMimeType, mime.lowercased().hasPrefix("audio/") {
            try database.saveAttachment(
                documentID: documentID,
                kind: "audio",
                mimeType: mime,
                data: data
            )
        }
    }


    public func writeText(
        entryID: String,
        variant: LibraryVariant,
        text: String
    ) throws {
        let document = try database().getDocument(entryID)
        guard document.texts[variant] != nil else {
            throw LibraryError.missingVariant
        }
        try database().commitDocument(SQLiteDocumentCommit(
            id: entryID,
            baseRevision: document.revision,
            texts: [variant: text]
        ))
    }

    public func search(_ query: String, limit: Int = 50) throws -> [SQLiteSearchResult] {
        try database().search(query, limit: limit)
    }

    public func getDocument(
        _ id: String,
        includeDeleted: Bool = false
    ) throws -> SQLiteDocument {
        try database().getDocument(id, includeDeleted: includeDeleted)
    }

    @discardableResult
    public func commitDocument(
        _ id: String,
        baseRevision: Int64,
        texts: [LibraryVariant: String],
        title: String? = nil
    ) throws -> SQLiteDocument {
        try database().commitDocument(SQLiteDocumentCommit(
            id: id,
            baseRevision: baseRevision,
            title: title,
            texts: texts
        ))
    }

    @discardableResult
    public func batch(_ commits: [SQLiteDocumentCommit]) throws -> [SQLiteDocument] {
        try database().batch(commits)
    }


    public func audioURL(entryID: String) throws -> URL? {
        try attachmentURL(entryID: entryID, kind: "audio")
    }

    public func faviconURL(entryID: String) throws -> URL? {
        try attachmentURL(entryID: entryID, kind: "favicon")
    }

    private func attachmentURL(entryID: String, kind: String) throws -> URL? {
        guard let (mime, data) = try database().attachment(documentID: entryID, kind: kind) else {
            return nil
        }
        let directory = fileManager.temporaryDirectory
            .appending(path: "briefly-attachments", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "\(slug(entryID))-\(kind).\(fileExtension(for: mime))")
        try data.write(to: url, options: .atomic)
        return url
    }

}
