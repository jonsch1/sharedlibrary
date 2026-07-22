import Foundation

struct SharedCaptureReference: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var contentPath: String
    var sharedByID: String
    var sharedWithIDs: [String]
}

enum SharedReferenceDirection: String, Sendable {
    case shared
    case sharedWith = "shared_with"
}

enum SharingStoreError: LocalizedError, Equatable {
    case overlappingWorkspaces
    case invalidCapture
    case missingCapture
    case captureNotShared
    case invalidSharedReference

    var errorDescription: String? {
        switch self {
        case .overlappingWorkspaces:
            return "The private and shared workspaces must be separate folders and cannot contain one another."
        case .invalidCapture:
            return "Only source files directly inside the private library can be shared."
        case .missingCapture:
            return "The source file no longer exists in the private library."
        case .captureNotShared:
            return "Share the capture before assigning people."
        case .invalidSharedReference:
            return "The shared capture reference is invalid."
        }
    }
}

final class SharingStore {
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        decoder = JSONDecoder()
    }

    @discardableResult
    func ensureSharedWorkspace(
        privateWorkspaceURL: URL,
        sharedWorkspaceURL: URL
    ) throws -> URL {
        try validateWorkspaceRoots(
            privateWorkspaceURL: privateWorkspaceURL,
            sharedWorkspaceURL: sharedWorkspaceURL
        )
        try fileManager.createDirectory(
            at: sharedWorkspaceURL.appendingPathComponent("library/summaries", isDirectory: true),
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: sharedWorkspaceURL.appendingPathComponent("people", isDirectory: true),
            withIntermediateDirectories: true
        )
        return sharedWorkspaceURL
    }

    func validateWorkspaceRoots(
        privateWorkspaceURL: URL,
        sharedWorkspaceURL: URL
    ) throws {
        let privateRoot = privateWorkspaceURL.standardizedFileURL.resolvingSymlinksInPath().path
        let sharedRoot = sharedWorkspaceURL.standardizedFileURL.resolvingSymlinksInPath().path
        guard !Self.contains(privateRoot, sharedRoot),
              !Self.contains(sharedRoot, privateRoot) else {
            throw SharingStoreError.overlappingWorkspaces
        }
    }

    func isShared(
        captureAt sourceURL: URL,
        privateWorkspaceURL: URL,
        sharedWorkspaceURL: URL
    ) -> Bool {
        guard let sharedSourceURL = try? sharedSourceURL(
            for: sourceURL,
            privateWorkspaceURL: privateWorkspaceURL,
            sharedWorkspaceURL: sharedWorkspaceURL
        ) else { return false }
        return (try? isRegularNonSymbolicLink(sharedSourceURL)) == true
    }

    @discardableResult
    func shareCapture(
        at sourceURL: URL,
        privateWorkspaceURL: URL,
        sharedWorkspaceURL: URL
    ) throws -> [URL] {
        guard fileManager.fileExists(atPath: sourceURL.path) else {
            throw SharingStoreError.missingCapture
        }
        guard try isRegularNonSymbolicLink(sourceURL) else {
            throw SharingStoreError.invalidCapture
        }
        try ensureSharedWorkspace(
            privateWorkspaceURL: privateWorkspaceURL,
            sharedWorkspaceURL: sharedWorkspaceURL
        )

        let mappings = try fileMappings(
            for: sourceURL,
            privateWorkspaceURL: privateWorkspaceURL,
            sharedWorkspaceURL: sharedWorkspaceURL
        )
        var copied: [URL] = []
        for (privateURL, sharedURL) in mappings {
            if try isRegularNonSymbolicLink(privateURL) {
                try fileManager.createDirectory(
                    at: sharedURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try Data(contentsOf: privateURL).write(to: sharedURL, options: .atomic)
                copied.append(sharedURL)
            } else if fileManager.fileExists(atPath: sharedURL.path) {
                try fileManager.removeItem(at: sharedURL)
            }
        }
        return copied
    }

    @discardableResult
    func unshareCapture(
        at sourceURL: URL,
        privateWorkspaceURL: URL,
        sharedWorkspaceURL: URL
    ) throws -> [URL] {
        try validateWorkspaceRoots(
            privateWorkspaceURL: privateWorkspaceURL,
            sharedWorkspaceURL: sharedWorkspaceURL
        )
        let existingReference = try sharingReference(
            for: sourceURL,
            privateWorkspaceURL: privateWorkspaceURL,
            sharedWorkspaceURL: sharedWorkspaceURL
        )
        let mappings = try fileMappings(
            for: sourceURL,
            privateWorkspaceURL: privateWorkspaceURL,
            sharedWorkspaceURL: sharedWorkspaceURL
        )
        var removed: [URL] = []
        for (_, sharedURL) in mappings where fileManager.fileExists(atPath: sharedURL.path) {
            try fileManager.removeItem(at: sharedURL)
            removed.append(sharedURL)
        }
        if let existingReference {
            try removeReferenceFiles(
                referenceID: existingReference.id,
                sharedWorkspaceURL: sharedWorkspaceURL
            )
        }
        return removed
    }

    @discardableResult
    func tagSharedCapture(
        at sourceURL: URL,
        privateWorkspaceURL: URL,
        sharedWorkspaceURL: URL,
        sharedBy: SharedPerson,
        sharedWith recipients: [SharedPerson]
    ) throws -> SharedCaptureReference {
        let sharedSource = try sharedSourceURL(
            for: sourceURL,
            privateWorkspaceURL: privateWorkspaceURL,
            sharedWorkspaceURL: sharedWorkspaceURL
        )
        guard try isRegularNonSymbolicLink(sharedSource) else {
            throw SharingStoreError.captureNotShared
        }

        let existingReference = try sharingReference(
            for: sourceURL,
            privateWorkspaceURL: privateWorkspaceURL,
            sharedWorkspaceURL: sharedWorkspaceURL
        )
        let uniqueRecipients = recipients
            .filter { $0.githubID != sharedBy.githubID }
            .reduce(into: [String: SharedPerson]()) { result, person in
                result[person.githubID] = person
            }
        let sortedRecipients = uniqueRecipients.values.sorted {
            $0.login.localizedStandardCompare($1.login) == .orderedAscending
        }
        let reference = SharedCaptureReference(
            id: existingReference?.id ?? UUID().uuidString.lowercased(),
            contentPath: try sharedContentPath(
                for: sourceURL,
                privateWorkspaceURL: privateWorkspaceURL,
                sharedWorkspaceURL: sharedWorkspaceURL
            ),
            sharedByID: sharedBy.githubID,
            sharedWithIDs: sortedRecipients.map(\.githubID)
        )

        try removeReferenceFiles(
            referenceID: reference.id,
            sharedWorkspaceURL: sharedWorkspaceURL
        )
        try writeReference(
            reference,
            person: sharedBy,
            direction: .shared,
            sharedWorkspaceURL: sharedWorkspaceURL
        )
        for recipient in sortedRecipients {
            try writeReference(
                reference,
                person: recipient,
                direction: .sharedWith,
                sharedWorkspaceURL: sharedWorkspaceURL
            )
        }
        return reference
    }

    func sharingReference(
        for sourceURL: URL,
        privateWorkspaceURL: URL,
        sharedWorkspaceURL: URL
    ) throws -> SharedCaptureReference? {
        let contentPath = try sharedContentPath(
            for: sourceURL,
            privateWorkspaceURL: privateWorkspaceURL,
            sharedWorkspaceURL: sharedWorkspaceURL
        )
        if let sharedReference = try allReferences(
            direction: .shared,
            sharedWorkspaceURL: sharedWorkspaceURL
        ).first(where: { $0.contentPath == contentPath }) {
            return sharedReference
        }
        return try allReferences(
            direction: .sharedWith,
            sharedWorkspaceURL: sharedWorkspaceURL
        ).first { $0.contentPath == contentPath }
    }

    func references(
        for person: SharedPerson,
        direction: SharedReferenceDirection,
        sharedWorkspaceURL: URL
    ) throws -> [SharedCaptureReference] {
        let directory = personDirectory(
            person,
            sharedWorkspaceURL: sharedWorkspaceURL
        ).appendingPathComponent(direction.rawValue, isDirectory: true)
        guard fileManager.fileExists(atPath: directory.path) else { return [] }
        return try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )
        .compactMap { url -> SharedCaptureReference? in
            guard url.pathExtension.localizedCaseInsensitiveCompare("json") == .orderedSame,
                  (try? isRegularNonSymbolicLink(url)) == true,
                  let data = try? Data(contentsOf: url) else { return nil }
            return try? decoder.decode(SharedCaptureReference.self, from: data)
        }
        .sorted { $0.contentPath.localizedStandardCompare($1.contentPath) == .orderedAscending }
    }

    func sharedContentURL(
        for reference: SharedCaptureReference,
        sharedWorkspaceURL: URL
    ) throws -> URL {
        let components = NSString(string: reference.contentPath).pathComponents
        guard components.first == "library",
              !components.contains(".."),
              !reference.contentPath.hasPrefix("/") else {
            throw SharingStoreError.invalidSharedReference
        }
        return sharedWorkspaceURL.appendingPathComponent(reference.contentPath).standardizedFileURL
    }

    func retargetSharingReference(
        from oldSourceURL: URL,
        to newSourceURL: URL,
        privateWorkspaceURL: URL,
        sharedWorkspaceURL: URL
    ) throws {
        guard var reference = try sharingReference(
            for: oldSourceURL,
            privateWorkspaceURL: privateWorkspaceURL,
            sharedWorkspaceURL: sharedWorkspaceURL
        ) else { return }
        let urls = try referenceFileURLs(
            referenceID: reference.id,
            sharedWorkspaceURL: sharedWorkspaceURL
        )
        reference.contentPath = try sharedContentPath(
            for: newSourceURL,
            privateWorkspaceURL: privateWorkspaceURL,
            sharedWorkspaceURL: sharedWorkspaceURL
        )
        let data = try encoder.encode(reference)
        for url in urls {
            try data.write(to: url, options: .atomic)
        }
    }

    private func sharedContentPath(
        for sourceURL: URL,
        privateWorkspaceURL: URL,
        sharedWorkspaceURL: URL
    ) throws -> String {
        let sharedSource = try sharedSourceURL(
            for: sourceURL,
            privateWorkspaceURL: privateWorkspaceURL,
            sharedWorkspaceURL: sharedWorkspaceURL
        )
        let rootPath = sharedWorkspaceURL.standardizedFileURL.path
        let sharedPath = sharedSource.standardizedFileURL.path
        guard sharedPath.hasPrefix(rootPath + "/") else {
            throw SharingStoreError.invalidSharedReference
        }
        return String(sharedPath.dropFirst(rootPath.count + 1))
    }

    private func writeReference(
        _ reference: SharedCaptureReference,
        person: SharedPerson,
        direction: SharedReferenceDirection,
        sharedWorkspaceURL: URL
    ) throws {
        guard GitHubPeopleClient.isValidLogin(person.login) else {
            throw GitHubPeopleError.invalidLogin(person.login)
        }
        let directory = personDirectory(
            person,
            sharedWorkspaceURL: sharedWorkspaceURL
        ).appendingPathComponent(direction.rawValue, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try encoder.encode(reference).write(
            to: directory
                .appendingPathComponent(reference.id)
                .appendingPathExtension("json"),
            options: .atomic
        )
    }

    private func personDirectory(
        _ person: SharedPerson,
        sharedWorkspaceURL: URL
    ) -> URL {
        sharedWorkspaceURL
            .appendingPathComponent("people", isDirectory: true)
            .appendingPathComponent(person.login, isDirectory: true)
    }

    private func allReferences(
        direction: SharedReferenceDirection,
        sharedWorkspaceURL: URL
    ) throws -> [SharedCaptureReference] {
        let peopleRoot = sharedWorkspaceURL.appendingPathComponent("people", isDirectory: true)
        guard fileManager.fileExists(atPath: peopleRoot.path) else { return [] }
        var referencesByID: [String: SharedCaptureReference] = [:]
        let peopleDirectories = try fileManager.contentsOfDirectory(
            at: peopleRoot,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )
        for personDirectory in peopleDirectories {
            let values = try personDirectory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else { continue }
            let referencesDirectory = personDirectory.appendingPathComponent(direction.rawValue, isDirectory: true)
            guard fileManager.fileExists(atPath: referencesDirectory.path) else { continue }
            for url in try fileManager.contentsOfDirectory(
                at: referencesDirectory,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            ) where url.pathExtension.localizedCaseInsensitiveCompare("json") == .orderedSame {
                guard try isRegularNonSymbolicLink(url),
                      let reference = try? decoder.decode(
                        SharedCaptureReference.self,
                        from: Data(contentsOf: url)
                      ) else { continue }
                referencesByID[reference.id] = reference
            }
        }
        return Array(referencesByID.values)
    }

    private func referenceFileURLs(
        referenceID: String,
        sharedWorkspaceURL: URL
    ) throws -> [URL] {
        let peopleRoot = sharedWorkspaceURL.appendingPathComponent("people", isDirectory: true)
        guard fileManager.fileExists(atPath: peopleRoot.path) else { return [] }
        var urls: [URL] = []
        let peopleDirectories = try fileManager.contentsOfDirectory(
            at: peopleRoot,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )
        for personDirectory in peopleDirectories {
            let values = try personDirectory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else { continue }
            for direction in [SharedReferenceDirection.shared, .sharedWith] {
                let url = personDirectory
                    .appendingPathComponent(direction.rawValue, isDirectory: true)
                    .appendingPathComponent(referenceID)
                    .appendingPathExtension("json")
                if fileManager.fileExists(atPath: url.path),
                   try isRegularNonSymbolicLink(url) {
                    urls.append(url)
                }
            }
        }
        return urls
    }

    private func removeReferenceFiles(
        referenceID: String,
        sharedWorkspaceURL: URL
    ) throws {
        for url in try referenceFileURLs(
            referenceID: referenceID,
            sharedWorkspaceURL: sharedWorkspaceURL
        ) {
            try fileManager.removeItem(at: url)
        }
    }

    private func fileMappings(
        for sourceURL: URL,
        privateWorkspaceURL: URL,
        sharedWorkspaceURL: URL
    ) throws -> [(URL, URL)] {
        let sharedSource = try sharedSourceURL(
            for: sourceURL,
            privateWorkspaceURL: privateWorkspaceURL,
            sharedWorkspaceURL: sharedWorkspaceURL
        )
        let privateFiles = [sourceURL.standardizedFileURL]
            + LibraryStore.companionSummaryURLs(
                for: sourceURL,
                workspaceRootURL: privateWorkspaceURL
            )
        let sharedFiles = [sharedSource]
            + LibraryStore.companionSummaryURLs(
                for: sharedSource,
                workspaceRootURL: sharedWorkspaceURL
            )
        return Array(zip(privateFiles, sharedFiles))
    }

    private func sharedSourceURL(
        for sourceURL: URL,
        privateWorkspaceURL: URL,
        sharedWorkspaceURL: URL
    ) throws -> URL {
        try validateWorkspaceRoots(
            privateWorkspaceURL: privateWorkspaceURL,
            sharedWorkspaceURL: sharedWorkspaceURL
        )
        let privateLibrary = privateWorkspaceURL
            .appendingPathComponent("library", isDirectory: true)
            .standardizedFileURL
        let source = sourceURL.standardizedFileURL
        guard source.deletingLastPathComponent() == privateLibrary,
              source.pathExtension.localizedCaseInsensitiveCompare("md") == .orderedSame else {
            throw SharingStoreError.invalidCapture
        }
        return sharedWorkspaceURL
            .appendingPathComponent("library", isDirectory: true)
            .appendingPathComponent(source.lastPathComponent)
            .standardizedFileURL
    }

    private func isRegularNonSymbolicLink(_ url: URL) throws -> Bool {
        guard fileManager.fileExists(atPath: url.path) else { return false }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        return values.isRegularFile == true && values.isSymbolicLink != true
    }

    private static func contains(_ parent: String, _ child: String) -> Bool {
        child == parent || child.hasPrefix(parent + "/")
    }
}
