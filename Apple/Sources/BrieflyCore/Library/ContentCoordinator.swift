import Foundation

/// Coordinates user-facing library actions that span documents and channel
/// references, without exposing SQLite details to the store facade.
struct LibraryContentCoordinator {
    let documents: SQLiteDocumentRepository
    let topics: SQLiteTopicRepository
    let channelState: LibraryChannelStateRepository
    let projection: LibraryProjectionService

    func loadHighlights() throws -> String {
        (try? documents.get("system:highlights").texts[.source]) ?? ""
    }

    func addHighlight(entryID: String, variant: LibraryVariant, text: String) throws {
        let highlighted = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !highlighted.isEmpty else { throw LibraryError.emptyHighlight }
        guard highlighted.count <= 50_000 else { throw LibraryError.highlightTooLong }
        let document = try documents.get(entryID)
        let title = document.title.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
        let quote = highlighted.components(separatedBy: .newlines)
            .map { "> \($0)" }.joined(separator: "\n")
        let source = document.sourceURL.map { "\n\n[Open original](\($0))" } ?? ""
        let item = """
        ## \(title)

        \(quote)

        _\(variant.title) · \(Date().formatted(date: .abbreviated, time: .omitted))_\(source)
        """
        let existing = try loadHighlights()
        try saveHighlights(existing.isEmpty ? "# Highlights\n\n\(item)\n" : "\(existing)\n\n\(item)\n")
    }

    @discardableResult
    func removeHighlight(_ text: String) throws -> Bool {
        let target = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { return false }
        let existing = try loadHighlights()
        let parts = existing.components(separatedBy: "\n\n## ")
        guard parts.count > 1 else { return false }
        var kept = [parts[0]]
        var removed = false
        for part in parts.dropFirst() {
            let section = "## \(part)"
            let quote = section.components(separatedBy: .newlines)
                .filter { $0.hasPrefix("> ") }
                .map { String($0.dropFirst(2)) }
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if quote == target { removed = true } else { kept.append(section) }
        }
        guard removed else { return false }
        try saveHighlights(kept.count == 1 ? "" : kept.joined(separator: "\n\n") + "\n")
        return true
    }

    func topicDefinitions() throws -> [LibraryTopicDefinition] {
        try topics.all()
    }

    @discardableResult
    func replaceTopicDefinitions(
        _ definitions: [LibraryTopicDefinition]
    ) throws -> [LibraryTopicDefinition] {
        let current = try topicDefinitions()
        let currentIDs = Set(current.map(\.id))
        let usedIDs = Set(try projection.loadLibraryIndex().entries.flatMap(\.topicIDs))
        var ids = Set<String>()
        var titles = Set<String>()
        var normalized = [LibraryTopicDefinition]()
        for definition in definitions {
            let title = definition.title.trimmingCharacters(in: .whitespacesAndNewlines)
                .split(whereSeparator: \.isWhitespace).joined(separator: " ")
            guard !title.isEmpty, title.count <= 48 else {
                throw LibraryError.invalidTopicDefinitions(
                    "Every topic needs a title of 48 characters or fewer."
                )
            }
            guard titles.insert(title.lowercased()).inserted else {
                throw LibraryError.invalidTopicDefinitions("The topic “\(title)” is duplicated.")
            }
            var id = definition.id.trimmingCharacters(in: .whitespacesAndNewlines)
            if id.isEmpty {
                let base = slug(title)
                id = base
                var suffix = 2
                while ids.contains(id) || currentIDs.contains(id) {
                    id = "\(base)-\(suffix)"
                    suffix += 1
                }
            }
            guard id.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$"#, options: .regularExpression) != nil,
                  ids.insert(id).inserted else {
                throw LibraryError.invalidTopicDefinitions(
                    "Topic IDs must be unique and contain only letters, numbers, dots, dashes, or underscores."
                )
            }
            normalized.append(LibraryTopicDefinition(id: id, title: title))
        }
        if let used = usedIDs.first(where: { currentIDs.contains($0) && !ids.contains($0) }) {
            throw LibraryError.invalidTopicDefinitions(
                "The topic “\(used)” is still used by library items. Rename it instead."
            )
        }
        try topics.replace(normalized)
        return normalized
    }

    func deleteTopicDefinition(id: String) throws {
        let topicID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !topicID.isEmpty else { throw LibraryError.invalidTopic }
        let commits = try documents.all(includeDeleted: true).compactMap { document -> SQLiteDocumentCommit? in
            guard document.topicIDs.contains(topicID) else { return nil }
            return SQLiteDocumentCommit(
                id: document.id,
                baseRevision: document.revision,
                topicIDs: document.topicIDs.filter { $0 != topicID }
            )
        }
        _ = try documents.batch(commits)
        try topics.replace(
            try topics.all().filter { $0.id != topicID }
        )
    }

    func moveToTrash(entryID: String) throws {
        let document = try documents.get(entryID)
        _ = try documents.commit(SQLiteDocumentCommit(
            id: entryID,
            baseRevision: document.revision,
            deleted: true
        ))
        var state = channelState.read()
        var removedKeys = Set<String>()
        for source in Array(state.sources.keys) {
            guard var current = state.sources[source] else { continue }
            let removed = current.items.filter { $0.entryID == entryID }
            guard !removed.isEmpty else { continue }
            removedKeys.formUnion(removed.map { voiceBriefItemKey(source, $0.id) })
            let ids = Set(removed.map(\.id))
            current.items.removeAll { ids.contains($0.id) }
            current.seen.removeAll { ids.contains($0) }
            state.sources[source] = current
        }
        if !removedKeys.isEmpty {
            for id in Array(state.voiceBriefs.keys) {
                state.voiceBriefs[id]?.consumed.removeAll { removedKeys.contains($0) }
            }
            try channelState.write(state)
        }
    }

    private func saveHighlights(_ text: String) throws {
        if let document = try? documents.get("system:highlights", includeDeleted: true) {
            _ = try documents.commit(SQLiteDocumentCommit(
                id: document.id,
                baseRevision: document.revision,
                texts: [.source: text],
                deleted: false
            ))
        } else if !text.isEmpty {
            _ = try documents.create(
                title: "Highlights",
                body: text,
                type: "highlights",
                id: "system:highlights",
                captureID: "HIGHLIGHTS"
            )
        }
    }
}
