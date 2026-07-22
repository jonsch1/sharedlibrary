import Foundation

enum SharingStoreError: LocalizedError, Equatable {
    case overlappingWorkspaces
    case invalidCapture
    case missingCapture

    var errorDescription: String? {
        switch self {
        case .overlappingWorkspaces:
            return "The private and shared workspaces must be separate folders and cannot contain one another."
        case .invalidCapture:
            return "Only source files directly inside the private library can be shared."
        case .missingCapture:
            return "The source file no longer exists in the private library."
        }
    }
}

final class SharingStore {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
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
        return removed
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
