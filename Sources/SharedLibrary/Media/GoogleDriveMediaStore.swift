import AppKit
import Combine
import CryptoKit
import Foundation
import Network
import Security

struct GoogleDriveAccessToken: Codable, Equatable, Sendable {
    var clientID: String
    var clientSecret: String?
    var accessToken: String
    var refreshToken: String
    var expiresAt: Date
}

enum GoogleDriveError: LocalizedError {
    case invalidClientID
    case missingClientSecret
    case authorizationCancelled
    case authorizationExpired
    case invalidResponse
    case notConnected
    case requestFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidClientID:
            return "This Shared Library build is not configured with a Google OAuth Desktop Client ID."
        case .missingClientSecret:
            return "This Shared Library build is not configured with the Google OAuth Desktop Client secret."
        case .authorizationCancelled:
            return "Google Drive authorization was cancelled."
        case .authorizationExpired:
            return "The Google Drive connection expired. Connect it again."
        case .invalidResponse:
            return "Google returned an invalid authorization response."
        case .notConnected:
            return "Connect Google Drive before synchronizing the library."
        case .requestFailed(let message):
            return message
        }
    }
}

protocol GoogleDriveCredentialProviding: Sendable {
    func validAccessToken(forceRefresh: Bool) async throws -> String?
}

struct GoogleDriveWorkspaceFile: Sendable {
    var relativePath: String
    var data: Data
    var contentHash: String
    var contentType: String
}

struct GoogleDriveWorkspaceSyncResult: Sendable {
    var uploadedItemCount: Int
    var deletedItemCount: Int

    var changedItemCount: Int {
        uploadedItemCount + deletedItemCount
    }
}

struct GoogleDriveFolderSyncResult: Sendable {
    var downloadedItemCount: Int
    var uploadedItemCount: Int
    var deletedLocalItemCount: Int
    var deletedRemoteItemCount: Int

    var changedItemCount: Int {
        downloadedItemCount
            + uploadedItemCount
            + deletedLocalItemCount
            + deletedRemoteItemCount
    }
}

actor GoogleDriveCredentialVault: GoogleDriveCredentialProviding {
    static let shared = GoogleDriveCredentialVault()

    private static let tokenAccount = "google_drive_access_token"
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func storedToken() throws -> GoogleDriveAccessToken? {
        guard let value = try KeychainStore.string(for: Self.tokenAccount),
              let data = value.data(using: .utf8) else {
            return nil
        }
        return try JSONDecoder().decode(GoogleDriveAccessToken.self, from: data)
    }

    func save(_ token: GoogleDriveAccessToken) throws {
        let data = try JSONEncoder().encode(token)
        guard let value = String(data: data, encoding: .utf8) else {
            throw KeychainError.unexpectedData
        }
        try KeychainStore.setString(value, for: Self.tokenAccount)
    }

    func clear() throws {
        try KeychainStore.delete(account: Self.tokenAccount)
    }

    func validAccessToken(forceRefresh: Bool = false) async throws -> String? {
        guard var token = try storedToken() else { return nil }
        guard forceRefresh || token.expiresAt <= Date().addingTimeInterval(90) else {
            return token.accessToken
        }

        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = googleRefreshTokenFormData(token)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let value = try? JSONDecoder.google.decode(GoogleTokenResponse.self, from: data),
              let accessToken = value.accessToken else {
            try clear()
            throw GoogleDriveError.authorizationExpired
        }
        token.accessToken = accessToken
        token.expiresAt = Date().addingTimeInterval(TimeInterval(value.expiresIn ?? 3600))
        try save(token)
        return accessToken
    }
}

enum GoogleDriveAuthorizationState: Equatable {
    case disconnected
    case connecting(String)
    case connected(String)
    case failed(String)

    var message: String {
        switch self {
        case .disconnected:
            return "Google Drive is not connected."
        case .connecting(let message), .connected(let message), .failed(let message):
            return message
        }
    }

    var isBusy: Bool {
        if case .connecting = self { return true }
        return false
    }
}

@MainActor
final class GoogleDriveAuthorizationCoordinator: ObservableObject {
    @Published private(set) var state = GoogleDriveAuthorizationState.disconnected

    private let vault: GoogleDriveCredentialVault
    private let session: URLSession
    private var task: Task<Void, Never>?

    init(
        vault: GoogleDriveCredentialVault = .shared,
        session: URLSession = .shared
    ) {
        self.vault = vault
        self.session = session
    }

    func refreshStatus() {
        guard task == nil else { return }
        task = Task { [weak self] in
            guard let self else { return }
            do {
                if try await vault.validAccessToken(forceRefresh: false) != nil {
                    state = .connected("Google Drive synchronization is connected.")
                } else {
                    if case .failed = state {
                        // Preserve the actionable OAuth error while Settings is open.
                    } else {
                        state = .disconnected
                    }
                }
            } catch {
                state = .failed(error.localizedDescription)
            }
            task = nil
        }
    }

    func connect() {
        guard task == nil else { return }
        let normalized = AppSettings.shared.googleDriveDesktopClientID
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let clientSecret = AppSettings.shared.googleDriveDesktopClientSecret
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isValidClientID(normalized) else {
            state = .failed(GoogleDriveError.invalidClientID.localizedDescription)
            return
        }
        guard !clientSecret.isEmpty else {
            state = .failed(GoogleDriveError.missingClientSecret.localizedDescription)
            return
        }
        state = .connecting("Opening Google authorization...")
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let receiver = try await OAuthLoopbackReceiver.start()
                let redirectURI = receiver.redirectURI
                let stateValue = randomURLSafeString(byteCount: 24)
                let verifier = randomURLSafeString(byteCount: 64)
                let challenge = sha256URLSafe(verifier)
                var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
                components.queryItems = [
                    URLQueryItem(name: "client_id", value: normalized),
                    URLQueryItem(name: "redirect_uri", value: redirectURI.absoluteString),
                    URLQueryItem(name: "response_type", value: "code"),
                    URLQueryItem(name: "scope", value: "https://www.googleapis.com/auth/drive.file"),
                    URLQueryItem(name: "access_type", value: "offline"),
                    URLQueryItem(name: "prompt", value: "consent"),
                    URLQueryItem(name: "state", value: stateValue),
                    URLQueryItem(name: "code_challenge", value: challenge),
                    URLQueryItem(name: "code_challenge_method", value: "S256")
                ]
                guard let authorizationURL = components.url else {
                    throw GoogleDriveError.invalidResponse
                }
                NSWorkspace.shared.open(authorizationURL)
                let callback = try await receiver.waitForCallback()
                guard callback.queryValue("state") == stateValue else {
                    throw GoogleDriveError.invalidResponse
                }
                if let authorizationError = callback.queryValue("error") {
                    let description = callback.queryValue("error_description")
                        ?? authorizationError
                    throw GoogleDriveError.requestFailed(
                        "Google authorization failed: \(description)"
                    )
                }
                guard let code = callback.queryValue("code"), !code.isEmpty else {
                    throw GoogleDriveError.invalidResponse
                }
                state = .connecting("Finishing Google authorization...")
                let token = try await exchangeCode(
                    code,
                    clientID: normalized,
                    clientSecret: clientSecret,
                    verifier: verifier,
                    redirectURI: redirectURI
                )
                try await vault.save(token)
                state = .connected("Google Drive synchronization is connected.")
            } catch is CancellationError {
                state = .disconnected
            } catch {
                state = .failed(error.localizedDescription)
            }
            task = nil
        }
    }

    func disconnect() {
        task?.cancel()
        task = Task { [weak self] in
            guard let self else { return }
            do {
                try await vault.clear()
                state = .disconnected
            } catch {
                state = .failed(error.localizedDescription)
            }
            task = nil
        }
    }

    private func exchangeCode(
        _ code: String,
        clientID: String,
        clientSecret: String,
        verifier: String,
        redirectURI: URL
    ) async throws -> GoogleDriveAccessToken {
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = googleAuthorizationCodeFormData(
            code: code,
            clientID: clientID,
            clientSecret: clientSecret,
            verifier: verifier,
            redirectURI: redirectURI
        )
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let value = try? JSONDecoder.google.decode(GoogleTokenResponse.self, from: data),
              let accessToken = value.accessToken,
              let refreshToken = value.refreshToken else {
            throw GoogleDriveError.requestFailed(
                googleErrorMessage(data) ?? "Google Drive authorization failed."
            )
        }
        return GoogleDriveAccessToken(
            clientID: clientID,
            clientSecret: clientSecret,
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAt: Date().addingTimeInterval(TimeInterval(value.expiresIn ?? 3600))
        )
    }

    private static func isValidClientID(_ value: String) -> Bool {
        value.count >= 20
            && value.count <= 256
            && value.hasSuffix(".apps.googleusercontent.com")
    }
}

actor GoogleDriveMediaStore {
    static let folderName = "Shared Library"
    static let legacyFolderName = "Shared Library Media"
    static let libraryFileName = "library.json"

    private let credentials: any GoogleDriveCredentialProviding
    private let session: URLSession
    private let fileManager: FileManager
    private let cacheRoot: URL

    init(
        credentials: any GoogleDriveCredentialProviding = GoogleDriveCredentialVault.shared,
        session: URLSession = .shared,
        fileManager: FileManager = .default,
        cacheRoot: URL? = nil
    ) {
        self.credentials = credentials
        self.session = session
        self.fileManager = fileManager
        self.cacheRoot = cacheRoot ?? fileManager.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        )[0].appendingPathComponent("SharedLibrary/Media", isDirectory: true)
    }

    func localURL(hash: String, fileExtension: String) -> URL {
        cacheRoot
            .appendingPathComponent(String(hash.prefix(2)), isDirectory: true)
            .appendingPathComponent(hash)
            .appendingPathExtension(fileExtension)
    }

    func data(
        hash: String,
        fileExtension: String
    ) async throws -> Data? {
        let destination = localURL(hash: hash, fileExtension: fileExtension)
        if fileManager.fileExists(atPath: destination.path) {
            try? fileManager.setAttributes(
                [.modificationDate: Date()],
                ofItemAtPath: destination.path
            )
            return try Data(contentsOf: destination)
        }
        guard let fileID = try await remoteFileID(hash: hash) else { return nil }
        let data = try await authorizedData(
            url: URL(string: "https://www.googleapis.com/drive/v3/files/\(fileID)?alt=media")!,
            method: "GET"
        )
        try cache(data, at: destination)
        return data
    }

    func synchronizePersonalWorkspace(
        at localRootURL: URL
    ) async throws -> GoogleDriveFolderSyncResult {
        let rootID = try await ensureFolder()
        return try await synchronizeFolder(
            localRootURL: localRootURL,
            rootFolderID: rootID,
            stateFilename: "google-personal-sync-state.json",
            preferLocalOnInitialConflict: true,
            includesPath: Self.isPersonalWorkspacePath,
            includesDirectory: Self.isPersonalWorkspaceDirectory
        )
    }

    func synchronizeSharedWorkspace(
        at localRootURL: URL,
        rootFolderID: String
    ) async throws -> GoogleDriveFolderSyncResult {
        _ = try await sharedFolderMetadata(id: rootFolderID)
        return try await synchronizeFolder(
            localRootURL: localRootURL,
            rootFolderID: rootFolderID,
            stateFilename: "google-shared-\(CloudLibrarySchema.sha256(rootFolderID).prefix(12))-sync-state.json",
            preferLocalOnInitialConflict: false,
            includesPath: Self.isSharedWorkspacePath,
            includesDirectory: Self.isSharedWorkspaceDirectory
        )
    }

    func sharedFolderName(id: String) async throws -> String {
        try await sharedFolderMetadata(id: id).name ?? "Shared folder"
    }

    func syncWorkspaceMirror(
        files: [GoogleDriveWorkspaceFile],
        indexData: Data,
        indexHash: String
    ) async throws -> GoogleDriveWorkspaceSyncResult {
        let rootID = try await ensureFolder()
        var foldersByHash = try await remoteItems(kind: "folder").reduce(into: [String: String]()) {
            if let hash = $1.appProperties?["sharedLibraryPathHash"] {
                $0[hash] = $1.id
            }
        }
        var remoteFilesByHash = try await remoteItems(kind: "workspace").reduce(into: [String: DriveFile]()) {
            if let hash = $1.appProperties?["sharedLibraryPathHash"] {
                $0[hash] = $1
            }
        }
        var uploaded = 0

        for file in files {
            let pathHash = CloudLibrarySchema.sha256(file.relativePath)
            let parentPath = parentPath(of: file.relativePath)
            let parentID = try await ensureMirrorFolder(
                path: parentPath,
                rootID: rootID,
                foldersByHash: &foldersByHash
            )
            let remote = remoteFilesByHash.removeValue(forKey: pathHash)
            if remote?.appProperties?["sharedLibraryContentHash"] == file.contentHash {
                continue
            }
            _ = try await upsertFile(
                existingID: remote?.id,
                name: URL(fileURLWithPath: file.relativePath).lastPathComponent,
                parentID: parentID,
                kind: "workspace",
                pathHash: pathHash,
                contentHash: file.contentHash,
                data: file.data,
                contentType: file.contentType
            )
            uploaded += 1
        }

        var deleted = 0
        for stale in remoteFilesByHash.values {
            try await trashFile(id: stale.id)
            deleted += 1
        }

        let indexPath = ".shared-library/index.json"
        let indexPathHash = CloudLibrarySchema.sha256(indexPath)
        let indexFolderID = try await ensureMirrorFolder(
            path: ".shared-library",
            rootID: rootID,
            foldersByHash: &foldersByHash
        )
        let remoteIndex = try await remoteItems(kind: "library-index").first
        if remoteIndex?.appProperties?["sharedLibraryContentHash"] != indexHash {
            _ = try await upsertFile(
                existingID: remoteIndex?.id,
                name: "index.json",
                parentID: indexFolderID,
                kind: "library-index",
                pathHash: indexPathHash,
                contentHash: indexHash,
                data: indexData,
                contentType: "application/json"
            )
            uploaded += 1
        }

        for legacy in try await remoteItems(kind: "library") {
            try await trashFile(id: legacy.id)
            deleted += 1
        }
        return GoogleDriveWorkspaceSyncResult(
            uploadedItemCount: uploaded,
            deletedItemCount: deleted
        )
    }

    @discardableResult
    func synchronizeLocalAudioMirror() async throws -> Int {
        var downloaded = 0
        for file in try await remoteItems(kind: "audio") {
            guard let hash = file.appProperties?["sharedLibraryHash"],
                  hash.count == 64,
                  hash.allSatisfy({ $0.isHexDigit }) else {
                continue
            }
            let fileExtension = file.name
                .map { URL(fileURLWithPath: $0).pathExtension }
                .flatMap { $0.isEmpty ? nil : $0 }
                ?? "mp3"
            let destination = localURL(hash: hash, fileExtension: fileExtension)
            guard !fileManager.fileExists(atPath: destination.path) else { continue }
            let data = try await authorizedData(
                url: URL(
                    string: "https://www.googleapis.com/drive/v3/files/\(file.id)?alt=media"
                )!,
                method: "GET"
            )
            try cache(data, at: destination)
            downloaded += 1
        }
        return downloaded
    }

    func libraryProjectionData() async throws -> Data? {
        guard let fileID = try await remoteLibraryFileID() else { return nil }
        return try await authorizedData(
            url: URL(string: "https://www.googleapis.com/drive/v3/files/\(fileID)?alt=media")!,
            method: "GET"
        )
    }

    @discardableResult
    func storeLibraryProjection(_ data: Data) async throws -> String {
        if let existing = try await remoteLibraryFileID() {
            _ = try await authorizedData(
                url: URL(
                    string: "https://www.googleapis.com/upload/drive/v3/files/\(existing)?uploadType=media"
                )!,
                method: "PATCH",
                body: data,
                contentType: "application/json"
            )
            return existing
        }

        let rootID = try await ensureFolder()
        var foldersByHash = try await remoteItems(kind: "folder").reduce(into: [String: String]()) {
            if let pathHash = $1.appProperties?["sharedLibraryPathHash"] {
                $0[pathHash] = $1.id
            }
        }
        let folderID = try await ensureMirrorFolder(
            path: "audio",
            rootID: rootID,
            foldersByHash: &foldersByHash
        )
        let boundary = "SharedLibrary-\(UUID().uuidString)"
        let metadata: [String: Any] = [
            "name": Self.libraryFileName,
            "parents": [folderID],
            "appProperties": [
                "sharedLibraryKind": "library"
            ]
        ]
        let metadataData = try JSONSerialization.data(withJSONObject: metadata)
        var body = Data()
        body.append("--\(boundary)\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n".data(using: .utf8)!)
        body.append(metadataData)
        body.append("\r\n--\(boundary)\r\nContent-Type: application/json\r\n\r\n".data(using: .utf8)!)
        body.append(data)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        let response = try await authorizedData(
            url: URL(string: "https://www.googleapis.com/upload/drive/v3/files?uploadType=multipart&fields=id")!,
            method: "POST",
            body: body,
            contentType: "multipart/related; boundary=\(boundary)"
        )
        guard let value = try? JSONDecoder().decode(DriveFile.self, from: response) else {
            throw GoogleDriveError.invalidResponse
        }
        return value.id
    }

    @discardableResult
    func store(
        _ data: Data,
        hash: String,
        fileExtension: String,
        contentType: String
    ) async throws -> String {
        guard contentType.hasPrefix("audio/") else {
            throw GoogleDriveError.requestFailed("Shared Library stores generated audio only.")
        }
        let destination = localURL(hash: hash, fileExtension: fileExtension)
        try cache(data, at: destination)
        if let existing = try await remoteFileID(hash: hash) {
            return existing
        }
        let folderID = try await ensureFolder()
        let boundary = "SharedLibrary-\(UUID().uuidString)"
        let metadata: [String: Any] = [
            "name": "\(hash).\(fileExtension)",
            "parents": [folderID],
            "appProperties": [
                "sharedLibraryHash": hash,
                "sharedLibraryKind": "audio"
            ]
        ]
        let metadataData = try JSONSerialization.data(withJSONObject: metadata)
        var body = Data()
        body.append("--\(boundary)\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n".data(using: .utf8)!)
        body.append(metadataData)
        body.append("\r\n--\(boundary)\r\nContent-Type: \(contentType)\r\n\r\n".data(using: .utf8)!)
        body.append(data)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        let response = try await authorizedData(
            url: URL(string: "https://www.googleapis.com/upload/drive/v3/files?uploadType=multipart&fields=id")!,
            method: "POST",
            body: body,
            contentType: "multipart/related; boundary=\(boundary)"
        )
        guard let value = try? JSONDecoder().decode(DriveFile.self, from: response) else {
            throw GoogleDriveError.invalidResponse
        }
        return value.id
    }

    func pruneLocalCache(maximumBytes: Int64 = 2_000_000_000) throws {
        guard fileManager.fileExists(atPath: cacheRoot.path) else { return }
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .fileSizeKey,
            .contentModificationDateKey
        ]
        let files = (fileManager.enumerator(
            at: cacheRoot,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        )?.allObjects as? [URL] ?? []).compactMap { url -> (URL, Int64, Date)? in
            guard let values = try? url.resourceValues(forKeys: keys),
                  values.isRegularFile == true else { return nil }
            return (
                url,
                Int64(values.fileSize ?? 0),
                values.contentModificationDate ?? .distantPast
            )
        }
        var total = files.reduce(Int64(0)) { $0 + $1.1 }
        for file in files.sorted(by: { $0.2 < $1.2 }) where total > maximumBytes {
            try fileManager.removeItem(at: file.0)
            total -= file.1
        }
    }

    private func remoteFileID(hash: String) async throws -> String? {
        let escaped = hash.replacingOccurrences(of: "'", with: "\\'")
        var components = URLComponents(string: "https://www.googleapis.com/drive/v3/files")!
        components.queryItems = [
            URLQueryItem(
                name: "q",
                value: "appProperties has { key='sharedLibraryHash' and value='\(escaped)' } and trashed=false"
            ),
            URLQueryItem(name: "fields", value: "files(id)"),
            URLQueryItem(name: "pageSize", value: "1")
        ]
        let data = try await authorizedData(url: components.url!, method: "GET")
        return try JSONDecoder().decode(DriveFileList.self, from: data).files.first?.id
    }

    private func synchronizeFolder(
        localRootURL: URL,
        rootFolderID: String,
        stateFilename: String,
        preferLocalOnInitialConflict: Bool,
        includesPath: (String) -> Bool,
        includesDirectory: (String) -> Bool
    ) async throws -> GoogleDriveFolderSyncResult {
        let root = localRootURL.standardizedFileURL
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let stateURL = root
            .appendingPathComponent(".shared-library", isDirectory: true)
            .appendingPathComponent(stateFilename)
        let previous = (try? JSONDecoder().decode(
            GoogleDriveFolderSyncState.self,
            from: Data(contentsOf: stateURL)
        )) ?? GoogleDriveFolderSyncState(files: [:])

        var local = try localWorkspaceFiles(at: root, includesPath: includesPath)
        var remoteTree = try await remoteFolderTree(
            rootFolderID: rootFolderID,
            includesPath: includesPath,
            includesDirectory: includesDirectory
        )
        let remote = remoteTree.files
        var result = GoogleDriveFolderSyncResult(
            downloadedItemCount: 0,
            uploadedItemCount: 0,
            deletedLocalItemCount: 0,
            deletedRemoteItemCount: 0
        )
        let allPaths = Set(local.keys)
            .union(remote.keys)
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }

        for path in allPaths {
            let localFile = local[path]
            var remoteFile = remote[path]
            let previousHash = previous.files[path]
            if remoteFile?.contentHash == nil, let unresolved = remoteFile {
                let data = try await downloadDriveFile(id: unresolved.id)
                remoteFile?.contentHash = CloudLibrarySchema.sha256(data)
                remoteFile?.downloadedData = data
            }

            switch (localFile, remoteFile) {
            case let (localFile?, remoteFile?):
                guard localFile.contentHash != remoteFile.contentHash else { continue }
                let localUnchanged = previousHash == localFile.contentHash
                let remoteUnchanged = previousHash == remoteFile.contentHash
                if previousHash == nil && preferLocalOnInitialConflict {
                    try await uploadLocalFile(
                        localFile,
                        existingRemoteID: remoteFile.id,
                        rootFolderID: rootFolderID,
                        foldersByPath: &remoteTree.folders
                    )
                    result.uploadedItemCount += 1
                } else if localUnchanged && !remoteUnchanged {
                    try await writeRemoteFile(remoteFile, to: root)
                    result.downloadedItemCount += 1
                } else if remoteUnchanged && !localUnchanged {
                    try await uploadLocalFile(
                        localFile,
                        existingRemoteID: remoteFile.id,
                        rootFolderID: rootFolderID,
                        foldersByPath: &remoteTree.folders
                    )
                    result.uploadedItemCount += 1
                } else if localFile.modifiedAt > remoteFile.modifiedAt {
                    try await uploadLocalFile(
                        localFile,
                        existingRemoteID: remoteFile.id,
                        rootFolderID: rootFolderID,
                        foldersByPath: &remoteTree.folders
                    )
                    result.uploadedItemCount += 1
                } else {
                    try await writeRemoteFile(remoteFile, to: root)
                    result.downloadedItemCount += 1
                }

            case let (localFile?, nil):
                if previousHash != nil {
                    try fileManager.removeItem(at: localFile.url)
                    result.deletedLocalItemCount += 1
                } else {
                    try await uploadLocalFile(
                        localFile,
                        existingRemoteID: nil,
                        rootFolderID: rootFolderID,
                        foldersByPath: &remoteTree.folders
                    )
                    result.uploadedItemCount += 1
                }

            case let (nil, remoteFile?):
                if previousHash != nil {
                    try await trashFile(id: remoteFile.id)
                    result.deletedRemoteItemCount += 1
                } else {
                    try await writeRemoteFile(remoteFile, to: root)
                    result.downloadedItemCount += 1
                }

            case (nil, nil):
                break
            }
        }

        local = try localWorkspaceFiles(at: root, includesPath: includesPath)
        try fileManager.createDirectory(
            at: stateURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(
            GoogleDriveFolderSyncState(
                files: local.mapValues(\.contentHash)
            )
        ).write(to: stateURL, options: .atomic)
        return result
    }

    private func localWorkspaceFiles(
        at root: URL,
        includesPath: (String) -> Bool
    ) throws -> [String: LocalGoogleDriveMirrorFile] {
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .contentModificationDateKey
        ]
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return [:]
        }
        var files: [String: LocalGoogleDriveMirrorFile] = [:]
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: keys)
            guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            let rootPath = root.path + "/"
            guard url.path.hasPrefix(rootPath) else { continue }
            let relativePath = String(url.path.dropFirst(rootPath.count))
            guard includesPath(relativePath) else { continue }
            let data = try Data(contentsOf: url)
            files[relativePath] = LocalGoogleDriveMirrorFile(
                relativePath: relativePath,
                url: url,
                data: data,
                contentHash: CloudLibrarySchema.sha256(data),
                modifiedAt: values.contentModificationDate ?? .distantPast
            )
        }
        return files
    }

    private func remoteFolderTree(
        rootFolderID: String,
        includesPath: (String) -> Bool,
        includesDirectory: (String) -> Bool
    ) async throws -> RemoteGoogleDriveTree {
        var folders = ["": rootFolderID]
        var files: [String: RemoteGoogleDriveMirrorFile] = [:]
        var queue: [(path: String, id: String)] = [("", rootFolderID)]
        var nextIndex = 0
        while nextIndex < queue.count {
            let current = queue[nextIndex]
            nextIndex += 1
            for item in try await folderChildren(parentID: current.id) {
                guard let name = item.name,
                      Self.isSafeDriveName(name) else {
                    continue
                }
                let path = current.path.isEmpty ? name : "\(current.path)/\(name)"
                if item.mimeType == "application/vnd.google-apps.folder" {
                    guard includesDirectory(path) else { continue }
                    folders[path] = item.id
                    queue.append((path, item.id))
                } else if includesPath(path) {
                    files[path] = RemoteGoogleDriveMirrorFile(
                        id: item.id,
                        relativePath: path,
                        contentHash: item.appProperties?["sharedLibraryContentHash"],
                        modifiedAt: Self.driveDate(item.modifiedTime),
                        downloadedData: nil
                    )
                }
            }
        }
        return RemoteGoogleDriveTree(folders: folders, files: files)
    }

    private func folderChildren(parentID: String) async throws -> [DriveFile] {
        let escaped = parentID.replacingOccurrences(of: "'", with: "\\'")
        var results: [DriveFile] = []
        var pageToken: String?
        repeat {
            var components = URLComponents(string: "https://www.googleapis.com/drive/v3/files")!
            var items = [
                URLQueryItem(name: "q", value: "'\(escaped)' in parents and trashed=false"),
                URLQueryItem(
                    name: "fields",
                    value: "nextPageToken,files(id,name,mimeType,parents,modifiedTime,appProperties)"
                ),
                URLQueryItem(name: "pageSize", value: "1000"),
                URLQueryItem(name: "supportsAllDrives", value: "true"),
                URLQueryItem(name: "includeItemsFromAllDrives", value: "true")
            ]
            if let pageToken {
                items.append(URLQueryItem(name: "pageToken", value: pageToken))
            }
            components.queryItems = items
            let data = try await authorizedData(url: components.url!, method: "GET")
            let page = try JSONDecoder().decode(DriveFileList.self, from: data)
            results.append(contentsOf: page.files)
            pageToken = page.nextPageToken
        } while pageToken != nil
        return results
    }

    private func sharedFolderMetadata(id: String) async throws -> DriveFile {
        var components = URLComponents(
            string: "https://www.googleapis.com/drive/v3/files/\(id)"
        )!
        components.queryItems = [
            URLQueryItem(name: "fields", value: "id,name,mimeType"),
            URLQueryItem(name: "supportsAllDrives", value: "true")
        ]
        let data = try await authorizedData(url: components.url!, method: "GET")
        let folder = try JSONDecoder().decode(DriveFile.self, from: data)
        guard folder.mimeType == "application/vnd.google-apps.folder" else {
            throw GoogleDriveError.requestFailed(
                "The connected sharing location is not a Google Drive folder."
            )
        }
        return folder
    }

    private func uploadLocalFile(
        _ file: LocalGoogleDriveMirrorFile,
        existingRemoteID: String?,
        rootFolderID: String,
        foldersByPath: inout [String: String]
    ) async throws {
        let parentID = try await ensureSharedMirrorFolder(
            path: parentPath(of: file.relativePath),
            rootFolderID: rootFolderID,
            foldersByPath: &foldersByPath
        )
        _ = try await upsertFile(
            existingID: existingRemoteID,
            name: URL(fileURLWithPath: file.relativePath).lastPathComponent,
            parentID: parentID,
            kind: "shared-workspace",
            pathHash: CloudLibrarySchema.sha256(file.relativePath),
            contentHash: file.contentHash,
            data: file.data,
            contentType: Self.contentType(for: file.url)
        )
    }

    private func ensureSharedMirrorFolder(
        path: String,
        rootFolderID: String,
        foldersByPath: inout [String: String]
    ) async throws -> String {
        guard !path.isEmpty else { return rootFolderID }
        var parentID = rootFolderID
        var currentPath = ""
        for component in path.split(separator: "/").map(String.init) {
            currentPath = currentPath.isEmpty ? component : "\(currentPath)/\(component)"
            if let existing = foldersByPath[currentPath] {
                parentID = existing
                continue
            }
            let body = try JSONSerialization.data(withJSONObject: [
                "name": component,
                "mimeType": "application/vnd.google-apps.folder",
                "parents": [parentID],
                "appProperties": [
                    "sharedLibraryKind": "shared-folder",
                    "sharedLibraryPathHash": CloudLibrarySchema.sha256(currentPath)
                ]
            ])
            var components = URLComponents(
                string: "https://www.googleapis.com/drive/v3/files"
            )!
            components.queryItems = [
                URLQueryItem(name: "fields", value: "id"),
                URLQueryItem(name: "supportsAllDrives", value: "true")
            ]
            let created = try await authorizedData(
                url: components.url!,
                method: "POST",
                body: body,
                contentType: "application/json"
            )
            let id = try JSONDecoder().decode(DriveFile.self, from: created).id
            foldersByPath[currentPath] = id
            parentID = id
        }
        return parentID
    }

    private func writeRemoteFile(
        _ file: RemoteGoogleDriveMirrorFile,
        to root: URL
    ) async throws {
        let destination = root.appendingPathComponent(file.relativePath).standardizedFileURL
        guard destination.path.hasPrefix(root.path + "/") else {
            throw GoogleDriveError.invalidResponse
        }
        let data: Data
        if let downloadedData = file.downloadedData {
            data = downloadedData
        } else {
            data = try await downloadDriveFile(id: file.id)
        }
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: destination, options: .atomic)
        try? fileManager.setAttributes(
            [.modificationDate: file.modifiedAt],
            ofItemAtPath: destination.path
        )
    }

    private func downloadDriveFile(id: String) async throws -> Data {
        try await authorizedData(
            url: URL(
                string: "https://www.googleapis.com/drive/v3/files/\(id)?alt=media&supportsAllDrives=true"
            )!,
            method: "GET"
        )
    }

    private static func isPersonalWorkspacePath(_ path: String) -> Bool {
        path == "topics.md"
            || path == ".shared-library/inbox-state.json"
            || (path.hasPrefix("library/") && path.lowercased().hasSuffix(".md"))
    }

    private static func isPersonalWorkspaceDirectory(_ path: String) -> Bool {
        path == "library"
            || path.hasPrefix("library/")
            || path == ".shared-library"
    }

    private static func isSharedWorkspacePath(_ path: String) -> Bool {
        guard !path.hasPrefix("."),
              !path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else {
            return false
        }
        if path == "people.json" { return true }
        let components = path.split(separator: "/")
        guard components.count == 2 else { return false }
        if components[0] == "library" {
            return components[1].lowercased().hasSuffix(".md")
        }
        if components[0] == "shares" {
            return components[1].lowercased().hasSuffix(".json")
        }
        return false
    }

    private static func isSharedWorkspaceDirectory(_ path: String) -> Bool {
        path == "library" || path == "shares"
    }

    private static func isSafeDriveName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/")
    }

    private static func driveDate(_ value: String?) -> Date {
        guard let value else { return .distantPast }
        return ISO8601DateFormatter().date(from: value) ?? .distantPast
    }

    private static func contentType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "json": return "application/json"
        case "md", "markdown": return "text/markdown"
        case "mp3": return "audio/mpeg"
        case "m4a": return "audio/mp4"
        default: return "application/octet-stream"
        }
    }

    private func remoteItems(kind: String) async throws -> [DriveFile] {
        var results = [DriveFile]()
        var pageToken: String?
        repeat {
            var components = URLComponents(string: "https://www.googleapis.com/drive/v3/files")!
            var queryItems = [
                URLQueryItem(
                    name: "q",
                    value: "appProperties has { key='sharedLibraryKind' and value='\(kind)' } and trashed=false"
                ),
                URLQueryItem(
                    name: "fields",
                    value: "nextPageToken,files(id,name,mimeType,parents,appProperties)"
                ),
                URLQueryItem(name: "pageSize", value: "1000")
            ]
            if let pageToken {
                queryItems.append(URLQueryItem(name: "pageToken", value: pageToken))
            }
            components.queryItems = queryItems
            let data = try await authorizedData(url: components.url!, method: "GET")
            let page = try JSONDecoder().decode(DriveFileList.self, from: data)
            results.append(contentsOf: page.files)
            pageToken = page.nextPageToken
        } while pageToken != nil
        return results
    }

    private func ensureMirrorFolder(
        path: String,
        rootID: String,
        foldersByHash: inout [String: String]
    ) async throws -> String {
        guard !path.isEmpty else { return rootID }
        var parentID = rootID
        var currentPath = ""
        for component in path.split(separator: "/").map(String.init) {
            currentPath = currentPath.isEmpty ? component : "\(currentPath)/\(component)"
            let pathHash = CloudLibrarySchema.sha256(currentPath)
            if let existing = foldersByHash[pathHash] {
                parentID = existing
                continue
            }
            let body = try JSONSerialization.data(withJSONObject: [
                "name": component,
                "mimeType": "application/vnd.google-apps.folder",
                "parents": [parentID],
                "appProperties": [
                    "sharedLibraryKind": "folder",
                    "sharedLibraryPathHash": pathHash
                ]
            ])
            let created = try await authorizedData(
                url: URL(string: "https://www.googleapis.com/drive/v3/files?fields=id")!,
                method: "POST",
                body: body,
                contentType: "application/json"
            )
            let id = try JSONDecoder().decode(DriveFile.self, from: created).id
            foldersByHash[pathHash] = id
            parentID = id
        }
        return parentID
    }

    private func upsertFile(
        existingID: String?,
        name: String,
        parentID: String,
        kind: String,
        pathHash: String,
        contentHash: String,
        data: Data,
        contentType: String
    ) async throws -> String {
        let boundary = "SharedLibrary-\(UUID().uuidString)"
        var metadata: [String: Any] = [
            "name": name,
            "appProperties": [
                "sharedLibraryKind": kind,
                "sharedLibraryPathHash": pathHash,
                "sharedLibraryContentHash": contentHash
            ]
        ]
        if existingID == nil {
            metadata["parents"] = [parentID]
        }
        let metadataData = try JSONSerialization.data(withJSONObject: metadata)
        var body = Data()
        body.append("--\(boundary)\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n".data(using: .utf8)!)
        body.append(metadataData)
        body.append("\r\n--\(boundary)\r\nContent-Type: \(contentType)\r\n\r\n".data(using: .utf8)!)
        body.append(data)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        let url: URL
        let method: String
        if let existingID {
            url = URL(
                string: "https://www.googleapis.com/upload/drive/v3/files/\(existingID)?uploadType=multipart&fields=id&supportsAllDrives=true"
            )!
            method = "PATCH"
        } else {
            url = URL(
                string: "https://www.googleapis.com/upload/drive/v3/files?uploadType=multipart&fields=id&supportsAllDrives=true"
            )!
            method = "POST"
        }
        let response = try await authorizedData(
            url: url,
            method: method,
            body: body,
            contentType: "multipart/related; boundary=\(boundary)"
        )
        return try JSONDecoder().decode(DriveFile.self, from: response).id
    }

    private func trashFile(id: String) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["trashed": true])
        _ = try await authorizedData(
            url: URL(string: "https://www.googleapis.com/drive/v3/files/\(id)?supportsAllDrives=true")!,
            method: "PATCH",
            body: body,
            contentType: "application/json"
        )
    }

    private func parentPath(of relativePath: String) -> String {
        let components = relativePath.split(separator: "/").map(String.init)
        guard components.count > 1 else { return "" }
        return components.dropLast().joined(separator: "/")
    }

    private func remoteLibraryFileID() async throws -> String? {
        var components = URLComponents(string: "https://www.googleapis.com/drive/v3/files")!
        components.queryItems = [
            URLQueryItem(
                name: "q",
                value: "appProperties has { key='sharedLibraryKind' and value='library' } and trashed=false"
            ),
            URLQueryItem(name: "fields", value: "files(id)"),
            URLQueryItem(name: "pageSize", value: "1")
        ]
        let data = try await authorizedData(url: components.url!, method: "GET")
        if let id = try JSONDecoder().decode(DriveFileList.self, from: data).files.first?.id {
            return id
        }

        let folderID = try await existingFolderID()
        guard let folderID else { return nil }
        components.queryItems = [
            URLQueryItem(
                name: "q",
                value: "name='\(Self.libraryFileName)' and '\(folderID)' in parents and trashed=false"
            ),
            URLQueryItem(name: "fields", value: "files(id)"),
            URLQueryItem(name: "pageSize", value: "1")
        ]
        let fallbackData = try await authorizedData(url: components.url!, method: "GET")
        return try JSONDecoder().decode(DriveFileList.self, from: fallbackData).files.first?.id
    }

    private func ensureFolder() async throws -> String {
        if let id = try await existingFolderID() {
            return id
        }
        let body = try JSONSerialization.data(withJSONObject: [
            "name": Self.folderName,
            "mimeType": "application/vnd.google-apps.folder",
            "appProperties": ["sharedLibraryRoot": "true"]
        ])
        let created = try await authorizedData(
            url: URL(string: "https://www.googleapis.com/drive/v3/files?fields=id")!,
            method: "POST",
            body: body,
            contentType: "application/json"
        )
        return try JSONDecoder().decode(DriveFile.self, from: created).id
    }

    private func existingFolderID() async throws -> String? {
        var components = URLComponents(string: "https://www.googleapis.com/drive/v3/files")!
        components.queryItems = [
            URLQueryItem(
                name: "q",
                value: "appProperties has { key='sharedLibraryRoot' and value='true' } and mimeType='application/vnd.google-apps.folder' and trashed=false"
            ),
            URLQueryItem(name: "fields", value: "files(id)"),
            URLQueryItem(name: "pageSize", value: "1")
        ]
        let data = try await authorizedData(url: components.url!, method: "GET")
        if let id = try JSONDecoder().decode(DriveFileList.self, from: data).files.first?.id {
            return id
        }

        for name in [Self.folderName, Self.legacyFolderName] {
            components.queryItems = [
                URLQueryItem(
                    name: "q",
                    value: "name='\(name)' and mimeType='application/vnd.google-apps.folder' and trashed=false"
                ),
                URLQueryItem(name: "fields", value: "files(id)"),
                URLQueryItem(name: "pageSize", value: "1")
            ]
            let namedData = try await authorizedData(url: components.url!, method: "GET")
            if let id = try JSONDecoder().decode(DriveFileList.self, from: namedData).files.first?.id {
                var metadata: [String: Any] = [
                    "appProperties": ["sharedLibraryRoot": "true"]
                ]
                if name == Self.legacyFolderName {
                    metadata["name"] = Self.folderName
                }
                let body = try JSONSerialization.data(withJSONObject: metadata)
                _ = try await authorizedData(
                    url: URL(string: "https://www.googleapis.com/drive/v3/files/\(id)")!,
                    method: "PATCH",
                    body: body,
                    contentType: "application/json"
                )
                return id
            }
        }
        return nil
    }

    private func cache(_ data: Data, at url: URL) throws {
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
    }

    private func authorizedData(
        url: URL,
        method: String,
        body: Data? = nil,
        contentType: String? = nil
    ) async throws -> Data {
        for forceRefresh in [false, true] {
            guard let token = try await credentials.validAccessToken(forceRefresh: forceRefresh) else {
                throw GoogleDriveError.notConnected
            }
            var request = URLRequest(url: url)
            request.httpMethod = method
            request.httpBody = body
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            if let contentType {
                request.setValue(contentType, forHTTPHeaderField: "Content-Type")
            }
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw GoogleDriveError.invalidResponse
            }
            if http.statusCode == 401, !forceRefresh { continue }
            guard (200..<300).contains(http.statusCode) else {
                throw GoogleDriveError.requestFailed(
                    googleErrorMessage(data) ?? "Google Drive request failed (\(http.statusCode))."
                )
            }
            return data
        }
        throw GoogleDriveError.authorizationExpired
    }
}

final class OAuthLoopbackReceiver: @unchecked Sendable {
    var redirectURI: URL {
        guard let port = listener.port else {
            preconditionFailure("The Google OAuth loopback listener is not ready.")
        }
        return URL(string: "http://127.0.0.1:\(port.rawValue)")!
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "SharedLibrary.GoogleOAuthLoopback")
    private var callbackContinuation: CheckedContinuation<URL, Error>?
    private var pendingCallback: Result<URL, Error>?

    private init(listener: NWListener) {
        self.listener = listener
    }

    static func start() async throws -> OAuthLoopbackReceiver {
        let listener = try NWListener(using: .tcp, on: .any)
        let receiver = OAuthLoopbackReceiver(listener: listener)
        receiver.installHandler()
        _ = try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<NWEndpoint.Port, Error>) in
            let gate = ContinuationGate(continuation)
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if let port = listener.port {
                        gate.resume(.success(port))
                    } else {
                        gate.resume(.failure(GoogleDriveError.invalidResponse))
                    }
                case .failed(let error):
                    gate.resume(.failure(error))
                default:
                    break
                }
            }
            listener.start(queue: receiver.queue)
        }
        return receiver
    }

    func waitForCallback() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                if let pending = self.pendingCallback {
                    self.pendingCallback = nil
                    continuation.resume(with: pending)
                } else {
                    self.callbackContinuation = continuation
                }
            }
        }
    }

    private func installHandler() {
        listener.newConnectionHandler = { [weak self] connection in
            self?.receive(connection)
        }
    }

    private func receive(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 32_768) {
            [weak self] data, _, _, error in
            guard let self else { return }
            let result: Result<URL, Error>
            if let error {
                result = .failure(error)
            } else if let data,
                      let request = String(data: data, encoding: .utf8),
                      let firstLine = request.components(separatedBy: "\r\n").first,
                      let path = firstLine.split(separator: " ").dropFirst().first,
                      let url = URL(string: "http://127.0.0.1\(path)") {
                result = .success(url)
            } else {
                result = .failure(GoogleDriveError.invalidResponse)
            }

            let html = """
            <!doctype html><meta charset="utf-8"><title>Shared Library</title>
            <style>body{font:16px -apple-system;padding:48px;max-width:560px;margin:auto}</style>
            <h1>Authorization received</h1>
            <p>Return to Shared Library while it finishes connecting Google Drive.</p>
            """
            let response = """
            HTTP/1.1 200 OK\r
            Content-Type: text/html; charset=utf-8\r
            Content-Length: \(html.utf8.count)\r
            Connection: close\r
            \r
            \(html)
            """
            connection.send(
                content: response.data(using: .utf8),
                completion: .contentProcessed { _ in connection.cancel() }
            )
            self.finish(result)
        }
    }

    private func finish(_ result: Result<URL, Error>) {
        listener.cancel()
        if let continuation = callbackContinuation {
            callbackContinuation = nil
            continuation.resume(with: result)
        } else {
            pendingCallback = result
        }
    }
}

private final class ContinuationGate<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?

    init(_ continuation: CheckedContinuation<Value, Error>) {
        self.continuation = continuation
    }

    func resume(_ result: Result<Value, Error>) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}

private struct GoogleTokenResponse: Decodable {
    var accessToken: String?
    var refreshToken: String?
    var expiresIn: Int?
}

private struct GoogleErrorEnvelope: Decodable {
    struct ErrorValue: Decodable {
        var message: String?
    }

    enum ErrorField: Decodable {
        case code(String)
        case value(ErrorValue)

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let code = try? container.decode(String.self) {
                self = .code(code)
            } else {
                self = .value(try container.decode(ErrorValue.self))
            }
        }
    }

    var error: ErrorField?
    var errorDescription: String?
}

private struct DriveFile: Decodable {
    var id: String
    var name: String?
    var mimeType: String?
    var parents: [String]?
    var modifiedTime: String?
    var appProperties: [String: String]?
}

private struct DriveFileList: Decodable {
    var files: [DriveFile]
    var nextPageToken: String?
}

private struct GoogleDriveFolderSyncState: Codable {
    var files: [String: String]
}

private struct LocalGoogleDriveMirrorFile {
    var relativePath: String
    var url: URL
    var data: Data
    var contentHash: String
    var modifiedAt: Date
}

private struct RemoteGoogleDriveMirrorFile {
    var id: String
    var relativePath: String
    var contentHash: String?
    var modifiedAt: Date
    var downloadedData: Data?
}

private struct RemoteGoogleDriveTree {
    var folders: [String: String]
    var files: [String: RemoteGoogleDriveMirrorFile]
}

func googleAuthorizationCodeFormData(
    code: String,
    clientID: String,
    clientSecret: String,
    verifier: String,
    redirectURI: URL
) -> Data {
    googleFormData([
        "client_id": clientID,
        "client_secret": clientSecret,
        "code": code,
        "code_verifier": verifier,
        "grant_type": "authorization_code",
        "redirect_uri": redirectURI.absoluteString
    ])
}

func googleRefreshTokenFormData(_ token: GoogleDriveAccessToken) -> Data {
    var values = [
        "client_id": token.clientID,
        "refresh_token": token.refreshToken,
        "grant_type": "refresh_token"
    ]
    if let clientSecret = token.clientSecret, !clientSecret.isEmpty {
        values["client_secret"] = clientSecret
    }
    return googleFormData(values)
}

private func googleFormData(_ values: [String: String]) -> Data {
    values
        .map { key, value in
            let allowed: CharacterSet = {
                var value = CharacterSet.urlQueryAllowed
                value.remove(charactersIn: ":#[]@!$&'()*+,;=")
                return value
            }()
            return "\(key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value)"
        }
        .sorted()
        .joined(separator: "&")
        .data(using: .utf8) ?? Data()
}

private func randomURLSafeString(byteCount: Int) -> String {
    var bytes = [UInt8](repeating: 0, count: byteCount)
    _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
    return Data(bytes)
        .base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

private func sha256URLSafe(_ value: String) -> String {
    Data(SHA256.hash(data: Data(value.utf8)))
        .base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

func googleErrorMessage(_ data: Data) -> String? {
    let value = try? JSONDecoder.google.decode(GoogleErrorEnvelope.self, from: data)
    switch value?.error {
    case .code(let code):
        if let description = value?.errorDescription, !description.isEmpty {
            return "\(description) (\(code))"
        }
        return code
    case .value(let error):
        return error.message ?? value?.errorDescription
    case nil:
        return value?.errorDescription
    }
}

private extension URL {
    func queryValue(_ name: String) -> String? {
        URLComponents(url: self, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == name })?
            .value
    }
}

private extension JSONDecoder {
    static var google: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }
}
