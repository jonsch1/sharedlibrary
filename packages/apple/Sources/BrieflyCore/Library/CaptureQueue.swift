import Foundation

extension SQLiteLibraryStore {
    /// Persists original input without fetching, parsing, or calling a model. The
    /// document, original file, and upload intent commit together before acknowledgement.
    public func queueCapture(
        _ input: ItemInputRequest,
        captureID: String = UUID().uuidString.uppercased(),
        createdAt: Date = Date()
    ) throws -> String {
        let database = try database()
        return try database.locked {
            try database.transaction {
                if let existing = try database.document(captureID: captureID) { return existing.id }
                let payload: CaptureRequest.Payload
                let title: String
                let sourceURL: String?
                let type: String
                var file: Data?
                switch input.source {
                case .url(let url):
                    guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                          url.host != nil, url.user == nil, url.password == nil else {
                        throw SharedCaptureInboxError.invalidURL
                    }
                    payload = .url(url.absoluteString)
                    title = input.hints.title?.nilIfEmpty ?? url.host ?? "Shared link"
                    sourceURL = url.absoluteString
                    type = "link"
                case .text(let value):
                    let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { throw SharedCaptureInboxError.emptyText }
                    guard text.utf8.count <= SharedCaptureInbox.maximumTextBytes else {
                        throw SharedCaptureInboxError.textTooLarge
                    }
                    payload = .text(text)
                    title = input.hints.title?.nilIfEmpty ?? String(text.prefix(100))
                    sourceURL = nil
                    type = "text"
                case .file(let url):
                    let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                    guard size <= SharedCaptureInbox.maximumPDFBytes else {
                        throw SharedCaptureInboxError.pdfTooLarge
                    }
                    let data = try Data(contentsOf: url)
                    guard data.count <= SharedCaptureInbox.maximumPDFBytes,
                          data.starts(with: Data("%PDF-".utf8)) else {
                        throw SharedCaptureInboxError.invalidPDF
                    }
                    file = data
                    let filename = input.hints.title?.nilIfEmpty ?? url.lastPathComponent
                    title = URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent
                    payload = .pdf(filename)
                    sourceURL = nil
                    type = "pdf"
                }
                let document = try database.createDocument(
                    title: title, body: "", texts: [.source: ""], type: type,
                    sourceURL: sourceURL, captureID: captureID, createdAt: createdAt,
                    captureRequest: CaptureRequest(payload: payload)
                )
                if let file {
                    try database.saveAttachment(
                        documentID: document.id, kind: "original-pdf",
                        mimeType: "application/pdf", data: file
                    )
                }
                return document.id
            }
        }
    }

    public func retryCapture(_ entryID: String) throws {
        let database = try database()
        let document = try database.getDocument(entryID)
        guard var request = document.captureRequest, request.state == .failed else { return }
        request.state = .queued
        request.error = nil
        _ = try database.commitDocument(.init(
            id: entryID, baseRevision: document.revision, captureRequest: request
        ))
    }

    #if os(macOS)
    public func pendingCaptureIDs() throws -> [String] {
        try database().allDocuments().filter {
            guard let request = $0.captureRequest else { return false }
            return request.state != .ready && request.state != .failed
        }.sorted { $0.createdAt < $1.createdAt }.map(\.id)
    }

    /// The Mac resumes from the last durable stage. A missing PDF attachment means
    /// iCloud has not delivered all records yet; it must not consume a retry.
    public func extractQueuedCapture(
        _ entryID: String,
        context: ItemInputContext,
        extract: (@MainActor @Sendable (ItemInputRequest) async throws -> ItemDraft)? = nil,
        onStateChanged: @MainActor @Sendable () async -> Void = {}
    ) async throws {
        let database = try database()
        let document = try database.getDocument(entryID)
        guard var request = document.captureRequest,
              request.state != .ready, request.state != .failed else { return }
        if request.hasExtractedSource {
            request.state = .summarizing
            request.error = nil
            _ = try database.commitDocument(.init(id: entryID, baseRevision: document.revision, captureRequest: request))
            try database.enqueueProcessingJob(documentID: entryID, selectWhenFinished: false)
            return
        }
        let input: ItemInputRequest
        var temporary: URL?
        switch request.payload {
        case .url(let value):
            guard let url = URL(string: value) else { throw SharedCaptureInboxError.invalidURL }
            input = .init(source: .url(url))
        case .text(let value):
            input = .init(source: .text(value))
        case .pdf:
            guard let (_, data) = try database.attachment(documentID: entryID, kind: "original-pdf") else {
                return
            }
            let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID()).pdf")
            try data.write(to: url, options: .atomic)
            temporary = url
            input = .init(source: .file(url))
        }
        defer { if let temporary { try? FileManager.default.removeItem(at: temporary) } }
        request.state = .extracting
        _ = try database.commitDocument(.init(
            id: entryID, baseRevision: document.revision, captureRequest: request
        ))
        await onStateChanged()
        do {
            let draft: ItemDraft
            if let extract { draft = try await extract(input) }
            else { draft = try await NativeItemInputRouter().ingest(input, context: context) }
            try Task.checkCancellation()
            // Re-read after suspension; deleted captures must never be resurrected.
            let current = try database.getDocument(entryID)
            guard current.captureRequest?.state == .extracting else { return }
            let content = draft.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !content.isEmpty else { throw LibraryError.emptyCapture }
            request.hasExtractedSource = true
            request.state = .summarizing
            request.error = nil
            try database.locked {
                try database.transaction {
                    _ = try database.commitDocument(.init(
                        id: entryID, baseRevision: current.revision, title: draft.title,
                        sourceURL: (draft.canonicalURL ?? draft.sourceURL)?.absoluteString,
                        mediaURL: draft.mediaURL?.absoluteString,
                        texts: [.source: content], captureRequest: request
                    ))
                    // The capture service attaches media to this same stable identity.
                    _ = try captureItem(draft, captureID: current.captureID)
                    try database.enqueueProcessingJob(documentID: entryID, selectWhenFinished: false)
                }
            }
            await onStateChanged()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try failCapture(entryID, error: error.localizedDescription)
            throw error
        }
    }

    public func failCapture(_ entryID: String, error: String) throws {
        let database = try database()
        guard let document = try? database.getDocument(entryID),
              var request = document.captureRequest, request.state != .ready else { return }
        request.state = .failed
        request.error = String(error.prefix(1_000))
        _ = try database.commitDocument(.init(
            id: entryID, baseRevision: document.revision, captureRequest: request
        ))
    }
    #endif
}
