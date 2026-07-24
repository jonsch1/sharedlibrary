import Foundation

struct SharedCaptureReference: Codable, Equatable, Identifiable, Sendable {
    static let schemaVersion = 2

    var schemaVersion: Int
    var id: String
    var itemID: String
    var contentPath: String
    var sourceFilename: String
    var sharedByID: String
    var sharedWithIDs: [String]
    var revision: Int
    var createdAt: Date
    var updatedAt: Date
}

enum SharedInboxDisposition: String, Codable, Equatable, Sendable {
    case saved
    case dismissed
}

struct SharedInboxReference: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var itemID: String
    var contentPath: String
    var sharedByID: String
    var recipientID: String
    var revision: Int
    var disposition: SharedInboxDisposition?
    var sharedAt: Date
    var updatedAt: Date
}

struct SharedInboxItem: Identifiable, Equatable, Sendable {
    var reference: SharedInboxReference
    var title: String
    var excerpt: String
    var sharedByUsername: String?
    var sourceURL: URL
    var summaryURLs: [URL]

    var id: String { reference.id }
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
    case invalidRecipient
    case invalidInboxState

    var errorDescription: String? {
        switch self {
        case .overlappingWorkspaces:
            return "The private and shared workspaces must be separate folders and cannot contain one another."
        case .invalidCapture:
            return "Only Markdown source files directly inside the private library can be shared."
        case .missingCapture:
            return "The source file no longer exists in the private library."
        case .captureNotShared:
            return "Share the capture before assigning people."
        case .invalidSharedReference:
            return "The shared capture reference is invalid."
        case .invalidRecipient:
            return "The shared Inbox recipient is invalid."
        case .invalidInboxState:
            return "The personal shared Inbox state is invalid."
        }
    }
}

private struct PersonalInboxDecision: Codable, Equatable {
    var disposition: SharedInboxDisposition
    var handledRevision: Int
    var updatedAt: Date
}

private struct PersonalInboxState: Codable, Equatable {
    static let schemaVersion = 1

    var schemaVersion: Int
    var shares: [String: PersonalInboxDecision]
    var updatedAt: Date
}

final class SharingStore {
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
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
            at: sharedWorkspaceURL.appendingPathComponent("library", isDirectory: true),
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: sharedWorkspaceURL.appendingPathComponent("shares", isDirectory: true),
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
        if (try? sharingReference(
            for: sourceURL,
            privateWorkspaceURL: privateWorkspaceURL,
            sharedWorkspaceURL: sharedWorkspaceURL
        )) != nil {
            return true
        }
        guard let destination = try? sharedSourceURL(
            for: sourceURL,
            privateWorkspaceURL: privateWorkspaceURL,
            sharedWorkspaceURL: sharedWorkspaceURL
        ) else {
            return false
        }
        return (try? isRegularNonSymbolicLink(destination)) == true
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
        try validatePrivateSource(sourceURL, privateWorkspaceURL: privateWorkspaceURL)
        try ensureSharedWorkspace(
            privateWorkspaceURL: privateWorkspaceURL,
            sharedWorkspaceURL: sharedWorkspaceURL
        )

        let itemID = try itemID(for: sourceURL)
        let mappings = flatFileMappings(
            itemID: itemID,
            sourceURL: sourceURL,
            privateWorkspaceURL: privateWorkspaceURL,
            sharedWorkspaceURL: sharedWorkspaceURL
        )
        var copied: [URL] = []
        for mapping in mappings {
            if try isRegularNonSymbolicLink(mapping.privateURL) {
                try Data(contentsOf: mapping.privateURL).write(
                    to: mapping.sharedURL,
                    options: .atomic
                )
                copied.append(mapping.sharedURL)
            } else if fileManager.fileExists(atPath: mapping.sharedURL.path) {
                try fileManager.removeItem(at: mapping.sharedURL)
            }
        }

        if var reference = try sharingReference(
            for: sourceURL,
            privateWorkspaceURL: privateWorkspaceURL,
            sharedWorkspaceURL: sharedWorkspaceURL
        ) {
            reference.contentPath = relativeSharedPath(
                flatSourceURL(itemID: itemID, sharedWorkspaceURL: sharedWorkspaceURL),
                sharedWorkspaceURL: sharedWorkspaceURL
            )
            reference.itemID = itemID
            reference.sourceFilename = sourceURL.lastPathComponent
            reference.revision += 1
            reference.updatedAt = Date()
            try writeReference(reference, sharedWorkspaceURL: sharedWorkspaceURL)
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
        let reference = try sharingReference(
            for: sourceURL,
            privateWorkspaceURL: privateWorkspaceURL,
            sharedWorkspaceURL: sharedWorkspaceURL
        )
        let itemID = try reference?.itemID ?? itemID(for: sourceURL)
        var removed: [URL] = []
        for url in flatSharedURLs(itemID: itemID, sharedWorkspaceURL: sharedWorkspaceURL)
        where fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
            removed.append(url)
        }
        if let reference {
            let url = referenceURL(reference.id, sharedWorkspaceURL: sharedWorkspaceURL)
            if fileManager.fileExists(atPath: url.path) {
                try fileManager.removeItem(at: url)
                removed.append(url)
            }
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
        let itemID = try itemID(for: sourceURL)
        let sharedSource = flatSourceURL(
            itemID: itemID,
            sharedWorkspaceURL: sharedWorkspaceURL
        )
        guard try isRegularNonSymbolicLink(sharedSource) else {
            throw SharingStoreError.captureNotShared
        }

        let uniqueRecipients = recipients
            .filter { $0.userID != sharedBy.userID }
            .reduce(into: [String: SharedPerson]()) { result, person in
                result[person.userID] = person
            }
        let sortedRecipients = uniqueRecipients.values.sorted {
            $0.username.localizedStandardCompare($1.username) == .orderedAscending
        }
        let existing = try sharingReference(
            for: sourceURL,
            privateWorkspaceURL: privateWorkspaceURL,
            sharedWorkspaceURL: sharedWorkspaceURL
        )
        let now = Date()
        let reference = SharedCaptureReference(
            schemaVersion: SharedCaptureReference.schemaVersion,
            id: existing?.id ?? itemID,
            itemID: itemID,
            contentPath: relativeSharedPath(
                sharedSource,
                sharedWorkspaceURL: sharedWorkspaceURL
            ),
            sourceFilename: sourceURL.lastPathComponent,
            sharedByID: sharedBy.userID,
            sharedWithIDs: sortedRecipients.map(\.userID),
            revision: (existing?.revision ?? 0) + 1,
            createdAt: existing?.createdAt ?? now,
            updatedAt: now
        )
        try writeReference(reference, sharedWorkspaceURL: sharedWorkspaceURL)
        return reference
    }

    func inboxReferences(
        for person: SharedPerson,
        privateWorkspaceURL: URL,
        sharedWorkspaceURL: URL,
        includingDecided: Bool = false
    ) throws -> [SharedInboxReference] {
        let decisions = try readInboxState(privateWorkspaceURL: privateWorkspaceURL).shares
        return try references(
            for: person,
            direction: .sharedWith,
            sharedWorkspaceURL: sharedWorkspaceURL
        )
        .compactMap { reference in
            let decision = decisions[reference.id]
            if !includingDecided,
               let decision,
               decision.handledRevision >= reference.revision {
                return nil
            }
            return SharedInboxReference(
                id: reference.id,
                itemID: reference.itemID,
                contentPath: reference.contentPath,
                sharedByID: reference.sharedByID,
                recipientID: person.userID,
                revision: reference.revision,
                disposition: decision?.disposition,
                sharedAt: reference.createdAt,
                updatedAt: max(reference.updatedAt, decision?.updatedAt ?? .distantPast)
            )
        }
        .sorted { $0.updatedAt > $1.updatedAt }
    }

    func inboxItems(
        for person: SharedPerson,
        privateWorkspaceURL: URL,
        sharedWorkspaceURL: URL
    ) throws -> [SharedInboxItem] {
        let people = try PeopleDirectoryStore().people(sharedWorkspaceURL: sharedWorkspaceURL)
        let peopleByID = Dictionary(uniqueKeysWithValues: people.map { ($0.userID, $0) })
        let references = try inboxReferences(
            for: person,
            privateWorkspaceURL: privateWorkspaceURL,
            sharedWorkspaceURL: sharedWorkspaceURL
        )
        return references.compactMap { reference in
            guard let sourceURL = try? sharedContentURL(
                for: reference,
                sharedWorkspaceURL: sharedWorkspaceURL
            ),
            let sourceText = try? String(contentsOf: sourceURL, encoding: .utf8) else {
                return nil
            }
            let metadata = MarkdownMetadata.parse(sourceText)
            let body = metadata.body.trimmingCharacters(in: .whitespacesAndNewlines)
            let title = metadata.firstValue(for: "title")
                ?? reference.contentPath
                    .split(separator: "/")
                    .last
                    .map(String.init)?
                    .replacingOccurrences(of: ".source.md", with: "")
                ?? "Shared item"
            return SharedInboxItem(
                reference: reference,
                title: title,
                excerpt: String(body.replacingOccurrences(
                    of: "\\s+",
                    with: " ",
                    options: .regularExpression
                ).prefix(240)),
                sharedByUsername: peopleByID[reference.sharedByID]?.username,
                sourceURL: sourceURL,
                summaryURLs: flatSummaryURLs(
                    itemID: reference.itemID,
                    sharedWorkspaceURL: sharedWorkspaceURL
                ).filter { fileManager.fileExists(atPath: $0.path) }
            )
        }
    }

    @discardableResult
    func saveInboxItem(
        _ item: SharedInboxItem,
        privateWorkspaceURL: URL,
        sharedWorkspaceURL: URL
    ) throws -> URL {
        guard try isRegularNonSymbolicLink(item.sourceURL) else {
            throw SharingStoreError.invalidSharedReference
        }
        let privateLibrary = privateWorkspaceURL.appendingPathComponent(
            "library",
            isDirectory: true
        )
        try fileManager.createDirectory(at: privateLibrary, withIntermediateDirectories: true)
        let destination = uniquePersonalDestination(
            preferredFilename: sourceFilename(
                for: item.reference,
                sharedWorkspaceURL: sharedWorkspaceURL
            ),
            privateLibraryURL: privateLibrary
        )
        let captureID = UUID().uuidString.lowercased()
        let sourceText = try String(contentsOf: item.sourceURL, encoding: .utf8)
        try rewriteSource(
            sourceText,
            captureID: captureID,
            shareID: item.reference.id,
            shareRevision: item.reference.revision
        ).write(to: destination, atomically: true, encoding: .utf8)

        for level in SummaryDetailLevel.allCases {
            let sharedSummary = flatSummaryURL(
                itemID: item.reference.itemID,
                variant: level.storageDirectoryName,
                sharedWorkspaceURL: sharedWorkspaceURL
            )
            guard try isRegularNonSymbolicLink(sharedSummary) else { continue }
            let personalSummary = privateWorkspaceURL
                .appendingPathComponent("library/summaries", isDirectory: true)
                .appendingPathComponent(level.storageDirectoryName, isDirectory: true)
                .appendingPathComponent(destination.lastPathComponent)
            try fileManager.createDirectory(
                at: personalSummary.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data(contentsOf: sharedSummary).write(to: personalSummary, options: .atomic)
        }
        try markInbox(
            shareID: item.reference.id,
            disposition: .saved,
            revision: item.reference.revision,
            privateWorkspaceURL: privateWorkspaceURL
        )
        return destination
    }

    func dismissInboxItem(
        _ item: SharedInboxItem,
        privateWorkspaceURL: URL
    ) throws {
        try markInbox(
            shareID: item.reference.id,
            disposition: .dismissed,
            revision: item.reference.revision,
            privateWorkspaceURL: privateWorkspaceURL
        )
    }

    func sharingReference(
        for sourceURL: URL,
        privateWorkspaceURL: URL,
        sharedWorkspaceURL: URL
    ) throws -> SharedCaptureReference? {
        try validateWorkspaceRoots(
            privateWorkspaceURL: privateWorkspaceURL,
            sharedWorkspaceURL: sharedWorkspaceURL
        )
        return try allReferences(sharedWorkspaceURL: sharedWorkspaceURL).first {
            $0.sourceFilename == sourceURL.lastPathComponent
        }
    }

    func references(
        for person: SharedPerson,
        direction: SharedReferenceDirection,
        sharedWorkspaceURL: URL
    ) throws -> [SharedCaptureReference] {
        try allReferences(sharedWorkspaceURL: sharedWorkspaceURL)
            .filter { reference in
                switch direction {
                case .shared:
                    return reference.sharedByID == person.userID
                case .sharedWith:
                    return reference.sharedWithIDs.contains(person.userID)
                }
            }
            .sorted {
                if $0.updatedAt == $1.updatedAt { return $0.id < $1.id }
                return $0.updatedAt > $1.updatedAt
            }
    }

    func sharedContentURL(
        for reference: SharedCaptureReference,
        sharedWorkspaceURL: URL
    ) throws -> URL {
        guard reference.schemaVersion == SharedCaptureReference.schemaVersion,
              reference.contentPath == "library/\(reference.itemID).source.md" else {
            throw SharingStoreError.invalidSharedReference
        }
        let url = sharedWorkspaceURL
            .appendingPathComponent(reference.contentPath)
            .standardizedFileURL
        let root = sharedWorkspaceURL.standardizedFileURL.path
        guard url.path.hasPrefix(root + "/") else {
            throw SharingStoreError.invalidSharedReference
        }
        return url
    }

    func sharedContentURL(
        for reference: SharedInboxReference,
        sharedWorkspaceURL: URL
    ) throws -> URL {
        let captureReference = SharedCaptureReference(
            schemaVersion: SharedCaptureReference.schemaVersion,
            id: reference.id,
            itemID: reference.itemID,
            contentPath: reference.contentPath,
            sourceFilename: "",
            sharedByID: reference.sharedByID,
            sharedWithIDs: [reference.recipientID],
            revision: reference.revision,
            createdAt: reference.sharedAt,
            updatedAt: reference.updatedAt
        )
        return try sharedContentURL(
            for: captureReference,
            sharedWorkspaceURL: sharedWorkspaceURL
        )
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
        ) else {
            throw SharingStoreError.invalidSharedReference
        }
        let itemID = try itemID(for: newSourceURL)
        reference.itemID = itemID
        reference.contentPath = relativeSharedPath(
            flatSourceURL(itemID: itemID, sharedWorkspaceURL: sharedWorkspaceURL),
            sharedWorkspaceURL: sharedWorkspaceURL
        )
        reference.sourceFilename = newSourceURL.lastPathComponent
        reference.revision += 1
        reference.updatedAt = Date()
        try writeReference(reference, sharedWorkspaceURL: sharedWorkspaceURL)
    }

    private func allReferences(sharedWorkspaceURL: URL) throws -> [SharedCaptureReference] {
        let directory = sharedWorkspaceURL.appendingPathComponent("shares", isDirectory: true)
        guard fileManager.fileExists(atPath: directory.path) else { return [] }
        return try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )
        .filter { $0.pathExtension.lowercased() == "json" }
        .compactMap { url in
            guard let values = try? url.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
            ),
            values.isRegularFile == true,
            values.isSymbolicLink != true,
            let data = try? Data(contentsOf: url),
            let reference = try? decoder.decode(SharedCaptureReference.self, from: data),
            reference.schemaVersion == SharedCaptureReference.schemaVersion else {
                return nil
            }
            return reference
        }
    }

    private func writeReference(
        _ reference: SharedCaptureReference,
        sharedWorkspaceURL: URL
    ) throws {
        guard reference.schemaVersion == SharedCaptureReference.schemaVersion,
              Self.isSafeIdentifier(reference.id),
              Self.isSafeIdentifier(reference.itemID) else {
            throw SharingStoreError.invalidSharedReference
        }
        let directory = sharedWorkspaceURL.appendingPathComponent("shares", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try encoder.encode(reference).write(
            to: referenceURL(reference.id, sharedWorkspaceURL: sharedWorkspaceURL),
            options: .atomic
        )
    }

    private func referenceURL(_ id: String, sharedWorkspaceURL: URL) -> URL {
        sharedWorkspaceURL
            .appendingPathComponent("shares", isDirectory: true)
            .appendingPathComponent(id)
            .appendingPathExtension("json")
    }

    private func itemID(for sourceURL: URL) throws -> String {
        if fileManager.fileExists(atPath: sourceURL.path),
           let text = try? String(contentsOf: sourceURL, encoding: .utf8),
           let captureID = MarkdownMetadata.parse(text).firstValue(for: "id") {
            let normalized = captureID.lowercased()
            if Self.isSafeIdentifier(normalized) { return normalized }
        }
        return String(CloudLibrarySchema.sha256(sourceURL.lastPathComponent).prefix(32))
    }

    private func validatePrivateSource(
        _ sourceURL: URL,
        privateWorkspaceURL: URL
    ) throws {
        let privateLibrary = privateWorkspaceURL
            .appendingPathComponent("library", isDirectory: true)
            .standardizedFileURL
        let source = sourceURL.standardizedFileURL
        guard source.deletingLastPathComponent() == privateLibrary,
              source.pathExtension.localizedCaseInsensitiveCompare("md") == .orderedSame,
              try isRegularNonSymbolicLink(source) else {
            throw SharingStoreError.invalidCapture
        }
    }

    private func flatFileMappings(
        itemID: String,
        sourceURL: URL,
        privateWorkspaceURL: URL,
        sharedWorkspaceURL: URL
    ) -> [(privateURL: URL, sharedURL: URL)] {
        var mappings = [(
            sourceURL,
            flatSourceURL(itemID: itemID, sharedWorkspaceURL: sharedWorkspaceURL)
        )]
        let summariesRoot = privateWorkspaceURL.appendingPathComponent(
            "library/summaries",
            isDirectory: true
        )
        let legacy = summariesRoot.appendingPathComponent(sourceURL.lastPathComponent)
        for level in SummaryDetailLevel.allCases {
            let explicit = summariesRoot
                .appendingPathComponent(level.storageDirectoryName, isDirectory: true)
                .appendingPathComponent(sourceURL.lastPathComponent)
            let privateURL = level == .concise && !fileManager.fileExists(atPath: explicit.path)
                ? legacy
                : explicit
            mappings.append((
                privateURL,
                flatSummaryURL(
                    itemID: itemID,
                    variant: level.storageDirectoryName,
                    sharedWorkspaceURL: sharedWorkspaceURL
                )
            ))
        }
        return mappings
    }

    private func flatSourceURL(itemID: String, sharedWorkspaceURL: URL) -> URL {
        sharedWorkspaceURL
            .appendingPathComponent("library", isDirectory: true)
            .appendingPathComponent("\(itemID).source.md")
    }

    private func flatSummaryURL(
        itemID: String,
        variant: String,
        sharedWorkspaceURL: URL
    ) -> URL {
        sharedWorkspaceURL
            .appendingPathComponent("library", isDirectory: true)
            .appendingPathComponent("\(itemID).\(variant).md")
    }

    private func flatSummaryURLs(
        itemID: String,
        sharedWorkspaceURL: URL
    ) -> [URL] {
        SummaryDetailLevel.allCases.map {
            flatSummaryURL(
                itemID: itemID,
                variant: $0.storageDirectoryName,
                sharedWorkspaceURL: sharedWorkspaceURL
            )
        }
    }

    private func flatSharedURLs(
        itemID: String,
        sharedWorkspaceURL: URL
    ) -> [URL] {
        [flatSourceURL(itemID: itemID, sharedWorkspaceURL: sharedWorkspaceURL)]
            + flatSummaryURLs(itemID: itemID, sharedWorkspaceURL: sharedWorkspaceURL)
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
        return flatSourceURL(
            itemID: try itemID(for: sourceURL),
            sharedWorkspaceURL: sharedWorkspaceURL
        )
    }

    private func relativeSharedPath(_ url: URL, sharedWorkspaceURL: URL) -> String {
        String(
            url.standardizedFileURL.path.dropFirst(
                sharedWorkspaceURL.standardizedFileURL.path.count + 1
            )
        )
    }

    private func sourceFilename(
        for reference: SharedInboxReference,
        sharedWorkspaceURL: URL
    ) -> String {
        (try? allReferences(sharedWorkspaceURL: sharedWorkspaceURL).first {
            $0.id == reference.id
        }?.sourceFilename) ?? "\(reference.itemID).md"
    }

    private func uniquePersonalDestination(
        preferredFilename: String,
        privateLibraryURL: URL
    ) -> URL {
        let preferred = URL(fileURLWithPath: preferredFilename)
        let base = preferred.deletingPathExtension().lastPathComponent
        let ext = preferred.pathExtension.isEmpty ? "md" : preferred.pathExtension
        var candidate = privateLibraryURL.appendingPathComponent(preferredFilename)
        var suffix = 1
        while fileManager.fileExists(atPath: candidate.path) {
            let label = suffix == 1 ? "\(base)-shared" : "\(base)-shared-\(suffix)"
            candidate = privateLibraryURL
                .appendingPathComponent(label)
                .appendingPathExtension(ext)
            suffix += 1
        }
        return candidate
    }

    private func rewriteSource(
        _ text: String,
        captureID: String,
        shareID: String,
        shareRevision: Int
    ) -> String {
        guard text.hasPrefix("---\n"),
              let endRange = text.dropFirst(4).range(of: "\n---\n") else {
            return text
        }
        let metadataStart = text.index(text.startIndex, offsetBy: 4)
        var metadata = String(text[metadataStart..<endRange.lowerBound])
        metadata = Self.upserting(metadata, key: "id", value: captureID)
        metadata = Self.upserting(metadata, key: "shared_from", value: shareID)
        metadata = Self.upserting(metadata, key: "shared_revision", value: "\(shareRevision)")
        return "---\n\(metadata)\n---\n\(text[endRange.upperBound...])"
    }

    private static func upserting(_ metadata: String, key: String, value: String) -> String {
        let escaped = NSRegularExpression.escapedPattern(for: key)
        let pattern = "(?m)^\(escaped):.*$"
        if metadata.range(of: pattern, options: .regularExpression) != nil {
            return metadata.replacingOccurrences(
                of: pattern,
                with: "\(key): \"\(value)\"",
                options: .regularExpression
            )
        }
        return metadata + "\n\(key): \"\(value)\""
    }

    private func readInboxState(privateWorkspaceURL: URL) throws -> PersonalInboxState {
        let url = inboxStateURL(privateWorkspaceURL: privateWorkspaceURL)
        guard fileManager.fileExists(atPath: url.path) else {
            return PersonalInboxState(
                schemaVersion: PersonalInboxState.schemaVersion,
                shares: [:],
                updatedAt: Date()
            )
        }
        do {
            let state = try decoder.decode(PersonalInboxState.self, from: Data(contentsOf: url))
            guard state.schemaVersion == PersonalInboxState.schemaVersion else {
                throw SharingStoreError.invalidInboxState
            }
            return state
        } catch let error as SharingStoreError {
            throw error
        } catch {
            throw SharingStoreError.invalidInboxState
        }
    }

    private func markInbox(
        shareID: String,
        disposition: SharedInboxDisposition,
        revision: Int,
        privateWorkspaceURL: URL
    ) throws {
        var state = try readInboxState(privateWorkspaceURL: privateWorkspaceURL)
        let now = Date()
        state.shares[shareID] = PersonalInboxDecision(
            disposition: disposition,
            handledRevision: revision,
            updatedAt: now
        )
        state.updatedAt = now
        let url = inboxStateURL(privateWorkspaceURL: privateWorkspaceURL)
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try encoder.encode(state).write(to: url, options: .atomic)
    }

    private func inboxStateURL(privateWorkspaceURL: URL) -> URL {
        privateWorkspaceURL
            .appendingPathComponent(".shared-library", isDirectory: true)
            .appendingPathComponent("inbox-state.json")
    }

    private func isRegularNonSymbolicLink(_ url: URL) throws -> Bool {
        guard fileManager.fileExists(atPath: url.path) else { return false }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        return values.isRegularFile == true && values.isSymbolicLink != true
    }

    private static func isSafeIdentifier(_ value: String) -> Bool {
        !value.isEmpty
            && value.count <= 128
            && value.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
    }

    private static func contains(_ parent: String, _ child: String) -> Bool {
        child == parent || child.hasPrefix(parent + "/")
    }
}
