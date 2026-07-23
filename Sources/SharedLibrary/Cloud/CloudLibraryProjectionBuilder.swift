import Foundation

struct CloudLibraryProjectionBuilder {
    private let knowledgeStore: KnowledgeStore
    private let sharingStore: SharingStore
    private let peopleDirectoryStore: PeopleDirectoryStore
    private let fileManager: FileManager

    init(
        knowledgeStore: KnowledgeStore = KnowledgeStore(),
        sharingStore: SharingStore = SharingStore(),
        peopleDirectoryStore: PeopleDirectoryStore = PeopleDirectoryStore(),
        fileManager: FileManager = .default
    ) {
        self.knowledgeStore = knowledgeStore
        self.sharingStore = sharingStore
        self.peopleDirectoryStore = peopleDirectoryStore
        self.fileManager = fileManager
    }

    func build(
        privateWorkspaceURL: URL,
        sharedWorkspaceURL: URL,
        currentGitHubUserID: String?,
        generatedAt: Date = Date()
    ) throws -> CloudLibraryProjection {
        let personalSnapshot = try knowledgeStore.snapshot(workspaceRootURL: privateWorkspaceURL)
        let personalTopicNames = topicNames(in: personalSnapshot)
        var entries = personalSnapshot.records.compactMap { record in
            makeEntry(
                record: record,
                workspaceURL: privateWorkspaceURL,
                id: "personal:\(record.captureID ?? record.fileURL.lastPathComponent)",
                origin: .personal,
                topicNamesByID: personalTopicNames,
                sharedBy: nil
            )
        }

        if let currentGitHubUserID,
           !currentGitHubUserID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            entries.append(contentsOf: try sharedEntries(
                sharedWorkspaceURL: sharedWorkspaceURL,
                currentGitHubUserID: currentGitHubUserID
            ))
        }

        entries.sort { lhs, rhs in
            let lhsDate = lhs.createdAt ?? lhs.updatedAt ?? .distantPast
            let rhsDate = rhs.createdAt ?? rhs.updatedAt ?? .distantPast
            if lhsDate == rhsDate {
                return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
            }
            return lhsDate > rhsDate
        }
        return CloudLibraryProjection(generatedAt: generatedAt, entries: entries)
    }

    private func sharedEntries(
        sharedWorkspaceURL: URL,
        currentGitHubUserID: String
    ) throws -> [CloudLibraryEntryPayload] {
        let people = try peopleDirectoryStore.people(sharedWorkspaceURL: sharedWorkspaceURL)
        guard let currentPerson = people.first(where: { $0.githubID == currentGitHubUserID }) else {
            return []
        }
        let peopleByID = Dictionary(uniqueKeysWithValues: people.map { ($0.githubID, $0) })
        let references = try sharingStore.references(
            for: currentPerson,
            direction: .sharedWith,
            sharedWorkspaceURL: sharedWorkspaceURL
        )
        guard !references.isEmpty else { return [] }

        let sharedSnapshot = try knowledgeStore.snapshot(workspaceRootURL: sharedWorkspaceURL)
        let topicNamesByID = topicNames(in: sharedSnapshot)
        let recordsByPath = Dictionary(
            uniqueKeysWithValues: sharedSnapshot.records.map {
                ($0.fileURL.standardizedFileURL.path, $0)
            }
        )

        return references.compactMap { reference in
            guard let contentURL = try? sharingStore.sharedContentURL(
                for: reference,
                sharedWorkspaceURL: sharedWorkspaceURL
            ),
            let record = recordsByPath[contentURL.standardizedFileURL.path] else {
                return nil
            }
            return makeEntry(
                record: record,
                workspaceURL: sharedWorkspaceURL,
                id: "shared:\(reference.id)",
                origin: .shared,
                topicNamesByID: topicNamesByID,
                sharedBy: peopleByID[reference.sharedByID]
            )
        }
    }

    private func makeEntry(
        record: KnowledgeRecord,
        workspaceURL: URL,
        id: String,
        origin: CloudLibraryOrigin,
        topicNamesByID: [String: String],
        sharedBy: SharedPerson?
    ) -> CloudLibraryEntryPayload? {
        guard let sourceText = sourceBody(at: record.fileURL) else { return nil }
        var texts = summaryTexts(for: record.fileURL, workspaceURL: workspaceURL)
        if !sourceText.isEmpty {
            texts.append(CloudLibraryTextPayload(variant: .source, text: sourceText))
        }
        texts.sort {
            let lhs = CloudLibraryVariant.allCases.firstIndex(of: $0.variant) ?? .max
            let rhs = CloudLibraryVariant.allCases.firstIndex(of: $1.variant) ?? .max
            return lhs < rhs
        }

        return CloudLibraryEntryPayload(
            id: id,
            captureID: record.captureID,
            title: record.title,
            excerpt: record.excerpt,
            topicIDs: record.topicIDs,
            topicNames: record.topicIDs.map { topicNamesByID[$0] ?? TaxonomyStore.titleized($0) },
            tags: record.tags,
            sourceURL: record.sourceURL,
            createdAt: record.createdAt,
            updatedAt: record.updatedAt,
            reviewedAt: record.reviewedAt,
            origin: origin,
            sharedByGitHubID: sharedBy?.githubID,
            sharedByDisplayName: sharedBy?.displayName,
            texts: texts
        )
    }

    private func sourceBody(at url: URL) -> String? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return MarkdownMetadata.parse(text).body.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func summaryTexts(
        for sourceURL: URL,
        workspaceURL: URL
    ) -> [CloudLibraryTextPayload] {
        let summariesFolder = workspaceURL.appendingPathComponent(
            "library/summaries",
            isDirectory: true
        )
        return SummaryDetailLevel.allCases.compactMap { level in
            let levelURL = summariesFolder
                .appendingPathComponent(level.storageDirectoryName, isDirectory: true)
                .appendingPathComponent(sourceURL.lastPathComponent)
            let fallbackURL = summariesFolder.appendingPathComponent(sourceURL.lastPathComponent)
            let candidates = level == .concise ? [levelURL, fallbackURL] : [levelURL]
            guard let text = candidates.lazy.compactMap({ try? String(contentsOf: $0, encoding: .utf8) })
                .map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) })
                .first(where: { !$0.isEmpty }) else {
                return nil
            }
            return CloudLibraryTextPayload(
                variant: CloudLibraryVariant(rawValue: level.storageDirectoryName) ?? .concise,
                text: text
            )
        }
    }

    private func topicNames(in snapshot: KnowledgeSnapshot) -> [String: String] {
        Dictionary(uniqueKeysWithValues: snapshot.topics.map { ($0.id, $0.title) })
    }
}
