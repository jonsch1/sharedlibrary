import Foundation
import XCTest
@testable import BrieflyCore

final class LibraryContractTests: XCTestCase {
    func testRefreshPersistsPendingHintsWithoutCreatingDocuments() async throws {
        let (root, store) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = "https://example.com/feed"
        try await store.addChannel(source)

        let result = try await store.checkChannelInput(source, maximumItems: 1) { maximumItems in
            XCTAssertEqual(maximumItems, 1)
            return ChannelInputBatch(
                inputID: .podcast,
                title: "Example feed",
                kind: .podcast,
                items: [ChannelItemReference(
                    id: "episode-1",
                    title: "Episode one",
                    url: URL(string: "https://example.com/episode-1")!,
                    publishedAt: "2026-08-01T10:00:00Z",
                    hints: ItemInputHints(
                        preferredInput: .podcast,
                        content: "A transcript hint.",
                        mediaURL: URL(string: "https://cdn.example.com/episode-1.mp3"),
                        transcriptURL: URL(string: "https://cdn.example.com/episode-1.vtt"),
                        transcriptType: "text/vtt",
                        transcriptLanguage: "en"
                    )
                )]
            )
        }

        XCTAssertEqual(result.newItemIDs, ["episode-1"])
        let channels = try await store.loadChannels()
        let channel = try XCTUnwrap(channels.first { $0.source == source })
        let item = try XCTUnwrap(channel.items.first)
        XCTAssertTrue(item.isPending)
        XCTAssertEqual(item.candidate().preferredInput, .podcast)
        XCTAssertEqual(item.candidate().content, "A transcript hint.")
        XCTAssertEqual(item.candidate().mediaURL, "https://cdn.example.com/episode-1.mp3")
        XCTAssertEqual(item.candidate().transcriptType, "text/vtt")
        XCTAssertEqual(item.candidate().transcriptLanguage, "en")
        let documents = try await store.documentDatabase().allDocuments()
        XCTAssertTrue(documents.isEmpty)

        let reopened = SQLiteLibraryStore(databaseURL: root.appending(path: "library.sqlite3"))
        let reopenedChannels = try await reopened.loadChannels()
        let persisted = try XCTUnwrap(reopenedChannels.first { $0.source == source })
        XCTAssertEqual(persisted.items.first?.candidate(), item.candidate())
    }

    func testGroupedChannelsUseTheConfiguredRollingReviewWindow() async throws {
        let (root, store) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let sources = [
            "https://example.com/one",
            "https://example.com/two"
        ]
        let groupID = try await store.addChannel(sources)
        try await store.updateChannelGroup(
            groupID,
            title: "Example sources",
            sources: sources,
            reviewLimit: 2,
            schedule: "daily 08:30"
        )

        for source in sources {
            _ = try await store.checkChannelInput(source) { maximumItems in
                XCTAssertEqual(maximumItems, 2)
                return ChannelInputBatch(
                    inputID: .feed,
                    title: source,
                    kind: .feed,
                    items: (1...3).map { number in
                        ChannelItemReference(
                            id: "\(source)-\(number)",
                            title: "Story \(number)",
                            url: URL(string: "\(source)/story-\(number)")!
                        )
                    }
                )
            }
        }

        let channels = try await store.loadChannels()
        let grouped = try XCTUnwrap(channels.first { $0.source == groupID })
        XCTAssertEqual(grouped.reviewLimit, 2)
        XCTAssertEqual(grouped.sources, sources.sorted())
        XCTAssertLessThanOrEqual(grouped.items.count, 2)
        XCTAssertEqual(grouped.schedule, "daily 08:30")
        XCTAssertEqual(defaultChannelReviewLimit, 50)
        XCTAssertEqual(channelReviewLimitRange, 1...50)

        do {
            try await store.updateChannel(
                sources[0], reviewLimit: 0, schedule: "manual"
            )
            XCTFail("An empty review window must be rejected.")
        } catch LibraryError.invalidChannelReviewLimit {
            // Expected boundary error.
        }

        let due = try await store.dueChannelSources(
            at: Date().addingTimeInterval(2 * 86_400)
        )
        XCTAssertEqual(due, sources.sorted())
    }

    func testAcceptRejectAndRemoveKeepAcceptedEntryInTheMainLibrary() async throws {
        let (root, store) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = "https://example.com/feed"
        try await store.addChannel(source)
        let candidates = [
            LibraryChannelCandidate(
                id: "accepted",
                title: "Accepted story",
                url: "https://example.com/accepted",
                content: "Accepted content",
                preferredInput: .webPage
            ),
            LibraryChannelCandidate(
                id: "rejected",
                title: "Rejected story",
                url: "https://example.com/rejected",
                content: "Rejected content",
                preferredInput: .webPage
            )
        ]
        _ = try await store.captureSignedInChannelItems(
            source: source,
            title: "Example feed",
            items: candidates
        )

        try await store.rejectChannelItem(channelID: source, itemID: "rejected")
        let documents = try await store.documentDatabase().allDocuments()
        XCTAssertTrue(documents.isEmpty)

        let entryID = try await store.acceptChannelItem(
            channelID: source,
            itemID: "accepted"
        ) { candidate in
            try await store.captureItem(ItemDraft(
                inputID: candidate.preferredInput ?? .webPage,
                title: candidate.title,
                content: candidate.content,
                sourceURL: URL(string: candidate.url),
                canonicalURL: URL(string: candidate.url),
                mediaURL: candidate.mediaURL.flatMap(URL.init(string:))
            ))
        }
        XCTAssertFalse(entryID.isEmpty)
        let job = try await store.claimNextProcessingJob()
        XCTAssertEqual(job?.documentID, entryID)

        var projection = try await store.loadProjection()
        let entry = try XCTUnwrap(projection.entries.first { $0.id == entryID })
        XCTAssertEqual(entry.channelSources, [source])
        XCTAssertTrue(entry.isMainLibraryEntry)
        let pendingChannels = try await store.loadChannels()
        XCTAssertTrue(pendingChannels.first { $0.source == source }?.items.isEmpty == true)

        let removedItemCount = try await store.removeChannel(source)
        XCTAssertEqual(removedItemCount, 0)
        let document = try await store.getDocument(entryID)
        XCTAssertEqual(document.type, "link")
        projection = try await store.loadProjection()
        let remainingEntry = try XCTUnwrap(projection.entries.first { $0.id == entryID })
        XCTAssertTrue(remainingEntry.isMainLibraryEntry)
        XCTAssertEqual(remainingEntry.channelSources, [])
        let remainingChannels = try await store.loadChannels()
        XCTAssertNil(remainingChannels.first { $0.source == source })
    }

    func testLegacyGeneratedDocumentMigratesToAnOrdinaryEntry() async throws {
        let (root, _) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appending(path: "library.sqlite3")
        do {
            let database = try SQLiteLibrary(databaseURL: databaseURL)
            let document = try database.createDocument(
                title: "Old generated episode",
                body: "Keep this content",
                type: "voice_brief_episode"
            )
            try database.execute("ALTER TABLE documents ADD COLUMN voice_brief_id TEXT")
            try database.run(
                "UPDATE documents SET voice_brief_id = 'old-brief' WHERE id = ?",
                bindings: [.text(document.id)]
            )
            try database.run(
                "INSERT INTO document_tags(document_id, tag) VALUES(?, 'voice-brief')",
                bindings: [.text(document.id)]
            )
            try database.execute(
                "CREATE TABLE voice_brief_runs(id TEXT PRIMARY KEY)"
            )
        }

        let migrated = try SQLiteLibrary(databaseURL: databaseURL)
        let document = try XCTUnwrap(try migrated.allDocuments().first)
        XCTAssertEqual(document.type, "document")
        XCTAssertEqual(document.texts[.source], "Keep this content")
        XCTAssertTrue(document.tags.isEmpty)
        let tables = try migrated.query(
            "SELECT name FROM sqlite_master WHERE type = 'table' AND name LIKE 'voice_brief_%'"
        ) { columnText($0, 0) }
        XCTAssertTrue(tables.isEmpty)
        let columns = try migrated.query("PRAGMA table_info(documents)") { columnText($0, 1) }
        XCTAssertFalse(columns.contains("voice_brief_id"))

        let projection = try await SQLiteLibraryStore(databaseURL: databaseURL).loadProjection()
        let entry = try XCTUnwrap(projection.entries.first)
        XCTAssertTrue(entry.isMainLibraryEntry)
    }

    func testPreReviewChannelLinksReturnToPendingWithoutTouchingUnlinkedDocuments() async throws {
        let (root, _) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appending(path: "library.sqlite3")
        let source = "https://example.com/feed"
        let historicalID: String
        let preservedID: String
        do {
            let database = try SQLiteLibrary(databaseURL: databaseURL)
            historicalID = try database.createDocument(
                title: "Historical channel item",
                body: "Keep this as a review candidate.",
                type: "link",
                sourceURL: "https://example.com/story"
            ).id
            preservedID = try database.createDocument(
                title: "Personal document",
                body: "A genuinely captured document.",
                type: "link",
                sourceURL: "https://personal.example/document"
            ).id
            try database.saveChannelRecords([SQLiteChannelRecord(
                source: source,
                title: "Example feed",
                kind: .feed,
                reviewLimit: 1,
                canLoadMore: false,
                seen: ["story"],
                items: [LibraryChannelItem(
                    id: "story",
                    title: "Historical channel item",
                    url: "https://example.com/story",
                    entryID: historicalID,
                    ingestedAt: Date().iso8601
                )]
            )])
            // Simulate a library written by the durable-review refactor before the
            // acceptance marker existed.
            try database.run("UPDATE channel_items SET accepted_at = NULL")
            try database.execute("ALTER TABLE channel_items DROP COLUMN accepted_at")
            try database.run(
                "DELETE FROM sync_state WHERE key = 'briefly-channel-review-acceptance-v1'"
            )
        }

        let store = SQLiteLibraryStore(databaseURL: databaseURL)
        let projection = try await store.loadProjection()
        XCTAssertTrue(projection.entries.contains { $0.id == preservedID })
        XCTAssertFalse(projection.entries.contains { $0.id == historicalID })
        let historical = try await store.getDocument(historicalID, includeDeleted: true)
        XCTAssertTrue(historical.deleted)

        let channels = try await store.loadChannels()
        let channel = try XCTUnwrap(channels.first { $0.source == source })
        let candidate = try XCTUnwrap(channel.items.first)
        XCTAssertTrue(candidate.isPending)
        XCTAssertEqual(candidate.content, "Keep this as a review candidate.")
    }

    func testCloudAttachmentCanArriveBeforeItsDocument() throws {
        let (root, _) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try SQLiteLibrary(databaseURL: root.appending(path: "library.sqlite3"))
        let audio = Data("audio".utf8)

        try database.applyRemote(SQLiteAttachment(
            id: "document:audio",
            documentID: "document",
            kind: "audio",
            mimeType: "audio/mp4",
            data: audio,
            revision: 1,
            cloudRecordData: nil
        ))
        try database.applyRemote(SQLiteDocument(
            id: "document",
            captureID: "capture",
            title: "Fetched document",
            texts: [.source: "Fetched body"]
        ))

        XCTAssertEqual(try database.attachment(documentID: "document", kind: "audio")?.1, audio)
    }

    func testSpokenTextRemovesMarkdownWithoutBeingVoiceBriefSpecific() {
        XCTAssertEqual(
            spokenText("# Update\n\nRead [the source](https://example.com)."),
            "Update Read the source."
        )
    }

    private func makeStore() -> (URL, SQLiteLibraryStore) {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "briefly-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        return (root, SQLiteLibraryStore(databaseURL: root.appending(path: "library.sqlite3")))
    }
}
