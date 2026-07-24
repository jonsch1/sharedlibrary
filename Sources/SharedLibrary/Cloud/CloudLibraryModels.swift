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
    var sharedByUserID: String?
    var sharedByUsername: String?
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
            var sharedByUserID: String?
            var sharedByUsername: String?
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
            sharedByUserID: sharedByUserID,
            sharedByUsername: sharedByUsername
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
    static let schemaVersion = 2

    var schemaVersion: Int
    var generatedAt: Date
    var entries: [CloudLibraryEntryPayload]

    init(generatedAt: Date = Date(), entries: [CloudLibraryEntryPayload]) {
        schemaVersion = Self.schemaVersion
        self.generatedAt = generatedAt
        self.entries = entries
    }
}

struct DriveLibraryFileRecord: Codable, Equatable, Hashable, Sendable {
    var path: String
    var contentHash: String
    var byteCount: Int
}

struct DriveLibraryTextReference: Codable, Equatable, Hashable, Sendable {
    var variant: CloudLibraryVariant
    var path: String
    var contentHash: String
    var wordCount: Int
}

struct DriveLibraryIndexEntry: Identifiable, Codable, Equatable, Hashable, Sendable {
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
    var sharedByUsername: String?
    var texts: [DriveLibraryTextReference]
}

struct DriveLibraryIndex: Codable, Equatable, Sendable {
    static let schemaVersion = 3

    var schemaVersion: Int
    var generatedAt: Date
    var files: [DriveLibraryFileRecord]
    var entries: [DriveLibraryIndexEntry]

    init(
        generatedAt: Date,
        files: [DriveLibraryFileRecord],
        entries: [DriveLibraryIndexEntry]
    ) {
        schemaVersion = Self.schemaVersion
        self.generatedAt = generatedAt
        self.files = files
        self.entries = entries
    }
}

enum CloudLibrarySchema {
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
