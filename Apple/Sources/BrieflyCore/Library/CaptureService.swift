import Foundation

/// Application-facing capture workflow. It validates drafts and coordinates the
/// document and attachment repositories; it does not know how SQLite stores rows.
struct LibraryCaptureService {
    let documents: SQLiteDocumentRepository
    let attachments: SQLiteAttachmentRepository
    let fileManager: FileManager

    func capture(_ value: String) throws -> String {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw LibraryError.emptyCapture }
        let sourceURL = httpURL(text)
        let title = sourceURL?.host?.replacingOccurrences(of: "www.", with: "") ??
            firstUsefulLine(text)
        return try saveCapture(
            title: title,
            content: text,
            sourceURL: sourceURL,
            entryType: sourceURL == nil ? "text" : "link"
        )
    }

    func captureWebPage(
        title: String,
        content: String,
        sourceURL: URL,
        asVoiceBriefSource: Bool,
        faviconData: Data?,
        faviconFileExtension: String?
    ) throws -> String {
        guard sourceURL.scheme == "http" || sourceURL.scheme == "https" else {
            throw LibraryError.invalidChannel
        }
        let text = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw LibraryError.emptyCapture }
        return try saveCapture(
            title: title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? sourceURL.host ?? "Web capture"
                : title,
            content: text,
            sourceURL: sourceURL,
            entryType: asVoiceBriefSource ? "voice_brief_source" : "link",
            faviconData: faviconData,
            faviconFileExtension: faviconFileExtension
        )
    }

    func captureDocument(title: String, content: String) throws -> String {
        let text = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw LibraryError.emptyDocument }
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return try saveCapture(
            title: name.isEmpty ? "PDF document" : String(name.prefix(200)),
            content: text,
            sourceURL: nil,
            entryType: "pdf"
        )
    }

    func captureItem(_ draft: ItemDraft, asVoiceBriefSource: Bool) throws -> String {
        let content = draft.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { throw LibraryError.emptyCapture }
        if let key = draft.canonicalKey,
           let existing = try documents.all().first(where: {
               $0.type != "voice_brief_episode" &&
                   canonicalItemIdentity($0.sourceURL.flatMap(URL.init(string:))) == key
           }) {
            let sourceURL = (draft.canonicalURL ?? draft.sourceURL)?.absoluteString
            let mediaURL = draft.mediaURL?.absoluteString
            if existing.texts[.source] != content ||
                (existing.mediaURL == nil && mediaURL != nil) ||
                (existing.sourceURL == nil && sourceURL != nil) ||
                (existing.type == "voice_brief_source" && !asVoiceBriefSource) {
                _ = try documents.commit(SQLiteDocumentCommit(
                    id: existing.id,
                    baseRevision: existing.revision,
                    type: existing.type == "voice_brief_source" && !asVoiceBriefSource
                        ? "link"
                        : nil,
                    sourceURL: existing.sourceURL == nil ? sourceURL : nil,
                    mediaURL: existing.mediaURL == nil ? mediaURL : nil,
                    texts: existing.texts[.source] == content ? [:] : [.source: content]
                ))
            }
            try saveDraftAttachments(draft, documentID: existing.id)
            return existing.id
        }
        let entryType: String = switch (asVoiceBriefSource, draft.inputID) {
        case (true, _): "voice_brief_source"
        case (_, .text): "text"
        case (_, .pdf): "pdf"
        default: "link"
        }
        return try saveCapture(
            title: draft.title,
            content: content,
            sourceURL: draft.canonicalURL ?? draft.sourceURL,
            mediaURL: draft.mediaURL,
            entryType: entryType,
            faviconData: draft.faviconData,
            faviconFileExtension: draft.faviconFileExtension,
            audioData: draft.audioData,
            audioMimeType: draft.audioMimeType
        )
    }

    func attachAudio(entryID: String, file source: URL) throws {
        let fileExtension = source.pathExtension.lowercased()
        guard ["m4a", "wav"].contains(fileExtension) else {
            throw LibraryError.invalidAudio
        }
        let data = try Data(contentsOf: source, options: .mappedIfSafe)
        guard !data.isEmpty, data.count <= 100_000_000 else {
            throw LibraryError.invalidAudio
        }
        _ = try documents.get(entryID)
        try attachments.save(
            documentID: entryID,
            kind: "audio",
            mimeType: fileExtension == "m4a" ? "audio/mp4" : "audio/wav",
            data: data
        )
    }

    func writeText(entryID: String, variant: LibraryVariant, text: String) throws {
        let document = try documents.get(entryID)
        guard document.texts[variant] != nil else { throw LibraryError.missingVariant }
        _ = try documents.commit(SQLiteDocumentCommit(
            id: entryID,
            baseRevision: document.revision,
            texts: [variant: text]
        ))
    }

    func search(_ query: String, limit: Int) throws -> [SQLiteSearchResult] {
        try documents.search(query, limit: limit)
    }

    func getDocument(_ id: String, includeDeleted: Bool) throws -> SQLiteDocument {
        try documents.get(id, includeDeleted: includeDeleted)
    }

    func commitDocument(
        _ id: String,
        baseRevision: Int64,
        texts: [LibraryVariant: String],
        title: String?
    ) throws -> SQLiteDocument {
        try documents.commit(SQLiteDocumentCommit(
            id: id,
            baseRevision: baseRevision,
            title: title,
            texts: texts
        ))
    }

    func batch(_ commits: [SQLiteDocumentCommit]) throws -> [SQLiteDocument] {
        try documents.batch(commits)
    }

    func audioURL(entryID: String) throws -> URL? {
        try attachmentURL(entryID: entryID, kind: "audio")
    }

    func faviconURL(entryID: String) throws -> URL? {
        try attachmentURL(entryID: entryID, kind: "favicon")
    }

    private func saveCapture(
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
        let document = try documents.create(
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
            documentID: document.id
        )
        return document.id
    }

    private func saveDraftAttachments(_ draft: ItemDraft, documentID: String) throws {
        if let data = draft.faviconData,
           let ext = draft.faviconFileExtension?.lowercased(),
           data.count <= 1_000_000, validFavicon(data, fileExtension: ext) {
            try attachments.save(
                documentID: documentID,
                kind: "favicon",
                mimeType: ext == "svg" ? "image/svg+xml" :
                    ext == "jpg" ? "image/jpeg" : "image/\(ext)",
                data: data
            )
        }
        if let data = draft.audioData, !data.isEmpty, data.count <= 100_000_000,
           let mime = draft.audioMimeType, mime.lowercased().hasPrefix("audio/") {
            try attachments.save(
                documentID: documentID,
                kind: "audio",
                mimeType: mime,
                data: data
            )
        }
    }

    private func attachmentURL(entryID: String, kind: String) throws -> URL? {
        guard let (mime, data) = try attachments.data(
            documentID: entryID,
            kind: kind
        ) else { return nil }
        let directory = fileManager.temporaryDirectory
            .appending(path: "briefly-attachments", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "\(slug(entryID))-\(kind).\(fileExtension(for: mime))")
        try data.write(to: url, options: .atomic)
        return url
    }
}
