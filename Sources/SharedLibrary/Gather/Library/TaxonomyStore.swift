import Foundation

enum TaxonomyStoreError: LocalizedError, Equatable {
    case missingAreas
    case duplicateAreaID(String)
    case duplicateTopicID(String)
    case missingTitle(String)
    case unknownArea(topicID: String, areaID: String)

    var errorDescription: String? {
        switch self {
        case .missingAreas:
            return "The taxonomy needs at least one area."
        case .duplicateAreaID(let id):
            return "The area id \"\(id)\" is used more than once."
        case .duplicateTopicID(let id):
            return "The topic id \"\(id)\" is used more than once."
        case .missingTitle(let id):
            return "\"\(id)\" needs a title."
        case .unknownArea(let topicID, let areaID):
            return "The topic \"\(topicID)\" references the unknown area \"\(areaID)\"."
        }
    }
}

struct TaxonomyStore {
    let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func ensureTaxonomy(at url: URL) throws {
        guard fileManager.fileExists(atPath: url.path) else {
            try save(Self.defaultTaxonomy, to: url)
            return
        }

        let text = try String(contentsOf: url, encoding: .utf8)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "[]" else {
            try save(Self.defaultTaxonomy, to: url)
            return
        }

        if Self.usesSectionedFormat(text) {
            // Existing YAML is user-owned. Validation happens when the library or
            // editor loads it so a temporary syntax problem cannot prevent launch.
            return
        }

        let legacyTopics = Self.parseList(text)
        var migrated = Self.defaultTaxonomy
        var seenTopicIDs = Set(migrated.topics.map(\.id))
        for entry in legacyTopics {
            guard let id = entry["id"]?.trimmedNonEmpty,
                  seenTopicIDs.insert(id).inserted else {
                continue
            }
            let requestedAreaID = entry["area"]?.trimmedNonEmpty
            let areaID = migrated.areas.contains(where: { $0.id == requestedAreaID })
                ? requestedAreaID!
                : "work"
            migrated.topics.append(TopicDefinition(
                id: id,
                areaID: areaID,
                title: entry["title"]?.trimmedNonEmpty ?? Self.titleized(id),
                description: entry["description"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            ))
        }
        try save(migrated, to: url)
    }

    func load(from url: URL) throws -> KnowledgeTaxonomy {
        guard fileManager.fileExists(atPath: url.path) else {
            return Self.defaultTaxonomy
        }
        let text = try String(contentsOf: url, encoding: .utf8)
        if Self.usesSectionedFormat(text) {
            return try parseSectionedTaxonomy(text)
        }

        // Reading a legacy file remains safe even before workspace migration runs.
        let entries = Self.parseList(text)
        let topics = entries.compactMap { entry -> TopicDefinition? in
            guard let id = entry["id"]?.trimmedNonEmpty else { return nil }
            return TopicDefinition(
                id: id,
                areaID: entry["area"]?.trimmedNonEmpty ?? "work",
                title: entry["title"]?.trimmedNonEmpty ?? Self.titleized(id),
                description: entry["description"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            )
        }
        let taxonomy = KnowledgeTaxonomy(areas: Self.defaultTaxonomy.areas, topics: topics)
        try validate(taxonomy)
        return taxonomy
    }

    func save(_ taxonomy: KnowledgeTaxonomy, to url: URL) throws {
        try validate(taxonomy)
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try serialized(taxonomy).write(to: url, atomically: true, encoding: .utf8)
    }

    @discardableResult
    func ensureTopic(named proposedName: String, at url: URL) throws -> TopicDefinition {
        let name = proposedName
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"' .,-"))
        guard !name.isEmpty else { throw TaxonomyStoreError.missingTitle("new-topic") }

        var taxonomy = try load(from: url)
        if let existing = taxonomy.topics.first(where: {
            $0.title.compare(
                name,
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]
            ) == .orderedSame || $0.id.compare(name, options: .caseInsensitive) == .orderedSame
        }) {
            return existing
        }

        let baseID = Self.slug(name, fallback: "topic")
        let usedIDs = Set(taxonomy.topics.map(\.id))
        var topicID = baseID
        var suffix = 2
        while usedIDs.contains(topicID) {
            topicID = "\(baseID)-\(suffix)"
            suffix += 1
        }
        let areaID = taxonomy.areas.first(where: { $0.id == "learning" })?.id
            ?? taxonomy.areas.first(where: { $0.id == "work" })?.id
            ?? taxonomy.areas.first!.id
        let topic = TopicDefinition(
            id: topicID,
            areaID: areaID,
            title: String(name.prefix(64)),
            description: ""
        )
        taxonomy.topics.append(topic)
        try save(taxonomy, to: url)
        return topic
    }

    func validate(_ taxonomy: KnowledgeTaxonomy) throws {
        guard !taxonomy.areas.isEmpty else { throw TaxonomyStoreError.missingAreas }

        var areaIDs = Set<String>()
        for area in taxonomy.areas {
            guard !area.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw TaxonomyStoreError.missingTitle(area.id)
            }
            guard areaIDs.insert(area.id).inserted else {
                throw TaxonomyStoreError.duplicateAreaID(area.id)
            }
        }

        var topicIDs = Set<String>()
        for topic in taxonomy.topics {
            guard !topic.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw TaxonomyStoreError.missingTitle(topic.id)
            }
            guard topicIDs.insert(topic.id).inserted else {
                throw TaxonomyStoreError.duplicateTopicID(topic.id)
            }
            guard areaIDs.contains(topic.areaID) else {
                throw TaxonomyStoreError.unknownArea(topicID: topic.id, areaID: topic.areaID)
            }
        }
    }

    func serialized(_ taxonomy: KnowledgeTaxonomy) -> String {
        var lines = ["version: 1", "", "areas:"]
        for area in taxonomy.areas {
            lines.append("  - id: \(MarkdownMetadata.yamlString(area.id))")
            lines.append("    title: \(MarkdownMetadata.yamlString(area.title))")
            lines.append("    description: \(MarkdownMetadata.yamlString(area.description))")
        }

        lines.append("")
        lines.append("topics:")
        for topic in taxonomy.topics {
            lines.append("  - id: \(MarkdownMetadata.yamlString(topic.id))")
            lines.append("    area: \(MarkdownMetadata.yamlString(topic.areaID))")
            lines.append("    title: \(MarkdownMetadata.yamlString(topic.title))")
            lines.append("    description: \(MarkdownMetadata.yamlString(topic.description))")
        }
        lines.append("")
        return lines.joined(separator: "\n")
    }

    private func parseSectionedTaxonomy(_ text: String) throws -> KnowledgeTaxonomy {
        enum Section {
            case areas
            case topics
        }

        var section: Section?
        var areas: [[String: String]] = []
        var topics: [[String: String]] = []
        var current: [String: String] = [:]

        func finishCurrent() {
            guard !current.isEmpty, let section else { return }
            switch section {
            case .areas: areas.append(current)
            case .topics: topics.append(current)
            }
            current = [:]
        }

        for rawLine in text.components(separatedBy: .newlines) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }

            if !rawLine.hasPrefix(" ") {
                if trimmed == "areas:" {
                    finishCurrent()
                    section = .areas
                } else if trimmed == "topics:" {
                    finishCurrent()
                    section = .topics
                }
                continue
            }

            guard section != nil else { continue }
            if trimmed.hasPrefix("- ") {
                finishCurrent()
                Self.parseKeyValue(String(trimmed.dropFirst(2)), into: &current)
            } else {
                Self.parseKeyValue(trimmed, into: &current)
            }
        }
        finishCurrent()

        let parsedAreas = areas.compactMap { entry -> AreaDefinition? in
            guard let id = entry["id"]?.trimmedNonEmpty else { return nil }
            return AreaDefinition(
                id: id,
                title: entry["title"]?.trimmedNonEmpty ?? Self.titleized(id),
                description: entry["description"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            )
        }
        let fallbackAreaID = parsedAreas.first(where: { $0.id == "work" })?.id
            ?? parsedAreas.first?.id
            ?? "work"
        let parsedTopics = topics.compactMap { entry -> TopicDefinition? in
            guard let id = entry["id"]?.trimmedNonEmpty else { return nil }
            return TopicDefinition(
                id: id,
                areaID: entry["area"]?.trimmedNonEmpty ?? fallbackAreaID,
                title: entry["title"]?.trimmedNonEmpty ?? Self.titleized(id),
                description: entry["description"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            )
        }

        let taxonomy = KnowledgeTaxonomy(areas: parsedAreas, topics: parsedTopics)
        try validate(taxonomy)
        return taxonomy
    }

    private static func usesSectionedFormat(_ text: String) -> Bool {
        let topLevelKeys = Set(text.components(separatedBy: .newlines).compactMap { line -> String? in
            guard !line.hasPrefix(" ") else { return nil }
            let value = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, !value.hasPrefix("#") else { return nil }
            return value
        })
        return topLevelKeys.contains("areas:") && topLevelKeys.contains("topics:")
    }

    private static func parseList(_ text: String) -> [[String: String]] {
        var entries: [[String: String]] = []
        var current: [String: String] = [:]

        func finishCurrent() {
            guard !current.isEmpty else { return }
            entries.append(current)
            current = [:]
        }

        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed != "[]", !trimmed.hasPrefix("#") else { continue }
            if trimmed.hasPrefix("- ") {
                finishCurrent()
                parseKeyValue(String(trimmed.dropFirst(2)), into: &current)
            } else {
                parseKeyValue(trimmed, into: &current)
            }
        }
        finishCurrent()
        return entries
    }

    private static func parseKeyValue(_ text: String, into entry: inout [String: String]) {
        guard let separator = text.firstIndex(of: ":") else { return }
        let key = String(text[..<separator]).trimmingCharacters(in: .whitespacesAndNewlines)
        let rawValue = String(text[text.index(after: separator)...]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        entry[key] = MarkdownMetadata.parseScalar(rawValue)
    }

    static func titleized(_ value: String) -> String {
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

    static func slug(_ value: String, fallback: String) -> String {
        let folded = value
            .folding(options: [.diacriticInsensitive, .widthInsensitive], locale: .current)
            .lowercased()
        let parts = folded.components(separatedBy: CharacterSet.alphanumerics.inverted)
        let slug = parts.filter { !$0.isEmpty }.joined(separator: "-")
        return slug.isEmpty ? fallback : slug
    }

    static let defaultTaxonomy = KnowledgeTaxonomy(
        areas: [
            AreaDefinition(
                id: "personal",
                title: "Personal",
                description: "Private life, wellbeing, relationships, finances, and home."
            ),
            AreaDefinition(
                id: "work",
                title: "Work",
                description: "Products, business, professional responsibilities, and career."
            ),
            AreaDefinition(
                id: "learning",
                title: "Learning",
                description: "Research, skills, books, media, tools, and working methods."
            )
        ],
        topics: [
            TopicDefinition(id: "self-improvement", areaID: "personal", title: "Self-improvement", description: "Habits, mindset, reflection, productivity, and personal growth."),
            TopicDefinition(id: "health-wellbeing", areaID: "personal", title: "Health & wellbeing", description: "Physical health, exercise, nutrition, sleep, and mental wellbeing."),
            TopicDefinition(id: "relationships", areaID: "personal", title: "Relationships", description: "Family, friendships, communication, and social life."),
            TopicDefinition(id: "personal-finance", areaID: "personal", title: "Personal finance", description: "Saving, spending, investing, taxes, and financial planning."),
            TopicDefinition(id: "home-life", areaID: "personal", title: "Home & life", description: "Household responsibilities, purchases, routines, and life administration."),
            TopicDefinition(id: "product-strategy", areaID: "work", title: "Product & strategy", description: "Product direction, customer needs, positioning, design decisions, and business strategy."),
            TopicDefinition(id: "building-engineering", areaID: "work", title: "Building & engineering", description: "Software development, architecture, implementation, technical systems, and shipping."),
            TopicDefinition(id: "business-operations", areaID: "work", title: "Business & operations", description: "Growth, marketing, sales, distribution, processes, finance, legal matters, and running the business."),
            TopicDefinition(id: "career", areaID: "work", title: "Career", description: "Professional development, opportunities, networking, reputation, and career decisions."),
            TopicDefinition(id: "research", areaID: "learning", title: "Research", description: "Investigations, source material, comparisons, and evidence gathering."),
            TopicDefinition(id: "skills-courses", areaID: "learning", title: "Skills & courses", description: "Deliberate learning and practice of a specific capability."),
            TopicDefinition(id: "books-media", areaID: "learning", title: "Books & media", description: "Books, articles, podcasts, videos, and the ideas they contain."),
            TopicDefinition(id: "tools-workflows", areaID: "learning", title: "Tools & workflows", description: "Software, automation, knowledge management, and working methods.")
        ]
    )
}

private extension String {
    var trimmedNonEmpty: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
