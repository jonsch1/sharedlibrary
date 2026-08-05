import Foundation

public struct SQLiteDocument: Codable, Equatable, Sendable {
    public var id: String
    public var captureID: String
    public var type: String
    public var voiceBriefID: String?
    public var title: String
    public var sourceURL: String?
    public var mediaURL: String?
    public var createdAt: Date
    public var updatedAt: Date
    public var revision: Int64
    public var deleted: Bool
    public var topicIDs: [String]
    public var tags: [String]
    public var sourceIDs: [String]
    public var sourceURLs: [String]
    public var texts: [LibraryVariant: String]
    public var cloudRecordData: Data?

    public init(
        id: String,
        captureID: String,
        type: String = "document",
        voiceBriefID: String? = nil,
        title: String,
        sourceURL: String? = nil,
        mediaURL: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        revision: Int64 = 1,
        deleted: Bool = false,
        topicIDs: [String] = [],
        tags: [String] = [],
        sourceIDs: [String] = [],
        sourceURLs: [String] = [],
        texts: [LibraryVariant: String],
        cloudRecordData: Data? = nil
    ) {
        self.id = id
        self.captureID = captureID
        self.type = type
        self.voiceBriefID = voiceBriefID
        self.title = title
        self.sourceURL = sourceURL
        self.mediaURL = mediaURL
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.revision = revision
        self.deleted = deleted
        self.topicIDs = topicIDs
        self.tags = tags
        self.sourceIDs = sourceIDs
        self.sourceURLs = sourceURLs
        self.texts = texts
        self.cloudRecordData = cloudRecordData
    }
}

struct SQLiteDocumentIndex: Sendable {
    var document: SQLiteDocument
    var variants: [LibraryVariant]
    var excerpt: String
}

public struct SQLiteSearchResult: Equatable, Sendable {
    public let id: String
    public let title: String
    public let variant: LibraryVariant
    public let snippet: String
    public let revision: Int64
}

public struct SQLiteDocumentCommit: Sendable {
    public let id: String
    public let baseRevision: Int64
    public let title: String?
    public let type: String?
    public let voiceBriefID: String?
    public let sourceURL: String?
    public let mediaURL: String?
    public let topicIDs: [String]?
    public let tags: [String]?
    public let texts: [LibraryVariant: String]
    public let deleted: Bool?

    public init(
        id: String,
        baseRevision: Int64,
        title: String? = nil,
        type: String? = nil,
        voiceBriefID: String? = nil,
        sourceURL: String? = nil,
        mediaURL: String? = nil,
        topicIDs: [String]? = nil,
        tags: [String]? = nil,
        texts: [LibraryVariant: String] = [:],
        deleted: Bool? = nil
    ) {
        self.id = id
        self.baseRevision = baseRevision
        self.title = title
        self.type = type
        self.voiceBriefID = voiceBriefID
        self.sourceURL = sourceURL
        self.mediaURL = mediaURL
        self.topicIDs = topicIDs
        self.tags = tags
        self.texts = texts
        self.deleted = deleted
    }
}

public struct SQLiteOutboxItem: Equatable, Sendable {
    public let recordType: String
    public let documentID: String
    public let revision: Int64
    public let operation: String
}

public struct SQLiteLogicalRecord: Sendable {
    public let id: String
    public let revision: Int64
    public let deleted: Bool
    public let payload: Data
    public let cloudRecordData: Data?
}

public struct SQLiteAttachment: Equatable, Sendable {
    public let id: String
    public let documentID: String
    public let kind: String
    public let mimeType: String
    public let data: Data
    public let revision: Int64
    public let cloudRecordData: Data?
}

public struct SQLiteAttachmentMetadata: Sendable {
    public let documentID: String
    public let kind: String
    public let mimeType: String
}

public struct SQLiteChannelRecord: Sendable {
    public var source: String
    public var groupID: String
    public var groupTitle: String?
    public var title: String?
    public var kind: LibraryChannelKind?
    public var schedule: String
    public var lastCheckedAt: String?
    public var error: String?
    public var retrievalCount: Int
    public var autoSummarize: Bool
    public var canLoadMore: Bool
    public var seen: [String]
    public var items: [LibraryChannelItem]

    public init(
        source: String,
        groupID: String? = nil,
        groupTitle: String? = nil,
        title: String? = nil,
        kind: LibraryChannelKind? = nil,
        schedule: String = "manual",
        lastCheckedAt: String? = nil,
        error: String? = nil,
        retrievalCount: Int = 5,
        autoSummarize: Bool = true,
        canLoadMore: Bool = true,
        seen: [String] = [],
        items: [LibraryChannelItem] = []
    ) {
        self.source = source
        self.groupID = groupID ?? source
        self.groupTitle = groupTitle
        self.title = title
        self.kind = kind
        self.schedule = schedule
        self.lastCheckedAt = lastCheckedAt
        self.error = error
        self.retrievalCount = retrievalCount
        self.autoSummarize = autoSummarize
        self.canLoadMore = canLoadMore
        self.seen = seen
        self.items = items
    }
}

public struct SQLiteVoiceBriefRunState: Sendable {
    public var voiceBriefID: String
    public var lastRunAt: String?
    public var lastAttemptAt: String?
    public var status: String?
    public var message: String?
    public var consumed: [String]
    public var pendingEpisodeID: String?
}

public struct SQLiteProcessingJob: Sendable {
    public let documentID: String
    public let selectWhenFinished: Bool
    public let attempts: Int
}

public enum SQLiteLibraryError: LocalizedError, Equatable {
    case database(String)
    case missingDocument
    case revisionConflict(current: Int64)
    case invalidDocument

    public var errorDescription: String? {
        switch self {
        case .database(let message): message
        case .missingDocument: "That document no longer exists."
        case .revisionConflict(let current):
            "The document changed since it was read (current revision: \(current))."
        case .invalidDocument: "The document is invalid."
        }
    }
}

/// SQLite is the only writable document store. Markdown is parsed only by the explicit
/// one-time importer.
