import CryptoKit
import Foundation

enum CloudLibraryVariant: String, CaseIterable, Codable, Hashable, Sendable {
    case brief
    case concise
    case detailed
    case comprehensive
    case source

    var title: String {
        switch self {
        case .brief: return "Brief"
        case .concise: return "Concise"
        case .detailed: return "Detailed"
        case .comprehensive: return "Comprehensive"
        case .source: return "Original"
        }
    }
}

enum CloudLibraryOrigin: String, Codable, Hashable, Sendable {
    case personal
    case shared
}

struct CloudLibraryTextPayload: Codable, Equatable, Hashable, Sendable {
    var variant: CloudLibraryVariant
    var text: String

    var wordCount: Int {
        text.split { $0.isWhitespace || $0.isNewline }.count
    }

    var contentHash: String {
        CloudLibrarySchema.sha256("\(variant.rawValue)\u{1f}\(text)")
    }
}

struct CloudLibraryEntryPayload: Identifiable, Codable, Equatable, Hashable, Sendable {
    var id: String
    var captureID: String?
    var title: String
    var excerpt: String
    var topicIDs: [String]
    var topicNames: [String]
    var tags: [String]
    var sourceURL: String?
    var createdAt: Date?
    var updatedAt: Date?
    var reviewedAt: Date?
    var origin: CloudLibraryOrigin
    var sharedByGitHubID: String?
    var sharedByDisplayName: String?
    var texts: [CloudLibraryTextPayload]

    var recordName: String {
        CloudLibrarySchema.recordName(prefix: "entry", key: id)
    }

    var metadataContentHash: String {
        struct Metadata: Encodable {
            var id: String
            var captureID: String?
            var title: String
            var excerpt: String
            var topicIDs: [String]
            var topicNames: [String]
            var tags: [String]
            var sourceURL: String?
            var createdAt: Date?
            var updatedAt: Date?
            var reviewedAt: Date?
            var origin: CloudLibraryOrigin
            var sharedByGitHubID: String?
            var sharedByDisplayName: String?
        }

        let metadata = Metadata(
            id: id,
            captureID: captureID,
            title: title,
            excerpt: excerpt,
            topicIDs: topicIDs,
            topicNames: topicNames,
            tags: tags,
            sourceURL: sourceURL,
            createdAt: createdAt,
            updatedAt: updatedAt,
            reviewedAt: reviewedAt,
            origin: origin,
            sharedByGitHubID: sharedByGitHubID,
            sharedByDisplayName: sharedByDisplayName
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = (try? encoder.encode(metadata)) ?? Data()
        return CloudLibrarySchema.sha256(data)
    }

    func textRecordName(for variant: CloudLibraryVariant) -> String {
        CloudLibrarySchema.recordName(
            prefix: "text",
            key: "\(id)\u{1f}\(variant.rawValue)"
        )
    }
}

struct CloudLibraryProjection: Codable, Equatable, Sendable {
    static let schemaVersion = 1

    var schemaVersion: Int
    var generatedAt: Date
    var entries: [CloudLibraryEntryPayload]

    init(generatedAt: Date = Date(), entries: [CloudLibraryEntryPayload]) {
        schemaVersion = Self.schemaVersion
        self.generatedAt = generatedAt
        self.entries = entries
    }
}

enum CloudLibrarySchema {
    static let containerIdentifier = "iCloud.com.sharedlibrary.app"
    static let zoneName = "SharedLibrary"
    static let entryRecordType = "LibraryEntry"
    static let textRecordType = "LibraryText"

    enum Field {
        static let schemaVersion = "schemaVersion"
        static let contentHash = "contentHash"
        static let entryID = "entryID"
        static let captureID = "captureID"
        static let title = "title"
        static let excerpt = "excerpt"
        static let topicIDs = "topicIDs"
        static let topicNames = "topicNames"
        static let tags = "tags"
        static let sourceURL = "sourceURL"
        static let createdAt = "createdAt"
        static let updatedAt = "updatedAt"
        static let reviewedAt = "reviewedAt"
        static let origin = "origin"
        static let sharedByGitHubID = "sharedByGitHubID"
        static let sharedByDisplayName = "sharedByDisplayName"
        static let variant = "variant"
        static let text = "text"
        static let textAsset = "textAsset"
        static let wordCount = "wordCount"
    }

    static func recordName(prefix: String, key: String) -> String {
        "\(prefix)-\(sha256(key))"
    }

    static func sha256(_ value: String) -> String {
        sha256(Data(value.utf8))
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
