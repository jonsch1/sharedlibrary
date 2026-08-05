import Foundation

/// Coordinates the persistence-backed processing queue and applies validated AI
/// output. Process execution itself remains in `Processing.swift`.
struct LibraryProcessingCoordinator {
    let repositories: SQLiteLibraryRepositories

    func enqueue(entryID: String, selectWhenFinished: Bool) throws {
        _ = try repositories.documents.get(entryID)
        try repositories.processing.enqueue(
            documentID: entryID,
            selectWhenFinished: selectWhenFinished
        )
    }

    func claimNext() throws -> SQLiteProcessingJob? {
        try repositories.processing.claimNext()
    }

    func complete(entryID: String) throws {
        try repositories.processing.complete(documentID: entryID)
    }

    func fail(entryID: String, error: String) throws {
        try repositories.processing.fail(documentID: entryID, error: error)
    }

    func prompt(entryID: String, template: String) throws -> String {
        let normalized = template.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.contains("{{topics}}"), normalized.contains("{{source}}") else {
            throw LibraryError.invalidProcessingPrompt
        }
        let englishInstruction =
            "Always write both summaries in English, regardless of the language of the source."
        let enforcedTemplate = normalized.contains(englishInstruction)
            ? normalized
            : englishInstruction + "\n" + normalized
        let document = try repositories.documents.get(entryID)
        var source: [String: Any] = [
            "title": document.title,
            "source_text": document.texts[.source] ?? ""
        ]
        if let sourceURL = document.sourceURL { source["source_url"] = sourceURL }
        let topics = try repositories.documents.topics().map(\.title).sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
        return enforcedTemplate
            .replacingOccurrences(of: "{{topics}}", with: try json(topics))
            .replacingOccurrences(of: "{{source}}", with: try json(source))
    }

    @discardableResult
    func apply(entryID: String, suggestion: ProcessingSuggestion) throws -> String {
        let document = try repositories.documents.get(entryID)
        let topicID = try ensureTopic(named: suggestion.topicName)
        let requestedBase = slug(suggestion.shortFilename)
        var texts = [LibraryVariant: String]()
        for variant in [LibraryVariant.concise, .detailed] {
            guard let summary = suggestion.summaries.text(for: variant)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !summary.isEmpty else {
                throw LibraryError.invalidProcessingOutput
            }
            texts[variant] = summary
        }
        _ = try repositories.documents.commit(SQLiteDocumentCommit(
            id: entryID,
            baseRevision: document.revision,
            title: firstHeading(document.texts[.source] ?? "") ??
                requestedBase.replacingOccurrences(of: "-", with: " ").capitalized,
            topicIDs: [topicID],
            texts: texts
        ))
        return entryID
    }

    private func ensureTopic(named value: String) throws -> String {
        let title = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        guard !title.isEmpty, title.count <= 48 else { throw LibraryError.invalidTopic }
        var topics = try repositories.documents.topics()
        if let existing = topics.first(where: {
            $0.title.localizedCaseInsensitiveCompare(title) == .orderedSame
        }) { return existing.id }
        let base = slug(title)
        var id = base
        var suffix = 2
        while topics.contains(where: { $0.id == id }) {
            id = "\(base)-\(suffix)"
            suffix += 1
        }
        topics.append(LibraryTopicDefinition(id: id, title: title))
        try repositories.documents.replaceTopics(topics)
        return id
    }
}
