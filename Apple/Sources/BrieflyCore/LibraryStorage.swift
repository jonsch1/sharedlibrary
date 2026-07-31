import CloudKit
import CryptoKit
import Foundation

public actor LibraryCache {
    private let root: URL
    private let fileManager = FileManager.default

    public init(root: URL? = nil) {
        self.root = root ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Briefly", directoryHint: .isDirectory)
    }

    public func loadProjection() throws -> LibraryProjection? {
        let url = root.appending(path: "library-index.json")
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        return try LibraryProjection.decode(Data(contentsOf: url))
    }

    public func saveProjection(_ projection: LibraryProjection) throws {
        try createRoot()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(projection).write(
            to: root.appending(path: "library-index.json"),
            options: .atomic
        )
    }

    public func contains(_ file: LibraryFile) -> Bool {
        fileManager.fileExists(atPath: cachedFileURL(for: file.contentHash).path)
    }

    public func save(_ data: Data, for file: LibraryFile) throws {
        guard data.count == file.byteCount, sha256(data) == file.contentHash else {
            throw LibraryStorageError.invalidFile(file.path)
        }
        try createRoot()
        try data.write(to: cachedFileURL(for: file.contentHash), options: .atomic)
    }

    public func contains(_ media: LibraryMedia) -> Bool {
        fileManager.fileExists(atPath: cachedMediaURL(for: media).path)
    }

    public func save(_ data: Data, for media: LibraryMedia) throws {
        guard
            data.count == media.byteCount,
            sha256(data) == media.contentHash
        else {
            throw LibraryStorageError.invalidFile(media.path)
        }
        try createRoot()
        try fileManager.createDirectory(
            at: root.appending(path: "media", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )
        try data.write(to: cachedMediaURL(for: media), options: .atomic)
    }

    public func url(for media: LibraryMedia) -> URL? {
        let url = cachedMediaURL(for: media)
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }

    public func text(for reference: LibraryText) throws -> String {
        if let text = reference.text { return displayText(text, variant: reference.variant) }
        guard let hash = reference.contentHash, let path = reference.path else { return "" }
        let data = try Data(contentsOf: cachedFileURL(for: hash))
        guard sha256(data) == hash, let text = String(data: data, encoding: .utf8) else {
            throw LibraryStorageError.invalidFile(path)
        }
        return displayText(text, variant: reference.variant)
    }

    public func removeFiles(notIn projection: LibraryProjection) throws {
        let directory = root.appending(path: "files", directoryHint: .isDirectory)
        guard let contents = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else {
            return
        }
        let active = Set(projection.files.map(\.contentHash))
        for url in contents where !active.contains(url.lastPathComponent) {
            try fileManager.removeItem(at: url)
        }
    }

    private func createRoot() throws {
        try fileManager.createDirectory(
            at: root.appending(path: "files", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )
    }

    private func cachedFileURL(for hash: String) -> URL {
        root.appending(path: "files", directoryHint: .isDirectory).appending(path: hash)
    }

    private func cachedMediaURL(for media: LibraryMedia) -> URL {
        root
            .appending(path: "media", directoryHint: .isDirectory)
            .appending(path: "\(media.contentHash).\(URL(fileURLWithPath: media.path).pathExtension)")
    }
}

public actor CloudLibrary {
    private let containerIdentifier: String?
    private var resolvedContainer: CKContainer?
    private let zoneID = CKRecordZone.ID(
        zoneName: "Briefly",
        ownerName: CKCurrentUserDefaultName
    )
    private var zoneReady = false

    public init(containerIdentifier: String? = nil) {
        let value = containerIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.containerIdentifier = value?.isEmpty == false ? value : nil
    }

    public func accountStatus() async throws -> CKAccountStatus {
        try await container().accountStatus()
    }

    public func fetchProjection() async throws -> LibraryProjection? {
        guard let record = try await record(named: "library-index") else { return nil }
        guard
            let asset = record["payload"] as? CKAsset,
            let url = asset.fileURL
        else {
            throw LibraryStorageError.missingAsset("library-index")
        }
        return try LibraryProjection.decode(Data(contentsOf: url))
    }

    public func download(_ file: LibraryFile) async throws -> Data {
        let recordName = "file-\(sha256(Data(file.path.utf8)))"
        guard let record = try await record(named: recordName) else {
            throw LibraryStorageError.missingAsset(file.path)
        }
        guard
            record["path"] as? String == file.path,
            record["contentHash"] as? String == file.contentHash,
            let asset = record["content"] as? CKAsset,
            let url = asset.fileURL
        else {
            throw LibraryStorageError.invalidFile(file.path)
        }
        let data = try Data(contentsOf: url)
        guard data.count == file.byteCount, sha256(data) == file.contentHash else {
            throw LibraryStorageError.invalidFile(file.path)
        }
        return data
    }

    public func download(_ media: LibraryMedia) async throws -> Data {
        let recordName = "media-\(media.kind.rawValue)-\(media.contentHash)"
        guard let record = try await record(named: recordName) else {
            throw LibraryStorageError.missingAsset(media.path)
        }
        guard
            record["kind"] as? String == media.kind.rawValue,
            record["path"] as? String == media.path,
            record["contentHash"] as? String == media.contentHash,
            let asset = record["content"] as? CKAsset,
            let url = asset.fileURL
        else {
            throw LibraryStorageError.invalidFile(media.path)
        }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count == media.byteCount, sha256(data) == media.contentHash else {
            throw LibraryStorageError.invalidFile(media.path)
        }
        return data
    }

    public func upload(_ mirror: LibraryCloudMirror) async throws -> LibrarySyncUploadResult {
        try await ensureZone()
        let database = try container().privateCloudDatabase
        let currentIndex = try await record(named: "library-index")
        let remoteProjection: LibraryProjection?
        if
            let asset = currentIndex?["payload"] as? CKAsset,
            let url = asset.fileURL
        {
            remoteProjection = try LibraryProjection.decode(Data(contentsOf: url))
        } else {
            remoteProjection = nil
        }
        let remoteHashes = Dictionary(
            uniqueKeysWithValues: (remoteProjection?.files ?? []).map {
                ($0.path, $0.contentHash)
            }
        )
        var changed = 0
        for file in mirror.files
        where remoteHashes[file.reference.path] != file.reference.contentHash {
            let name = "file-\(sha256(Data(file.reference.path.utf8)))"
            let record = try await record(named: name) ??
                CKRecord(
                    recordType: "BrieflyLibraryFile",
                    recordID: CKRecord.ID(recordName: name, zoneID: zoneID)
                )
            record["path"] = file.reference.path as CKRecordValue
            record["contentHash"] = file.reference.contentHash as CKRecordValue
            record["byteCount"] = file.reference.byteCount as CKRecordValue
            try await save(file.data, in: record, field: "content", database: database)
            changed += 1
        }
        for media in mirror.media {
            let reference = media.reference
            let name = "media-\(reference.kind.rawValue)-\(reference.contentHash)"
            if
                let existing = try await record(named: name),
                existing["contentHash"] as? String == reference.contentHash,
                (existing["byteCount"] as? NSNumber)?.intValue == reference.byteCount
            {
                continue
            }
            let record = CKRecord(
                recordType: "BrieflyLibraryMedia",
                recordID: CKRecord.ID(recordName: name, zoneID: zoneID)
            )
            record["kind"] = reference.kind.rawValue as CKRecordValue
            record["path"] = reference.path as CKRecordValue
            record["contentHash"] = reference.contentHash as CKRecordValue
            record["byteCount"] = reference.byteCount as CKRecordValue
            record["contentType"] = reference.contentType as CKRecordValue
            try await save(media.data, in: record, field: "content", database: database)
            changed += 1
        }

        let index = currentIndex ??
            CKRecord(
                recordType: "BrieflyLibraryIndex",
                recordID: CKRecord.ID(recordName: "library-index", zoneID: zoneID)
            )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        index["schemaVersion"] = librarySchemaVersion as CKRecordValue
        index["generatedAt"] = Int64(Date().timeIntervalSince1970 * 1_000) as CKRecordValue
        try await save(
            encoder.encode(mirror.projection),
            in: index,
            field: "payload",
            database: database
        )

        let activeFiles = Set(mirror.files.map(\.reference.path))
        for file in remoteProjection?.files ?? [] where !activeFiles.contains(file.path) {
            let name = "file-\(sha256(Data(file.path.utf8)))"
            _ = try? await database.deleteRecord(
                withID: CKRecord.ID(recordName: name, zoneID: zoneID)
            )
            changed += 1
        }
        let activeMedia = Set(mirror.media.map {
            "media-\($0.reference.kind.rawValue)-\($0.reference.contentHash)"
        })
        let remoteMedia = Set((remoteProjection?.entries ?? []).flatMap {
            [$0.audio, $0.favicon].compactMap { reference in
                reference.map {
                    "media-\($0.kind.rawValue)-\($0.contentHash)"
                }
            }
        })
        for name in remoteMedia.subtracting(activeMedia) {
            _ = try? await database.deleteRecord(
                withID: CKRecord.ID(recordName: name, zoneID: zoneID)
            )
            changed += 1
        }
        return LibrarySyncUploadResult(
            changed: changed,
            syncedAt: ISO8601DateFormatter().string(from: Date())
        )
    }

    private func save(
        _ data: Data,
        in record: CKRecord,
        field: String,
        database: CKDatabase
    ) async throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "\(UUID().uuidString).asset")
        try data.write(to: url, options: .atomic)
        defer { try? FileManager.default.removeItem(at: url) }
        record[field] = CKAsset(fileURL: url)
        _ = try await database.save(record)
    }

    private func record(named name: String) async throws -> CKRecord? {
        try await ensureZone()
        let id = CKRecord.ID(recordName: name, zoneID: zoneID)
        do {
            return try await container().privateCloudDatabase.record(for: id)
        } catch let error as CKError where error.code == .unknownItem {
            return nil
        }
    }

    private func ensureZone() async throws {
        guard !zoneReady else { return }
        let database = try container().privateCloudDatabase
        do {
            _ = try await database.recordZone(for: zoneID)
        } catch let error as CKError where error.code == .zoneNotFound {
            _ = try await database.save(CKRecordZone(zoneID: zoneID))
        }
        zoneReady = true
    }

    private func container() throws -> CKContainer {
        if let resolvedContainer { return resolvedContainer }
        guard let containerIdentifier else {
            throw LibraryStorageError.cloudKitNotConfigured
        }
        let container = CKContainer(identifier: containerIdentifier)
        resolvedContainer = container
        return container
    }
}

public enum LibraryStorageError: LocalizedError {
    case cloudKitNotConfigured
    case invalidFile(String)
    case missingAsset(String)

    public var errorDescription: String? {
        switch self {
        case .cloudKitNotConfigured:
            "Set Briefly’s CloudKit container in the native target before synchronizing."
        case .invalidFile(let path):
            "CloudKit returned an invalid copy of \(path)."
        case .missingAsset(let path):
            "CloudKit does not contain \(path)."
        }
    }
}

private func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func displayText(_ text: String, variant: LibraryVariant) -> String {
    guard variant == .source, text.hasPrefix("---\n") || text.hasPrefix("---\r\n") else {
        return text
    }
    let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
    guard let end = normalized.range(of: "\n---\n", range: normalized.index(after: normalized.startIndex)..<normalized.endIndex) else {
        return text
    }
    return normalized[end.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
}
