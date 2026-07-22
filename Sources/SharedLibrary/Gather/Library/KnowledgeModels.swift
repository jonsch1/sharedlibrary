import Foundation

struct AreaDefinition: Identifiable, Hashable {
    var id: String
    var title: String
    var description: String
}

struct TopicDefinition: Identifiable, Hashable {
    var id: String
    var areaID: String
    var title: String
    var description: String
}

struct KnowledgeTaxonomy: Equatable {
    var areas: [AreaDefinition]
    var topics: [TopicDefinition]

    static let empty = KnowledgeTaxonomy(areas: [], topics: [])
}

struct KnowledgeRecord: Identifiable, Hashable {
    var id: String
    var captureID: String?
    var typeID: String
    var title: String
    var excerpt: String
    var topicIDs: [String]
    var tags: [String]
    var sourceURL: String?
    var fileURL: URL
    var createdAt: Date?
    var updatedAt: Date?
    var reviewedAt: Date?

    var sortDate: Date {
        createdAt ?? updatedAt ?? .distantPast
    }

    var isReviewed: Bool {
        reviewedAt != nil
    }

}

struct KnowledgeSnapshot {
    var areas: [AreaDefinition]
    var topics: [TopicDefinition]
    var records: [KnowledgeRecord]

    static let empty = KnowledgeSnapshot(areas: [], topics: [], records: [])
}

struct MarkdownMetadata {
    var fields: [String: [String]]
    var body: String
    var hasFrontmatter: Bool

    func firstValue(for key: String) -> String? {
        fields[key]?.first
    }

    func values(for key: String) -> [String] {
        fields[key] ?? []
    }

    static func parse(_ text: String) -> MarkdownMetadata {
        guard text.hasPrefix("---\n"),
              let endRange = text.dropFirst(4).range(of: "\n---\n") else {
            return MarkdownMetadata(fields: [:], body: text, hasFrontmatter: false)
        }

        let metadataStart = text.index(text.startIndex, offsetBy: 4)
        let metadata = String(text[metadataStart..<endRange.lowerBound])
        var body = String(text[endRange.upperBound...])
        if body.hasPrefix("\r\n") {
            body.removeFirst(2)
        } else if body.hasPrefix("\n") {
            body.removeFirst()
        }

        return MarkdownMetadata(
            fields: parseFields(metadata),
            body: body,
            hasFrontmatter: true
        )
    }

    static func parseFields(_ metadata: String) -> [String: [String]] {
        var fields: [String: [String]] = [:]
        var currentKey: String?
        var currentValue = ""
        var listValues: [String] = []

        func finishCurrent() {
            guard let key = currentKey, !key.isEmpty else { return }
            if listValues.isEmpty {
                fields[key] = parseValues(currentValue)
            } else {
                fields[key] = listValues.map(parseScalar)
            }
        }

        for line in metadata.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }

            if trimmed.hasPrefix("- "), currentKey != nil {
                listValues.append(String(trimmed.dropFirst(2)))
                continue
            }

            guard let separator = line.firstIndex(of: ":") else { continue }
            finishCurrent()
            currentKey = String(line[..<separator]).trimmingCharacters(in: .whitespacesAndNewlines)
            currentValue = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            listValues = []
        }

        finishCurrent()
        return fields
    }

    static func parseValues(_ value: String) -> [String] {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "[]" else { return [] }

        if trimmed.hasPrefix("["),
           trimmed.hasSuffix("]"),
           let data = trimmed.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([String].self, from: data) {
            return decoded
        }

        return [parseScalar(trimmed)]
    }

    static func parseScalar(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("\""),
              let data = trimmed.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(String.self, from: data) else {
            return trimmed
        }

        return decoded
    }

    static func yamlString(_ value: String) -> String {
        let data = try? JSONEncoder().encode(value)
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
    }
}

final class KnowledgeStore {
    private let fileManager: FileManager
    private let isoFormatter: ISO8601DateFormatter

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    }

    func snapshot(workspaceRootURL: URL) throws -> KnowledgeSnapshot {
        let gatherFolder = workspaceRootURL.appendingPathComponent("gather", isDirectory: true)
        let taxonomyURL = workspaceRootURL.appendingPathComponent("topics").appendingPathExtension("md")

        let records = readSources(in: gatherFolder).sorted { lhs, rhs in
            if lhs.sortDate == rhs.sortDate {
                return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
            }
            return lhs.sortDate > rhs.sortDate
        }

        let taxonomy = completedTaxonomy(
            try TaxonomyStore(fileManager: fileManager).load(from: taxonomyURL),
            records: records
        )
        return KnowledgeSnapshot(
            areas: taxonomy.areas,
            topics: taxonomy.topics,
            records: records
        )
    }

    private func readSources(in folder: URL) -> [KnowledgeRecord] {
        readMarkdownURLs(in: folder)
            .filter { url in
                !["TAGS.md", "AGENTS.md"].contains { excluded in
                    url.lastPathComponent.localizedCaseInsensitiveCompare(excluded) == .orderedSame
                }
            }
            .compactMap { record(at: $0, typeID: "source", inheritedTopics: []) }
    }

    private func record(
        at url: URL,
        typeID: String,
        inheritedTopics: [String]
    ) -> KnowledgeRecord? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let metadata = MarkdownMetadata.parse(text)
        if typeID == "source",
           metadata.firstValue(for: "type")?.localizedCaseInsensitiveCompare("image") == .orderedSame {
            return nil
        }
        let values = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
        let topics = metadata.values(for: "topics").isEmpty ? inheritedTopics : metadata.values(for: "topics")
        let title = Self.title(
            metadata: metadata,
            fallbackBody: metadata.body,
            fallback: url.deletingPathExtension().lastPathComponent
        )

        return KnowledgeRecord(
            id: "\(typeID):\(url.standardizedFileURL.path)",
            captureID: metadata.firstValue(for: "id"),
            typeID: typeID,
            title: title,
            excerpt: Self.excerpt(from: metadata.body),
            topicIDs: Self.normalizedValues(topics),
            tags: Self.normalizedValues(metadata.values(for: "tags")),
            sourceURL: metadata.firstValue(for: "source_url"),
            fileURL: url.standardizedFileURL,
            createdAt: parseDate(metadata.firstValue(for: "created_at")) ?? values?.creationDate,
            updatedAt: parseDate(metadata.firstValue(for: "updated_at")) ?? values?.contentModificationDate,
            reviewedAt: parseDate(metadata.firstValue(for: "reviewed_at"))
        )
    }

    private func readMarkdownURLs(in folder: URL) -> [URL] {
        let urls = (try? fileManager.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey, .creationDateKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        return urls
            .filter { $0.pathExtension.localizedCaseInsensitiveCompare("md") == .orderedSame }
            .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    private func completedTaxonomy(
        _ taxonomy: KnowledgeTaxonomy,
        records: [KnowledgeRecord]
    ) -> KnowledgeTaxonomy {
        var completed = taxonomy
        var seen = Set(taxonomy.topics.map(\.id))
        let referenced = Set(records.flatMap(\.topicIDs))
        let fallbackAreaID = taxonomy.areas.first(where: { $0.id == "work" })?.id
            ?? taxonomy.areas.first?.id
            ?? "work"

        if completed.areas.isEmpty {
            completed.areas.append(AreaDefinition(
                id: fallbackAreaID,
                title: Self.titleized(fallbackAreaID),
                description: ""
            ))
        }

        for topicID in referenced.sorted() where !seen.contains(topicID) {
            completed.topics.append(TopicDefinition(
                id: topicID,
                areaID: fallbackAreaID,
                title: Self.titleized(topicID),
                description: ""
            ))
            seen.insert(topicID)
        }

        return completed
    }

    private func parseDate(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        if let date = isoFormatter.date(from: value) {
            return date
        }

        let fallback = ISO8601DateFormatter()
        fallback.formatOptions = [.withInternetDateTime]
        return fallback.date(from: value)
    }

    private static func title(
        metadata: MarkdownMetadata,
        fallbackBody: String,
        fallback: String
    ) -> String {
        if let title = metadata.firstValue(for: "title")?.trimmingCharacters(in: .whitespacesAndNewlines),
           !title.isEmpty {
            return title
        }

        for line in fallbackBody.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if trimmed.hasPrefix("# ") {
                let heading = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespacesAndNewlines)
                if !heading.isEmpty { return heading }
            }
            return truncated(trimmed, limit: 90)
        }

        return Self.titleized(fallback)
    }

    private static func excerpt(from body: String) -> String {
        let text = body
            .components(separatedBy: .newlines)
            .map { line in
                line
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: #"^#{1,6}\s+"#, with: "", options: .regularExpression)
            }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return truncated(text, limit: 180)
    }

    private static func truncated(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        let index = text.index(text.startIndex, offsetBy: max(0, limit - 1))
        return String(text[..<index]).trimmingCharacters(in: .whitespacesAndNewlines) + "..."
    }

    private static func titleized(_ value: String) -> String {
        value
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .split(separator: " ")
            .map { word in
                guard let first = word.first else { return "" }
                return String(first).uppercased() + String(word.dropFirst())
            }
            .joined(separator: " ")
    }

    private static func normalizedValues(_ values: [String]) -> [String] {
        Array(Set(values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })).sorted()
    }
}
