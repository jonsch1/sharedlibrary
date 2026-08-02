import Foundation

public let librarySchemaVersion = 4

public enum LibraryVariant: String, Codable, CaseIterable, Sendable {
    case brief
    case concise
    case detailed
    case comprehensive
    case source

    public var title: String {
        switch self {
        case .brief: "Brief"
        case .concise: "Concise"
        case .detailed: "Detailed"
        case .comprehensive: "Comprehensive"
        case .source: "Source"
        }
    }
}

public enum LibraryOrigin: String, Codable, Sendable {
    case personal
    case shared
}

public enum LibraryMediaKind: String, Codable, Sendable {
    case audio
    case favicon
}

public struct LibraryTopicDefinition: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let title: String

    public init(id: String, title: String) {
        self.id = id
        self.title = title
    }
}

public struct LibraryMedia: Codable, Hashable, Sendable {
    public let kind: LibraryMediaKind
    public let path: String
    public let contentHash: String
    public let byteCount: Int
    public let contentType: String
}

public struct LibraryCloudFile: Sendable {
    public let reference: LibraryFile
    public let data: Data

    public init(reference: LibraryFile, data: Data) {
        self.reference = reference
        self.data = data
    }
}

public struct LibraryCloudMedia: Sendable {
    public let reference: LibraryMedia
    public let data: Data

    public init(reference: LibraryMedia, data: Data) {
        self.reference = reference
        self.data = data
    }
}

public struct LibraryCloudMirror: Sendable {
    public let projection: LibraryProjection
    public let files: [LibraryCloudFile]
    public let media: [LibraryCloudMedia]

    public init(
        projection: LibraryProjection,
        files: [LibraryCloudFile],
        media: [LibraryCloudMedia]
    ) {
        self.projection = projection
        self.files = files
        self.media = media
    }
}

public struct LibrarySyncMergeResult: Sendable {
    public let changed: Int
    public let conflicts: Int

    public init(changed: Int, conflicts: Int) {
        self.changed = changed
        self.conflicts = conflicts
    }
}

public struct LibrarySyncUploadResult: Sendable {
    public let changed: Int
    public let syncedAt: String

    public init(changed: Int, syncedAt: String) {
        self.changed = changed
        self.syncedAt = syncedAt
    }
}

public struct LibraryVoiceBrief: Codable, Hashable, Sendable {
    public let id: String
    public let filename: String
    public let title: String
    public let schedule: String
    public let length: String
    public let sources: [String]
    public let prompt: String?
    public let prioritizeForMe: Bool?

    public init(
        id: String,
        filename: String,
        title: String,
        schedule: String,
        length: String,
        sources: [String],
        prompt: String? = nil,
        prioritizeForMe: Bool? = nil
    ) {
        self.id = id
        self.filename = filename
        self.title = title
        self.schedule = schedule
        self.length = length
        self.sources = sources
        self.prompt = prompt
        self.prioritizeForMe = prioritizeForMe
    }

    public func matches(_ query: String) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return true }
        return ([title, schedule, length] + sources)
            .joined(separator: " ")
            .lowercased()
            .contains(needle)
    }
}

public struct LibraryVoiceBriefDraft: Hashable, Sendable {
    public let id: String?
    public let title: String
    public let schedule: String
    public let length: String
    public let sources: [String]
    public let prompt: String
    public let prioritizeForMe: Bool

    public init(
        id: String? = nil,
        title: String,
        schedule: String,
        length: String,
        sources: [String],
        prompt: String,
        prioritizeForMe: Bool
    ) {
        self.id = id
        self.title = title
        self.schedule = schedule
        self.length = length
        self.sources = sources
        self.prompt = prompt
        self.prioritizeForMe = prioritizeForMe
    }
}

public struct LibraryVoiceBriefEpisodeResult: Hashable, Sendable {
    public let entryID: String
    public let script: String

    public init(entryID: String, script: String) {
        self.entryID = entryID
        self.script = script
    }
}

public enum LibraryChannelKind: String, Codable, Hashable, Sendable {
    case feed
    case podcast
    case page
}

public struct LibraryChannelItem: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let url: String
    public let publishedAt: String?
    public let content: String?
    public let linkedURL: String?
    public let entryID: String
    public let ingestedAt: String

    public init(
        id: String,
        title: String,
        url: String,
        publishedAt: String? = nil,
        content: String? = nil,
        linkedURL: String? = nil,
        entryID: String,
        ingestedAt: String
    ) {
        self.id = id
        self.title = title
        self.url = url
        self.publishedAt = publishedAt
        self.content = content
        self.linkedURL = linkedURL
        self.entryID = entryID
        self.ingestedAt = ingestedAt
    }
}

public struct LibraryChannel: Hashable, Identifiable, Sendable {
    public let source: String
    public let title: String
    public let kind: LibraryChannelKind?
    public let schedule: String
    public let lastCheckedAt: String?
    public let error: String?
    public let retrievalCount: Int
    public let canLoadMore: Bool
    public let items: [LibraryChannelItem]
    public let briefIDs: [String]
    public let briefTitles: [String]

    public init(
        source: String,
        title: String,
        kind: LibraryChannelKind? = nil,
        schedule: String = "manual",
        lastCheckedAt: String? = nil,
        error: String? = nil,
        retrievalCount: Int = 5,
        canLoadMore: Bool = true,
        items: [LibraryChannelItem] = [],
        briefIDs: [String] = [],
        briefTitles: [String] = []
    ) {
        self.source = source
        self.title = title
        self.kind = kind
        self.schedule = schedule
        self.lastCheckedAt = lastCheckedAt
        self.error = error
        self.retrievalCount = retrievalCount
        self.canLoadMore = canLoadMore
        self.items = items
        self.briefIDs = briefIDs
        self.briefTitles = briefTitles
    }

    public var id: String { source }
    public var entryIDs: [String] { items.map(\.entryID) }

    public func matches(_ query: String) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return true }
        return ([title, source] + items.map(\.title))
            .joined(separator: " ")
            .localizedCaseInsensitiveContains(needle)
    }
}

public struct LibraryChannelRefresh: Hashable, Sendable {
    public let channel: LibraryChannel
    public let newEntryIDs: [String]

    public init(channel: LibraryChannel, newEntryIDs: [String]) {
        self.channel = channel
        self.newEntryIDs = newEntryIDs
    }
}

public struct LibraryChannelCandidate: Hashable, Sendable {
    public let id: String
    public let title: String
    public let url: String
    public let publishedAt: String?
    public let content: String
    public let linkedURL: String?
    public let preferredInput: ItemInputID?
    public let mediaURL: String?
    public let transcriptURL: String?
    public let transcriptType: String?
    public let transcriptLanguage: String?

    public init(
        id: String,
        title: String,
        url: String,
        publishedAt: String? = nil,
        content: String,
        linkedURL: String? = nil,
        preferredInput: ItemInputID? = nil,
        mediaURL: String? = nil,
        transcriptURL: String? = nil,
        transcriptType: String? = nil,
        transcriptLanguage: String? = nil
    ) {
        self.id = id
        self.title = title
        self.url = url
        self.publishedAt = publishedAt
        self.content = content
        self.linkedURL = linkedURL
        self.preferredInput = preferredInput
        self.mediaURL = mediaURL
        self.transcriptURL = transcriptURL
        self.transcriptType = transcriptType
        self.transcriptLanguage = transcriptLanguage
    }
}

public struct LibraryText: Codable, Hashable, Sendable {
    public let variant: LibraryVariant
    public let path: String?
    public let contentHash: String?
    public let wordCount: Int?
    public let text: String?

    public init(
        variant: LibraryVariant,
        path: String? = nil,
        contentHash: String? = nil,
        wordCount: Int? = nil,
        text: String? = nil
    ) {
        self.variant = variant
        self.path = path
        self.contentHash = contentHash
        self.wordCount = wordCount
        self.text = text
    }
}

public struct LibraryFile: Codable, Hashable, Sendable {
    public let path: String
    public let contentHash: String
    public let byteCount: Int

    public init(path: String, contentHash: String, byteCount: Int) {
        self.path = path
        self.contentHash = contentHash
        self.byteCount = byteCount
    }
}

public struct LibraryEntry: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let captureID: String?
    public let entryType: String?
    public let voiceBriefID: String?
    public let title: String
    public let excerpt: String
    public let topicIDs: [String]
    public let topicNames: [String]
    public let tags: [String]
    public let sourceURL: String?
    public let mediaURL: String?
    public let faviconFile: String?
    public let audio: LibraryMedia?
    public let favicon: LibraryMedia?
    public let sourceIDs: [String]?
    public let sourceURLs: [String]?
    public let hasAudio: Bool?
    public let createdAt: String?
    public let updatedAt: String?
    public let reviewedAt: String?
    public let origin: LibraryOrigin
    public let sharedByUsername: String?
    public let sharedByDisplayName: String?
    public let inboxReferenceID: String?
    public let texts: [LibraryText]

    public var ownerUsername: String? {
        sharedByUsername ?? sharedByDisplayName
    }

    public var isMainLibraryEntry: Bool {
        entryType != "voice_brief_episode" &&
            entryType != "voice_brief_source" &&
            entryType != "highlights"
    }

    public var preferredVariant: LibraryVariant {
        [.concise, .brief, .detailed, .comprehensive, .source]
            .first(where: { text(for: $0) != nil }) ?? .source
    }

    public func text(for variant: LibraryVariant) -> LibraryText? {
        texts.first { $0.variant == variant }
    }

    public func matches(_ query: String) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return true }
        return ([title, excerpt] + topicNames + tags + [ownerUsername ?? ""])
            .joined(separator: " ")
            .lowercased()
            .contains(needle)
    }
}

public struct LibraryProjection: Codable, Hashable, Sendable {
    public let schemaVersion: Int
    public let generatedAt: String
    public let files: [LibraryFile]
    public let entries: [LibraryEntry]
    public let voiceBriefs: [LibraryVoiceBrief]?

    public static func decode(_ data: Data) throws -> LibraryProjection {
        let projection: LibraryProjection
        do {
            projection = try JSONDecoder().decode(LibraryProjection.self, from: data)
        } catch {
            throw LibraryContractError.incompatible
        }
        try projection.validate()
        return projection
    }

    public static let demo: LibraryProjection = {
        guard
            let url = Bundle.module.url(forResource: "demo-library", withExtension: "json"),
            let data = try? Data(contentsOf: url),
            let projection = try? decode(data)
        else {
            preconditionFailure("The bundled Briefly demo library is invalid.")
        }
        return projection
    }()

    public static let empty = LibraryProjection(
        schemaVersion: 1,
        generatedAt: "",
        files: [],
        entries: [],
        voiceBriefs: []
    )

    public var topics: [String] {
        Array(Set(entries.flatMap(\.topicNames))).sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
    }

    public var documentTopics: [String] {
        topics.filter { topic in
            entries.contains { $0.isMainLibraryEntry && $0.topicNames.contains(topic) }
        }
    }

    public var voiceBriefDefinitions: [LibraryVoiceBrief] {
        voiceBriefs ?? []
    }

    public var channelSources: [String] {
        Array(Set(voiceBriefDefinitions.flatMap(\.sources))).sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
    }

    public func episodes(for voiceBriefID: String) -> [LibraryEntry] {
        entries
            .filter {
                $0.entryType == "voice_brief_episode" &&
                    $0.voiceBriefID == voiceBriefID
            }
            .sorted { ($0.createdAt ?? "") > ($1.createdAt ?? "") }
    }

    public func entries(forChannel source: String) -> [LibraryEntry] {
        entries
            .filter {
                $0.entryType == "voice_brief_source" &&
                    $0.sourceURL == source
            }
            .sorted { ($0.createdAt ?? "") > ($1.createdAt ?? "") }
    }

    private func validate() throws {
        guard
            schemaVersion == 2 || schemaVersion == librarySchemaVersion,
            isISO8601(generatedAt),
            files.allSatisfy({ $0.isValid }),
            entries.allSatisfy({ $0.isValid })
        else {
            throw LibraryContractError.incompatible
        }
    }
}

public enum LibraryContractError: LocalizedError {
    case incompatible

    public var errorDescription: String? {
        "This is not a compatible Briefly library index. Open Briefly and let it synchronize again."
    }
}

private extension LibraryFile {
    var isValid: Bool {
        isSafeRelativePath(path) && isSHA256(contentHash) && byteCount >= 0
    }
}

private extension LibraryEntry {
    var isValid: Bool {
        audio?.isValid ?? true &&
            favicon?.isValid ?? true &&
            texts.allSatisfy(\.isValid)
    }
}

private extension LibraryText {
    var isValid: Bool {
        if text != nil { return true }
        guard let path, let contentHash, let wordCount else { return false }
        return isSafeRelativePath(path) && isSHA256(contentHash) && wordCount >= 0
    }
}

private extension LibraryMedia {
    var isValid: Bool {
        let directory = kind == .audio ? "library/audio/" : "library/favicons/"
        return path.hasPrefix(directory) &&
            isSafeRelativePath(path) &&
            isSHA256(contentHash) &&
            byteCount > 0 &&
            contentType.hasPrefix(kind == .audio ? "audio/" : "image/")
    }
}

private func isSHA256(_ value: String) -> Bool {
    value.utf8.count == 64 && value.utf8.allSatisfy {
        (48...57).contains($0) || (97...102).contains($0)
    }
}

private func isSafeRelativePath(_ value: String) -> Bool {
    guard !value.isEmpty, !value.hasPrefix("/") else { return false }
    return !value.split(separator: "/", omittingEmptySubsequences: false)
        .contains(where: { $0.isEmpty || $0 == "." || $0 == ".." })
}

private func isISO8601(_ value: String) -> Bool {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if formatter.date(from: value) != nil { return true }
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: value) != nil
}
