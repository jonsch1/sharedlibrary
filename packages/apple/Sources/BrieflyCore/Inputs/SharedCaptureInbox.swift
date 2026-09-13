import Foundation

public enum BrieflySharedContainer {
    public static let appGroupIdentifier = "group.fyi.readbriefly.shared"
}

public struct PendingSharedCapture: Codable, Equatable, Identifiable, Sendable {
    public enum Payload: Codable, Equatable, Sendable {
        case url(String)
        case text(String)
        case pdf(filename: String)
    }

    public let id: UUID
    public let createdAt: Date
    public let payload: Payload
    public var originalFilename: String?
    public var attempts: Int
    public var lastError: String?

    public init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        payload: Payload,
        originalFilename: String? = nil,
        attempts: Int = 0,
        lastError: String? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.payload = payload
        self.originalFilename = originalFilename
        self.attempts = attempts
        self.lastError = lastError
    }

    public var captureID: String { id.uuidString.uppercased() }
}

public enum SharedCaptureInboxError: LocalizedError, Equatable {
    case sharedContainerUnavailable
    case invalidURL
    case emptyText
    case textTooLarge
    case invalidPDF
    case pdfTooLarge
    case corruptedCapture

    public var errorDescription: String? {
        switch self {
        case .sharedContainerUnavailable:
            "Briefly could not open its shared capture inbox."
        case .invalidURL:
            "Share an HTTP or HTTPS link without embedded credentials."
        case .emptyText:
            "The shared text is empty."
        case .textTooLarge:
            "The shared text is too large to capture."
        case .invalidPDF:
            "The shared file is not a readable PDF."
        case .pdfTooLarge:
            "PDFs must be 20 MB or smaller."
        case .corruptedCapture:
            "A pending shared capture is invalid."
        }
    }
}

/// A filesystem queue shared by the iOS app and its Share Extension. Each
/// manifest is a complete unit of work. The containing app atomically moves a
/// manifest into `Processing` before it starts network or database work.
public struct SharedCaptureInbox: Sendable {
    public static let maximumTextBytes = 1_000_000
    public static let maximumPDFBytes = 20_000_000
    public static let maximumAttempts = 3

    public let directoryURL: URL

    private var pendingDirectory: URL {
        directoryURL.appending(path: "Pending", directoryHint: .isDirectory)
    }

    private var processingDirectory: URL {
        directoryURL.appending(path: "Processing", directoryHint: .isDirectory)
    }

    private var failedDirectory: URL {
        directoryURL.appending(path: "Failed", directoryHint: .isDirectory)
    }

    private var filesDirectory: URL {
        directoryURL.appending(path: "Files", directoryHint: .isDirectory)
    }

    public init(directoryURL: URL) throws {
        self.directoryURL = directoryURL.standardizedFileURL
        try createDirectories()
    }

    public init(
        appGroupIdentifier: String = BrieflySharedContainer.appGroupIdentifier,
        fileManager: FileManager = .default
    ) throws {
        guard let container = fileManager.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        ) else {
            throw SharedCaptureInboxError.sharedContainerUnavailable
        }
        try self.init(directoryURL: container.appending(
            path: "CaptureInbox",
            directoryHint: .isDirectory
        ))
    }

    @discardableResult
    public func enqueue(url: URL, at date: Date = Date()) throws -> PendingSharedCapture {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.host != nil, url.user == nil, url.password == nil else {
            throw SharedCaptureInboxError.invalidURL
        }
        return try enqueue(PendingSharedCapture(
            createdAt: date,
            payload: .url(url.absoluteString)
        ))
    }

    @discardableResult
    public func enqueue(text: String, at date: Date = Date()) throws -> PendingSharedCapture {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SharedCaptureInboxError.emptyText }
        guard trimmed.lengthOfBytes(using: .utf8) <= Self.maximumTextBytes else {
            throw SharedCaptureInboxError.textTooLarge
        }
        return try enqueue(PendingSharedCapture(
            createdAt: date,
            payload: .text(trimmed)
        ))
    }

    /// Copies the provider-owned temporary file before this method returns.
    @discardableResult
    public func enqueuePDF(at sourceURL: URL, at date: Date = Date()) throws
        -> PendingSharedCapture
    {
        let values = try? sourceURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values?.isRegularFile == true, let size = values?.fileSize else {
            throw SharedCaptureInboxError.invalidPDF
        }
        guard size <= Self.maximumPDFBytes else { throw SharedCaptureInboxError.pdfTooLarge }

        let id = UUID()
        let filename = "\(id.uuidString.lowercased()).pdf"
        let temporary = filesDirectory.appending(path: ".\(filename).tmp")
        let destination = filesDirectory.appending(path: filename)
        do {
            try FileManager.default.copyItem(at: sourceURL, to: temporary)
            guard try isPDF(temporary) else { throw SharedCaptureInboxError.invalidPDF }
            try FileManager.default.moveItem(at: temporary, to: destination)
            let capture = PendingSharedCapture(
                id: id,
                createdAt: date,
                payload: .pdf(filename: filename),
                originalFilename: sourceURL.lastPathComponent
            )
            do {
                return try enqueue(capture)
            } catch {
                try? FileManager.default.removeItem(at: destination)
                throw error
            }
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }

    public func pendingCaptures() throws -> [PendingSharedCapture] {
        try manifests(in: pendingDirectory).sorted {
            if $0.createdAt == $1.createdAt { return $0.id.uuidString < $1.id.uuidString }
            return $0.createdAt < $1.createdAt
        }
    }

    public func failedCaptures() throws -> [PendingSharedCapture] {
        try manifests(in: failedDirectory).sorted { $0.createdAt < $1.createdAt }
    }

    public func retryFailedCaptures() throws {
        for var capture in try failedCaptures() {
            capture.attempts = 0
            capture.lastError = nil
            try write(capture, to: pendingDirectory)
            try FileManager.default.removeItem(at: manifestURL(for: capture.id, in: failedDirectory))
        }
    }

    /// Returns interrupted claims to the pending queue. Only the containing app
    /// calls this before beginning a new drain.
    public func recoverInterruptedClaims() throws {
        for source in try manifestURLs(in: processingDirectory) {
            let destination = pendingDirectory.appending(path: source.lastPathComponent)
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: source)
            } else {
                try FileManager.default.moveItem(at: source, to: destination)
            }
        }
    }

    /// Atomically claims the oldest pending capture for one importer.
    public func claimNext(excluding attemptedIDs: Set<UUID> = []) throws -> PendingSharedCapture? {
        for capture in try pendingCaptures() where !attemptedIDs.contains(capture.id) {
            let source = manifestURL(for: capture.id, in: pendingDirectory)
            let destination = manifestURL(for: capture.id, in: processingDirectory)
            do {
                try FileManager.default.moveItem(at: source, to: destination)
                return capture
            } catch CocoaError.fileNoSuchFile {
                continue
            }
        }
        return nil
    }

    public func inputRequest(for capture: PendingSharedCapture) throws -> ItemInputRequest {
        switch capture.payload {
        case .url(let value):
            guard let url = URL(string: value),
                  ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                  url.host != nil, url.user == nil, url.password == nil else {
                throw SharedCaptureInboxError.corruptedCapture
            }
            return ItemInputRequest(source: .url(url))
        case .text(let value):
            guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  value.lengthOfBytes(using: .utf8) <= Self.maximumTextBytes else {
                throw SharedCaptureInboxError.corruptedCapture
            }
            return ItemInputRequest(source: .text(value))
        case .pdf(let filename):
            guard filename == URL(filePath: filename).lastPathComponent,
                  filename.lowercased().hasSuffix(".pdf") else {
                throw SharedCaptureInboxError.corruptedCapture
            }
            let url = filesDirectory.appending(path: filename)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw SharedCaptureInboxError.corruptedCapture
            }
            return ItemInputRequest(source: .file(url), hints: .init(title: capture.originalFilename))
        }
    }

    public func complete(_ capture: PendingSharedCapture) throws {
        let manifest = manifestURL(for: capture.id, in: processingDirectory)
        if FileManager.default.fileExists(atPath: manifest.path) {
            try FileManager.default.removeItem(at: manifest)
        }
        if case .pdf(let filename) = capture.payload,
           filename == URL(filePath: filename).lastPathComponent {
            let file = filesDirectory.appending(path: filename)
            if FileManager.default.fileExists(atPath: file.path) {
                try FileManager.default.removeItem(at: file)
            }
        }
    }

    /// Releases a failed claim for a later app activation. Repeated permanent
    /// failures are retained in `Failed` for diagnostics instead of looping.
    public func release(_ capture: PendingSharedCapture, error: Error) throws {
        var updated = capture
        updated.attempts += 1
        updated.lastError = String(error.localizedDescription.prefix(500))
        let destination = updated.attempts >= Self.maximumAttempts
            ? failedDirectory
            : pendingDirectory
        try write(updated, to: destination)
        let processing = manifestURL(for: capture.id, in: processingDirectory)
        if FileManager.default.fileExists(atPath: processing.path) {
            try FileManager.default.removeItem(at: processing)
        }
    }

    private func enqueue(_ capture: PendingSharedCapture) throws -> PendingSharedCapture {
        try write(capture, to: pendingDirectory)
        return capture
    }

    private func createDirectories() throws {
        for directory in [directoryURL, pendingDirectory, processingDirectory, failedDirectory, filesDirectory] {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }
    }

    private func manifests(in directory: URL) throws -> [PendingSharedCapture] {
        try manifestURLs(in: directory).compactMap { url in
            guard let data = try? Data(contentsOf: url),
                  let capture = try? Self.decoder.decode(PendingSharedCapture.self, from: data)
            else { return nil }
            return capture
        }
    }

    private func manifestURLs(in directory: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ).filter { $0.pathExtension.lowercased() == "json" }
    }

    private func write(_ capture: PendingSharedCapture, to directory: URL) throws {
        let data = try Self.encoder.encode(capture)
        try data.write(to: manifestURL(for: capture.id, in: directory), options: .atomic)
    }

    private func manifestURL(for id: UUID, in directory: URL) -> URL {
        directory.appending(path: "\(id.uuidString.lowercased()).json")
    }

    private func isPDF(_ url: URL) throws -> Bool {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        return try handle.read(upToCount: 5) == Data("%PDF-".utf8)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
