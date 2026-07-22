import Foundation

struct LibraryItem: Identifiable, Hashable {
    var id: String
    var type: String
    var createdAt: Int64
    var updatedAt: Int64
    var reviewedAt: Int64?
    var url: String
    var title: String
    var tags: [String]
    var topics: [String]
    var clusterID: String?
    var clusterName: String?
    var embeddingModel: String?
    var content: String
    var fileURL: URL?

    init(id: String = UUID().uuidString,
         type: String = "link",
         createdAt: Int64 = Int64((Date().timeIntervalSince1970 * 1000).rounded()),
         updatedAt: Int64 = Int64((Date().timeIntervalSince1970 * 1000).rounded()),
         reviewedAt: Int64? = nil,
         url: String,
         title: String,
         tags: [String] = [],
         topics: [String] = [],
         clusterID: String? = nil,
         clusterName: String? = nil,
         embeddingModel: String? = nil,
         content: String,
         fileURL: URL? = nil) {
        self.id = id
        self.type = type
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.reviewedAt = reviewedAt
        self.url = url
        self.title = title
        self.tags = tags
        self.topics = topics
        self.clusterID = clusterID
        self.clusterName = clusterName
        self.embeddingModel = embeddingModel
        self.content = content
        self.fileURL = fileURL
    }

    var createdAtDate: Date {
        Date(timeIntervalSince1970: Double(createdAt) / 1000)
    }

    var updatedAtDate: Date {
        Date(timeIntervalSince1970: Double(updatedAt) / 1000)
    }

    var reviewedAtDate: Date? {
        reviewedAt.map { Date(timeIntervalSince1970: Double($0) / 1000) }
    }

    var wordCount: Int {
        content.split { $0.isWhitespace || $0.isNewline }.count
    }
}

struct CaptureSummaries: Codable, Equatable, Hashable, Sendable {
    var brief: String
    var concise: String
    var detailed: String
    var comprehensive: String

    init(brief: String, concise: String, detailed: String, comprehensive: String) {
        self.brief = brief
        self.concise = concise
        self.detailed = detailed
        self.comprehensive = comprehensive
    }

    init(repeating summary: String) {
        self.init(
            brief: summary,
            concise: summary,
            detailed: summary,
            comprehensive: summary
        )
    }

    subscript(level: SummaryDetailLevel) -> String {
        switch level {
        case .brief:
            return brief
        case .concise:
            return concise
        case .detailed:
            return detailed
        case .comprehensive:
            return comprehensive
        }
    }

    var allAreNonempty: Bool {
        SummaryDetailLevel.allCases.allSatisfy {
            !self[$0].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }
}

struct LibraryDocument: Identifiable, Hashable {
    var item: LibraryItem
    var summary: String?
    var summaryFileURL: URL?

    var id: LibraryItem.ID { item.id }

    var hasSummary: Bool {
        guard let summary else { return false }
        return !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

struct LibrarySnapshot {
    var documents: [LibraryDocument]
}

enum LibraryStoreError: LocalizedError {
    case missingSourceFile(String)
    case invalidSourceFile
    case sourceOutsideWorkspace
    case emptySummary
    case missingSummary

    var errorDescription: String? {
        switch self {
        case .missingSourceFile(let title):
            return "The source file for \"\(title)\" is missing."
        case .invalidSourceFile:
            return "This capture is not a valid Shared Library source."
        case .sourceOutsideWorkspace:
            return "Only captures in the capture folder can be processed."
        case .emptySummary:
            return "Add a summary before applying the changes."
        case .missingSummary:
            return "Process this capture before marking it reviewed."
        }
    }
}
