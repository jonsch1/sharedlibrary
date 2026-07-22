import XCTest
@testable import SharedLibrary

final class ProcessingStoreTests: XCTestCase {
    func testSummaryDetailLevelsAreProgressiveAndHaveDistinctPrompts() {
        XCTAssertEqual(
            SummaryDetailLevel.allCases,
            [.brief, .concise, .detailed, .comprehensive]
        )
        XCTAssertEqual(SummaryDetailLevel.allCases.map(\.rawValue), [0, 1, 2, 3])
        XCTAssertEqual(Set(SummaryDetailLevel.allCases.map(\.promptRequirement)).count, 4)
        XCTAssertEqual(SummaryDetailLevel.brief.title, "Brief")
        XCTAssertEqual(SummaryDetailLevel.comprehensive.title, "Comprehensive")
    }

    func testGenerationOrderRunsFromComprehensiveToBrief() {
        XCTAssertEqual(
            SummaryDetailLevel.generationOrder,
            [.comprehensive, .detailed, .concise, .brief]
        )
    }

    func testSummaryGenerationPinsTerraAtMediumReasoning() {
        XCTAssertEqual(ProcessingService.summaryModel, "gpt-5.6-terra")
        XCTAssertEqual(ProcessingService.summaryReasoningEffort, "medium")
    }

    private func makeWorkspace() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("processing-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("gather/summaries", isDirectory: true),
            withIntermediateDirectories: true
        )
        return root
    }

    private func writeSource(named filename: String, in root: URL) throws -> URL {
        let url = root.appendingPathComponent("gather/\(filename)")
        try """
        ---
        id: "source-1"
        type: "link"
        title: "A Useful Source"
        created_at: "2026-07-09T10:00:00.000Z"
        updated_at: "2026-07-09T10:00:00.000Z"
        tags:
          - "reference"
        topics: []
        source_url: "https://example.com/source"
        ---

        Body stays exactly where it belongs.
        """.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func testProcessingRenamesSourceWritesSummaryAndUpdatesTopics() throws {
        let root = try makeWorkspace()
        let sourceURL = try writeSource(named: "260709-1.md", in: root)
        let date = ISO8601DateFormatter().date(from: "2026-07-09T12:00:00Z")!

        let processedURL = try LibraryStore().processSource(
            at: sourceURL,
            workspaceRootURL: root,
            suggestedFilename: "Useful Source Draft.md",
            summary: "A short, corrected summary.",
            topicIDs: ["research", "voice", "research"],
            date: date
        )

        XCTAssertEqual(processedURL.lastPathComponent, "useful-source-draft.md")
        XCTAssertFalse(FileManager.default.fileExists(atPath: sourceURL.path))

        let processedText = try String(contentsOf: processedURL, encoding: .utf8)
        let metadata = MarkdownMetadata.parse(processedText)
        XCTAssertEqual(metadata.firstValue(for: "title"), "A Useful Source")
        XCTAssertEqual(metadata.values(for: "tags"), ["reference"])
        XCTAssertEqual(metadata.values(for: "topics"), ["research", "voice"])
        XCTAssertNil(metadata.firstValue(for: "reviewed_at"))
        XCTAssertTrue(metadata.body.contains("Body stays exactly where it belongs."))

        let summaryURL = root.appendingPathComponent("gather/summaries/useful-source-draft.md")
        XCTAssertEqual(
            try String(contentsOf: summaryURL, encoding: .utf8),
            "A short, corrected summary.\n"
        )
        for level in SummaryDetailLevel.allCases {
            let levelURL = root
                .appendingPathComponent("gather/summaries/\(level.storageDirectoryName)", isDirectory: true)
                .appendingPathComponent("useful-source-draft.md")
            XCTAssertEqual(
                try String(contentsOf: levelURL, encoding: .utf8),
                "A short, corrected summary.\n"
            )
        }
    }

    func testAutomaticProcessingWritesFourSummariesAndTopicMetadata() throws {
        let root = try makeWorkspace()
        let sourceURL = try writeSource(named: "260709-1.md", in: root)
        let summaries = CaptureSummaries(
            brief: "Brief version.",
            concise: "Concise version.",
            detailed: "Detailed version.",
            comprehensive: "Comprehensive version."
        )
        let processedURL = try LibraryStore().processSource(
            at: sourceURL,
            workspaceRootURL: root,
            suggestedFilename: "AI Systems",
            summaries: summaries,
            topicID: "ai-engineering"
        )

        let metadata = MarkdownMetadata.parse(
            try String(contentsOf: processedURL, encoding: .utf8)
        )
        XCTAssertEqual(metadata.values(for: "topics"), ["ai-engineering"])
        XCTAssertNil(metadata.firstValue(for: "cluster_id"))
        XCTAssertNil(metadata.firstValue(for: "embedding_model"))
        XCTAssertNotNil(metadata.firstValue(for: "reviewed_at"))

        let conciseURL = root.appendingPathComponent(
            "gather/summaries/concise/ai-systems.md"
        )
        let comprehensiveURL = root.appendingPathComponent(
            "gather/summaries/comprehensive/ai-systems.md"
        )
        XCTAssertEqual(try String(contentsOf: conciseURL), "Concise version.\n")
        XCTAssertEqual(try String(contentsOf: comprehensiveURL), "Comprehensive version.\n")
        XCTAssertEqual(
            try String(contentsOf: root.appendingPathComponent("gather/summaries/ai-systems.md")),
            "Concise version.\n"
        )
    }

    func testEditablePromptRendersTopicsAndSourcePlaceholders() throws {
        let record = KnowledgeRecord(
            id: "source:test",
            captureID: "test",
            typeID: "source",
            title: "A Source",
            excerpt: "Excerpt",
            topicIDs: [],
            tags: [],
            sourceURL: "https://example.com",
            fileURL: URL(fileURLWithPath: "/tmp/source.md"),
            createdAt: nil,
            updatedAt: nil,
            reviewedAt: nil
        )
        let rendered = try ProcessingService.renderPrompt(
            template: "Topics:\n{{existing_topics}}\nSource:\n{{source}}",
            sourceText: "Body text",
            record: record,
            availableTopics: [
                TopicDefinition(
                    id: "ai-engineering",
                    areaID: "learning",
                    title: "AI Engineering",
                    description: "Building AI systems."
                )
            ]
        )

        XCTAssertTrue(rendered.contains("AI Engineering"))
        XCTAssertTrue(rendered.contains("Body text"))
        XCTAssertFalse(rendered.contains("{{existing_topics}}"))
        XCTAssertFalse(rendered.contains("{{source}}"))
    }

    func testDefaultPromptControlsSummariesTopicAndGranularity() {
        let prompt = AppSettings.defaultProcessingPrompt
        XCTAssertFalse(prompt.contains("title:"))
        XCTAssertTrue(prompt.contains("summaries.comprehensive"))
        XCTAssertTrue(prompt.contains("topic_name"))
        XCTAssertTrue(prompt.contains("2-4 words"))
        XCTAssertTrue(prompt.contains("AI Engineering\" instead of \"AI and Work"))
        XCTAssertTrue(prompt.contains("Ukraine War\" instead of \"Russia Ukraine War"))
        XCTAssertTrue(prompt.contains(AppSettings.existingTopicsPromptPlaceholder))
        XCTAssertTrue(prompt.contains(AppSettings.sourcePromptPlaceholder))
        XCTAssertFalse(prompt.contains("image"))
    }

    func testCaptureDeletionIncludesEveryCompanionSummary() throws {
        let root = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = root.appendingPathComponent("gather/example.md")
        try "Source".write(to: sourceURL, atomically: true, encoding: .utf8)
        let summaryURLs = LibraryStore.companionSummaryURLs(
            for: sourceURL,
            workspaceRootURL: root
        )
        for url in summaryURLs {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try "Summary".write(to: url, atomically: true, encoding: .utf8)
        }
        let unrelatedURL = root.appendingPathComponent("gather/summaries/unrelated.md")
        try "Keep".write(to: unrelatedURL, atomically: true, encoding: .utf8)

        try LibraryStore().deleteCapture(
            at: sourceURL,
            workspaceRootURL: root,
            trashItem: { try FileManager.default.removeItem(at: $0) }
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: sourceURL.path))
        XCTAssertTrue(summaryURLs.allSatisfy {
            !FileManager.default.fileExists(atPath: $0.path)
        })
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelatedURL.path))
    }

    func testLegacyClusterMetadataMigratesToTopicAndDeletesIndex() throws {
        let root = try makeWorkspace()
        let sourceURL = root.appendingPathComponent("gather/legacy.md")
        try TaxonomyStore().save(
            TaxonomyStore.defaultTaxonomy,
            to: root.appendingPathComponent("topics.md")
        )
        try """
        ---
        id: "legacy"
        type: "link"
        title: "Legacy source"
        created_at: "2026-07-09T10:00:00.000Z"
        updated_at: "2026-07-09T10:00:00.000Z"
        tags: []
        topics: []
        cluster_id: "cluster-ai"
        cluster: "AI Engineering"
        embedding_model: "old-embedding-model"
        source_url: "https://example.com"
        ---

        Source body.
        """.write(to: sourceURL, atomically: true, encoding: .utf8)
        let indexURL = root.appendingPathComponent("gather/.gather-capture-clusters.json")
        try "{}".write(to: indexURL, atomically: true, encoding: .utf8)

        try LibraryStore().migrateLegacyClusterMetadata(workspaceRootURL: root)

        let metadata = MarkdownMetadata.parse(try String(contentsOf: sourceURL))
        XCTAssertEqual(metadata.values(for: "topics"), ["ai-engineering"])
        XCTAssertNil(metadata.firstValue(for: "cluster"))
        XCTAssertNil(metadata.firstValue(for: "embedding_model"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: indexURL.path))
        let taxonomy = try TaxonomyStore().load(from: root.appendingPathComponent("topics.md"))
        XCTAssertTrue(taxonomy.topics.contains {
            $0.id == "ai-engineering" && $0.title == "AI Engineering"
        })
    }

    func testPromptTopicMigrationClearsExistingTopicsOnlyOnce() throws {
        let root = try makeWorkspace()
        let sourceURL = try writeSource(named: "existing.md", in: root)
        let original = try String(contentsOf: sourceURL)
            .replacingOccurrences(of: "topics: []", with: "topics:\n  - \"research\"")
        try original.write(to: sourceURL, atomically: true, encoding: .utf8)
        let store = LibraryStore()

        XCTAssertTrue(try store.preparePromptTopicMigration(workspaceRootURL: root))
        var metadata = MarkdownMetadata.parse(try String(contentsOf: sourceURL))
        XCTAssertEqual(metadata.values(for: "topics"), [])

        let recategorized = try String(contentsOf: sourceURL)
            .replacingOccurrences(of: "topics: []", with: "topics:\n  - \"ai-engineering\"")
        try recategorized.write(to: sourceURL, atomically: true, encoding: .utf8)

        XCTAssertFalse(try store.preparePromptTopicMigration(workspaceRootURL: root))
        metadata = MarkdownMetadata.parse(try String(contentsOf: sourceURL))
        XCTAssertEqual(metadata.values(for: "topics"), ["ai-engineering"])
    }

    func testProcessingAvoidsFilenameAndSummaryCollisions() throws {
        let root = try makeWorkspace()
        let sourceURL = try writeSource(named: "260709-1.md", in: root)
        try "occupied".write(
            to: root.appendingPathComponent("gather/useful-source.md"),
            atomically: true,
            encoding: .utf8
        )

        let processedURL = try LibraryStore().processSource(
            at: sourceURL,
            workspaceRootURL: root,
            suggestedFilename: "Useful Source",
            summary: "Summary",
            topicIDs: []
        )

        XCTAssertEqual(processedURL.lastPathComponent, "useful-source-2.md")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("gather/summaries/useful-source-2.md").path
        ))
    }

    func testReviewStateCanChangeAndReprocessingClearsIt() throws {
        let root = try makeWorkspace()
        let sourceURL = try writeSource(named: "260709-1.md", in: root)
        let store = LibraryStore()
        let reviewDate = ISO8601DateFormatter().date(from: "2026-07-09T13:00:00Z")!

        let processedURL = try store.processSource(
            at: sourceURL,
            workspaceRootURL: root,
            suggestedFilename: "Useful Source",
            summary: "Summary",
            topicIDs: []
        )
        try store.markSourceReviewed(
            at: processedURL,
            workspaceRootURL: root,
            date: reviewDate
        )

        var metadata = MarkdownMetadata.parse(
            try String(contentsOf: processedURL, encoding: .utf8)
        )
        XCTAssertEqual(metadata.firstValue(for: "reviewed_at"), "2026-07-09T13:00:00.000Z")

        let reprocessedURL = try store.processSource(
            at: processedURL,
            workspaceRootURL: root,
            suggestedFilename: "Useful Source",
            summary: "Updated summary",
            topicIDs: []
        )
        metadata = MarkdownMetadata.parse(
            try String(contentsOf: reprocessedURL, encoding: .utf8)
        )
        XCTAssertNil(metadata.firstValue(for: "reviewed_at"))
    }

    func testUnprocessedSourceCannotBeMarkedReviewed() throws {
        let root = try makeWorkspace()
        let sourceURL = try writeSource(named: "260709-1.md", in: root)

        XCTAssertThrowsError(
            try LibraryStore().markSourceReviewed(
                at: sourceURL,
                workspaceRootURL: root
            )
        ) { error in
            guard let storeError = error as? LibraryStoreError else {
                return XCTFail("Expected LibraryStoreError, got \(error)")
            }
            guard case .missingSummary = storeError else {
                return XCTFail("Expected missingSummary, got \(storeError)")
            }
        }
    }

    func testProcessedFilenameBaseIsSafeAndCompact() {
        XCTAssertEqual(
            LibraryStore.processedFilenameBase("  Héllo, Swift World!.MD  "),
            "hello-swift-world"
        )
        XCTAssertEqual(LibraryStore.processedFilenameBase("***", fallback: "260709-1"), "260709-1")
    }
}
