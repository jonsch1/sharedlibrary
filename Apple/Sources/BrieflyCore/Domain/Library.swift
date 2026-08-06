import Foundation

public let librarySchemaVersion = 6

public let defaultChannelReviewLimit = 50
public let channelReviewLimitRange = 1...50

public enum LibraryVariant: String, Codable, CaseIterable, Sendable {
    case concise
    case detailed
    case source

    public var title: String {
        switch self {
        case .concise: "Concise"
        case .detailed: "Detailed"
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
    public let preferredInput: ItemInputID?
    public let mediaURL: String?
    public let transcriptURL: String?
    public let transcriptType: String?
    public let transcriptLanguage: String?
    public let entryID: String
    public let ingestedAt: String

    public init(
        id: String,
        title: String,
        url: String,
        publishedAt: String? = nil,
        content: String? = nil,
        linkedURL: String? = nil,
        preferredInput: ItemInputID? = nil,
        mediaURL: String? = nil,
        transcriptURL: String? = nil,
        transcriptType: String? = nil,
        transcriptLanguage: String? = nil,
        entryID: String,
        ingestedAt: String
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
        self.entryID = entryID
        self.ingestedAt = ingestedAt
    }

    public var isPending: Bool { entryID.isEmpty }

    public func candidate() -> LibraryChannelCandidate {
        LibraryChannelCandidate(
            id: id,
            title: title,
            url: url,
            publishedAt: publishedAt,
            content: content ?? "",
            linkedURL: linkedURL,
            preferredInput: preferredInput,
            mediaURL: mediaURL,
            transcriptURL: transcriptURL,
            transcriptType: transcriptType,
            transcriptLanguage: transcriptLanguage
        )
    }
}

public struct LibraryChannel: Hashable, Identifiable, Sendable {
    /// Stable identity for the channel. For single-source channels this is the source URL;
    /// multi-source channels use an independent identifier.
    public let source: String
    public let sources: [String]
    public let title: String
    public let kind: LibraryChannelKind?
    public let schedule: String
    public let lastCheckedAt: String?
    public let error: String?
    public let reviewLimit: Int
    public let canLoadMore: Bool
    public let items: [LibraryChannelItem]

    public init(
        source: String,
        sources: [String]? = nil,
        title: String,
        kind: LibraryChannelKind? = nil,
        schedule: String = "manual",
        lastCheckedAt: String? = nil,
        error: String? = nil,
        reviewLimit: Int = defaultChannelReviewLimit,
        canLoadMore: Bool = true,
        items: [LibraryChannelItem] = []
    ) {
        self.source = source
        self.sources = sources ?? [source]
        self.title = title
        self.kind = kind
        self.schedule = schedule
        self.lastCheckedAt = lastCheckedAt
        self.error = error
        self.reviewLimit = reviewLimit
        self.canLoadMore = canLoadMore
        self.items = items.filter(\.isPending)
    }

    public var id: String { source }
    public var primarySource: String { sources.first ?? source }
    public var entryIDs: [String] { items.map(\.entryID) }

    public func matches(_ query: String) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return true }
        return ([title] + sources + items.map(\.title))
            .joined(separator: " ")
            .localizedCaseInsensitiveContains(needle)
    }
}

public struct LibraryChannelRefresh: Hashable, Sendable {
    public let channel: LibraryChannel
    public let newItemIDs: [String]

    public init(channel: LibraryChannel, newItemIDs: [String]) {
        self.channel = channel
        self.newItemIDs = newItemIDs
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
    public let channelSources: [String]?
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
        entryType != "highlights"
    }

    public var preferredVariant: LibraryVariant {
        [.concise, .detailed, .source]
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
