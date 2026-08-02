import XCTest
@testable import BrieflyCore

final class LibraryContractTests: XCTestCase {
    func testCloudAttachmentCanArriveBeforeItsDocument() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
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

    func testCanonicalCaptureAndMediaPersistence() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SQLiteLibraryStore(databaseURL: root.appending(path: "library.sqlite3"))
        let first = try await store.captureItem(ItemDraft(
            inputID: .podcast,
            title: "Canonical episode",
            content: "Transcript",
            sourceURL: URL(string: "https://www.example.com/episode?utm_source=test")!,
            canonicalURL: URL(string: "https://example.com/episode")!,
            mediaURL: URL(string: "https://cdn.example.com/episode.mp3")!
        ))
        let second = try await store.captureItem(ItemDraft(
            inputID: .webPage,
            title: "Duplicate route",
            content: "Duplicate content",
            sourceURL: URL(string: "https://example.com/episode?fbclid=tracking")!
        ))
        XCTAssertEqual(first, second)
        let projection = try await store.loadProjection()
        let entry = try XCTUnwrap(projection.entries.first)
        XCTAssertEqual(entry.mediaURL, "https://cdn.example.com/episode.mp3")
        XCTAssertEqual(entry.text(for: .source)?.text, "Duplicate content")
        let index = try await store.loadLibraryIndex()
        let indexedEntry = try XCTUnwrap(index.entries.first)
        XCTAssertEqual(indexedEntry.excerpt, "Duplicate content")
        XCTAssertNotNil(indexedEntry.text(for: .source))
        XCTAssertNil(indexedEntry.text(for: .source)?.text)
        let indexedDocument = try await store.getDocument(indexedEntry.id)
        XCTAssertEqual(indexedDocument.texts[.source], "Duplicate content")
        try await store.writeText(
            entryID: indexedEntry.id,
            variant: .brief,
            text: "# Stored excerpt"
        )
        let updatedIndex = try await store.loadLibraryIndex()
        XCTAssertEqual(updatedIndex.entries.first?.excerpt, "Stored excerpt")
        let database = try await store.documentDatabase()
        let documentCount = try database.allDocuments().count
        XCTAssertEqual(documentCount, 1)
    }

    func testChannelOnlyCheckpointsSuccessfulItemsAndTrashAllowsRetry() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SQLiteLibraryStore(databaseURL: root.appending(path: "library.sqlite3"))
        let source = "https://feed.test/native"
        try await store.addChannel(source)
        let batch = ChannelInputBatch(
            inputID: .feed,
            title: "Native feed",
            kind: .feed,
            items: [
                .init(id: "one", title: "One", url: URL(string: "https://story.test/one")!,
                      hints: .init(title: "One", content: "First story")),
                .init(id: "two", title: "Two", url: URL(string: "https://story.test/two")!,
                      hints: .init(title: "Two", content: "Second story"))
            ]
        )
        let attempts = ChannelAttemptLog()
        let first = try await store.checkChannelInput(
            source,
            discover: { _ in batch },
            ingest: { candidate in
                await attempts.record(candidate.id)
                if candidate.id == "two" { throw NativeInputError.unreadableContent }
                return try await store.captureItem(ItemDraft(
                    inputID: .webPage,
                    title: candidate.title,
                    content: candidate.content,
                    sourceURL: URL(string: candidate.url)
                ), asVoiceBriefSource: true)
            }
        )
        XCTAssertEqual(first.channel.items.map(\.id), ["one"])
        XCTAssertNotNil(first.channel.error)

        let second = try await store.checkChannelInput(
            source,
            discover: { _ in batch },
            ingest: { candidate in
                await attempts.record(candidate.id)
                return try await store.captureItem(ItemDraft(
                    inputID: .webPage,
                    title: candidate.title,
                    content: candidate.content,
                    sourceURL: URL(string: candidate.url)
                ), asVoiceBriefSource: true)
            }
        )
        XCTAssertEqual(second.newEntryIDs.count, 1)
        let channelProjection = try await store.loadProjection()
        let fetchedEntry = try XCTUnwrap(
            channelProjection.entries.first {
                $0.id == second.newEntryIDs.first
            }
        )
        XCTAssertFalse(fetchedEntry.isMainLibraryEntry)
        let attemptedIDs = await attempts.values()
        XCTAssertEqual(attemptedIDs, ["two", "one", "two"])

        let trashed = try XCTUnwrap(second.channel.items.first { $0.id == "two" }?.entryID)
        try await store.moveToTrash(entryID: trashed)
        let third = try await store.checkChannelInput(
            source,
            discover: { _ in batch },
            ingest: { candidate in
                try await store.captureItem(ItemDraft(
                    inputID: .webPage,
                    title: candidate.title,
                    content: candidate.content,
                    sourceURL: URL(string: candidate.url)
                ), asVoiceBriefSource: true)
            }
        )
        XCTAssertEqual(third.newEntryIDs.count, 1)
        XCTAssertNotEqual(third.newEntryIDs.first, trashed)
    }

    func testSQLiteCanonicalLibraryJourney() async throws {
        let projection = LibraryProjection.demo
        XCTAssertEqual(projection.schemaVersion, librarySchemaVersion)
        XCTAssertEqual(projection.entries.first?.preferredVariant, .concise)
        XCTAssertTrue(projection.entries[0].matches("systems biology"))
        XCTAssertEqual(projection.voiceBriefDefinitions.count, 4)
        XCTAssertEqual(projection.episodes(for: "hacker-news").count, 1)
        XCTAssertTrue(projection.channelSources.contains("https://news.ycombinator.com"))

        var projectionJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(projection))
                as? [String: Any]
        )
        var projectionEntries = try XCTUnwrap(projectionJSON["entries"] as? [[String: Any]])
        let episodeIndex = try XCTUnwrap(
            projectionEntries.firstIndex { $0["entryType"] as? String == "voice_brief_episode" }
        )
        projectionEntries[episodeIndex]["topicNames"] = ["Episode only"]
        projectionJSON["entries"] = projectionEntries
        let mixedProjection = try LibraryProjection.decode(
            JSONSerialization.data(withJSONObject: projectionJSON)
        )
        XCTAssertTrue(mixedProjection.topics.contains("Episode only"))
        XCTAssertFalse(mixedProjection.documentTopics.contains("Episode only"))

        let invalid = Data("""
        {"schemaVersion":99,"generatedAt":"2026-07-31T08:00:00Z","files":[],"entries":[]}
        """.utf8)
        XCTAssertThrowsError(try LibraryProjection.decode(invalid))

        let temporary = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: temporary) }
        #if os(macOS)
        let commandOutput = try await runProcessingCommand(
            "/bin/cat",
            prompt: "native command boundary",
            timeout: 5
        )
        XCTAssertEqual(
            commandOutput,
            "native command boundary"
        )
        #endif

        let databaseURL = temporary.appending(path: "library.sqlite3")
        let workspace = SQLiteLibraryStore(databaseURL: databaseURL)
        let capturedID = try await workspace.capture("# Native capture\n\nEditable text.")
        let database = try await workspace.documentDatabase()
        try database.enqueueInitialCloudUploadIfNeeded()
        XCTAssertTrue(
            try database.outbox().contains {
                $0.recordType == "document" && $0.documentID == capturedID
            }
        )
        try database.markInitialCloudUploadCompleted()
        var workspaceProjection = try await workspace.loadProjection()
        XCTAssertEqual(workspaceProjection.entries.first?.id, capturedID)
        XCTAssertEqual(
            workspaceProjection.entries.first?.text(for: .source)?.text,
            "# Native capture\n\nEditable text."
        )
        try await workspace.writeText(
            entryID: capturedID,
            variant: .source,
            text: "# Updated capture\n\nSaved by Swift."
        )
        workspaceProjection = try await workspace.loadProjection()
        XCTAssertEqual(
            workspaceProjection.entries.first?.text(for: .source)?.text,
            "# Updated capture\n\nSaved by Swift."
        )
        try await workspace.addHighlight(
            entryID: capturedID,
            variant: .source,
            text: "Saved by Swift."
        )
        try await workspace.addHighlight(
            entryID: capturedID,
            variant: .source,
            text: "Saved by Swift."
        )
        let highlights = try await workspace.loadHighlights()
        XCTAssertTrue(highlights.contains("# Highlights"))
        XCTAssertTrue(highlights.contains("> Saved by Swift."))
        let removedHighlight = try await workspace.removeHighlight("Saved by Swift.")
        let highlightsAfterRemoval = try await workspace.loadHighlights()
        let removedMissingHighlight = try await workspace.removeHighlight("Saved by Swift.")
        XCTAssertTrue(removedHighlight)
        XCTAssertFalse(highlightsAfterRemoval.contains("> Saved by Swift."))
        XCTAssertFalse(removedMissingHighlight)
        let highlightDocument = try await workspace.getDocument("system:highlights")
        XCTAssertEqual(highlightDocument.type, "highlights")
        let prompt = try await workspace.processingPrompt(entryID: capturedID)
        XCTAssertTrue(prompt.contains("Updated capture"))
        let suggestion = try ProcessingSuggestion.decode(
            """
            ```json
            {
              "short_filename": "native-capture",
              "topic_name": "Native Development",
              "summaries": {
                "brief": "Brief summary.",
                "concise": "Concise summary.",
                "detailed": "Detailed summary.",
                "comprehensive": "Comprehensive summary."
              }
            }
            ```
            """
        )
        _ = try await workspace.applyProcessingSuggestion(
            entryID: capturedID,
            suggestion: suggestion
        )
        workspaceProjection = try await workspace.loadProjection()
        let processed = try XCTUnwrap(
            workspaceProjection.entries.first { $0.id == capturedID }
        )
        XCTAssertEqual(processed.topicNames, ["Native Development"])
        XCTAssertEqual(processed.text(for: .brief)?.text, "Brief summary.")
        XCTAssertEqual(
            processed.text(for: .comprehensive)?.text,
            "Comprehensive summary."
        )
        let topicID = try XCTUnwrap(processed.topicIDs.first)
        let topicDefinitions = try await workspace.topicDefinitions()
        XCTAssertEqual(topicDefinitions.first?.title, "Native Development")
        try await workspace.replaceTopicDefinitions([
            LibraryTopicDefinition(id: topicID, title: "Native Apps")
        ])
        workspaceProjection = try await workspace.loadProjection()
        XCTAssertEqual(
            workspaceProjection.entries.first { $0.id == capturedID }?.topicNames,
            ["Native Apps"]
        )
        let pdfID = try await workspace.captureDocument(
            title: "Native PDF",
            content: "Text extracted by PDFKit."
        )
        workspaceProjection = try await workspace.loadProjection()
        let pdf = try XCTUnwrap(
            workspaceProjection.entries.first { $0.id == pdfID }
        )
        XCTAssertEqual(pdf.entryType, "pdf")
        XCTAssertEqual(pdf.text(for: .source)?.text, "Text extracted by PDFKit.")
        let faviconData = Data([
            0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a,
            0x00, 0x00, 0x00, 0x00
        ])
        let webID = try await workspace.captureWebPage(
            title: "Native web capture",
            content: "Extracted page.",
            sourceURL: URL(string: "https://example.com/page")!,
            faviconData: faviconData,
            faviconFileExtension: "png"
        )
        workspaceProjection = try await workspace.loadProjection()
        let webEntry = try XCTUnwrap(
            workspaceProjection.entries.first { $0.id == webID }
        )
        XCTAssertTrue(webEntry.faviconFile?.hasSuffix(".png") == true)
        let faviconURL = try await workspace.faviconURL(entryID: webID)
        XCTAssertNotNil(faviconURL)
        let voiceBriefID = try await workspace.saveVoiceBrief(
            LibraryVoiceBriefDraft(
                title: "Native Daily",
                schedule: "daily 07:30",
                length: "5 minutes",
                sources: ["https://example.com/feed"],
                prompt: "Connect the most useful updates.",
                prioritizeForMe: true
            )
        )
        workspaceProjection = try await workspace.loadProjection()
        XCTAssertEqual(workspaceProjection.voiceBriefDefinitions.first?.id, voiceBriefID)
        XCTAssertEqual(
            workspaceProjection.voiceBriefDefinitions.first?.prompt,
            "Connect the most useful updates."
        )
        try await workspace.addChannel("https://example.com/feed")
        var channels = try await workspace.loadChannels()
        XCTAssertEqual(channels.first?.retrievalCount, 5)
        XCTAssertEqual(channels.first?.schedule, "manual")
        XCTAssertEqual(channels.first?.briefTitles, ["Native Daily"])
        let manuallyCheckedChannels = try await workspace.dueChannelSources()
        XCTAssertTrue(manuallyCheckedChannels.isEmpty)
        try await workspace.updateChannel(
            "https://example.com/feed",
            retrievalCount: 12,
            schedule: "weekly thu 07:30"
        )
        channels = try await workspace.loadChannels()
        XCTAssertEqual(channels.first?.retrievalCount, 12)
        XCTAssertEqual(channels.first?.schedule, "weekly thu 07:30")
        let ingestChannelItem: @Sendable (LibraryChannelCandidate) async throws -> String = {
            item in
            guard let url = URL(string: item.url) else {
                throw LibraryError.invalidChannel
            }
            return try await workspace.captureWebPage(
                title: item.title,
                content: item.content,
                sourceURL: url,
                asVoiceBriefSource: true
            )
        }
        let signedIn = try await workspace.captureSignedInChannelItems(
            source: "https://example.com/feed",
            title: "Signed-in feed",
            items: [
                LibraryChannelCandidate(
                    id: "signed-one",
                    title: "Signed item",
                    url: "https://example.com/signed-one",
                    content: "Private session content."
                )
            ],
            ingest: ingestChannelItem
        )
        XCTAssertEqual(signedIn.newEntryIDs.count, 1)
        let signedInAgain = try await workspace.captureSignedInChannelItems(
            source: "https://example.com/feed",
            title: "Signed-in feed",
            items: [
                LibraryChannelCandidate(
                    id: "signed-one",
                    title: "Signed item",
                    url: "https://example.com/signed-one",
                    content: "Private session content."
                )
            ],
            ingest: ingestChannelItem
        )
        XCTAssertTrue(signedInAgain.newEntryIDs.isEmpty)
        let routed = try await workspace.captureSignedInChannelItems(
            source: "https://example.com/feed",
            title: "Signed-in feed",
            items: [
                LibraryChannelCandidate(
                    id: "routed-item",
                    title: "Routed item",
                    url: "https://example.com/routed-item",
                    content: "Discovered content hint."
                )
            ],
            ingest: { _ in capturedID }
        )
        XCTAssertEqual(routed.newEntryIDs, [capturedID])
        XCTAssertEqual(
            routed.channel.items.first { $0.id == "routed-item" }?.entryID,
            capturedID
        )

        let feed = try parseFeed(
            Data("""
            <?xml version="1.0"?>
            <rss version="2.0">
              <channel>
                <title>Native Feed</title>
                <item>
                  <guid>one</guid>
                  <title>First &amp; best</title>
                  <link>https://example.com/one</link>
                  <description><![CDATA[<p>Readable body.</p>]]></description>
                </item>
              </channel>
            </rss>
            """.utf8),
            fallbackTitle: "Fallback"
        )
        XCTAssertEqual(feed.title, "Native Feed")
        XCTAssertEqual(feed.items.first?.title, "First & best")
        XCTAssertEqual(feed.items.first?.content, "Readable body.")
        let youtubeFeed = try XCTUnwrap(youtubeFeedURL(
            in: #"<meta itemprop="channelId" content="UCabcdefghijklmnopqrstuv">"#,
            relativeTo: URL(string: "https://www.youtube.com/@briefly")!
        ))
        XCTAssertEqual(
            URLComponents(url: youtubeFeed, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "channel_id" }?.value,
            "UCabcdefghijklmnopqrstuv"
        )
        let hackerNews = try XCTUnwrap(parseHackerNews(
            """
            <table>
              <tr class="athing" id="123">
                <td class="title"><span class="titleline">
                  <a href="https://example.com/story">A useful story</a>
                </span></td>
              </tr>
              <tr class="athing" id="124">
                <td class="title"><span class="titleline">
                  <a href="item?id=124">Ask HN</a>
                </span></td>
              </tr>
            </table>
            """,
            sourceURL: URL(string: "https://news.ycombinator.com")!,
            maximumItems: 2
        ))
        XCTAssertEqual(hackerNews.items.map(\.id), ["123", "124"])
        XCTAssertEqual(hackerNews.items[1].url, "https://news.ycombinator.com/item?id=124")
        let renderedVoicePrompt = try renderVoiceBriefPrompt(
            prompt: defaultVoiceBriefPrompt,
            title: "Native Daily",
            requestedLength: "5 minutes",
            sourcePackets: "A native source packet."
        )
        XCTAssertTrue(renderedVoicePrompt.contains("Voice brief: Native Daily"))
        XCTAssertTrue(
            try renderVoiceBriefPrompt(
                prompt: "Lead with practical consequences.",
                template: """
                Custom {{voice_brief_title}} / {{requested_length}}
                {{source_packets}}
                """,
                title: "Native Daily",
                requestedLength: "5 minutes",
                sourcePackets: "A native source packet."
            ).contains("Custom Native Daily / 5 minutes")
        )
        XCTAssertEqual(
            spokenVoiceBriefText("# Update\n\nRead [the source](https://example.com)."),
            "Update Read the source."
        )
        XCTAssertThrowsError(
            try renderVoiceBriefPrompt(
                prompt: "{{voice_brief_title}} only",
                title: "Invalid",
                requestedLength: "",
                sourcePackets: ""
            )
        )

        #if os(macOS)
        let episode = try await workspace.runVoiceBrief(
            id: voiceBriefID,
            command: "/bin/cat",
            runner: { prompt in
                XCTAssertTrue(prompt.contains("Signed item"))
                return "# Managed episode"
            }
        )
        XCTAssertEqual(episode.script, "# Managed episode")
        workspaceProjection = try await workspace.loadProjection()
        let savedEpisode = try XCTUnwrap(
            workspaceProjection.entries.first { $0.id == episode.entryID }
        )
        XCTAssertEqual(savedEpisode.entryType, "voice_brief_episode")
        XCTAssertEqual(savedEpisode.voiceBriefID, voiceBriefID)
        XCTAssertEqual(
            Set(savedEpisode.sourceIDs ?? []),
            Set(signedIn.newEntryIDs + [capturedID])
        )
        let generatedAudio = temporary.appending(path: "episode.wav")
        try Data("RIFF native audio boundary".utf8).write(to: generatedAudio)
        try await workspace.attachAudio(
            entryID: episode.entryID,
            file: generatedAudio
        )
        workspaceProjection = try await workspace.loadProjection()
        XCTAssertEqual(
            workspaceProjection.entries.first { $0.id == episode.entryID }?.hasAudio,
            true
        )
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let scheduledCheck = try XCTUnwrap(
            calendar.date(
                from: DateComponents(
                    year: 2030,
                    month: 8,
                    day: 1,
                    hour: 8
                )
            )
        )
        let initiallyDue = try await workspace.dueVoiceBriefIDs(at: scheduledCheck)
        XCTAssertTrue(initiallyDue.contains(voiceBriefID))
        let dueChannels = try await workspace.dueChannelSources(at: scheduledCheck)
        XCTAssertEqual(dueChannels, ["https://example.com/feed"])
        try await workspace.markVoiceBriefAttempt(
            id: voiceBriefID,
            at: scheduledCheck
        )
        let dueAfterAttempt = try await workspace.dueVoiceBriefIDs(at: scheduledCheck)
        XCTAssertFalse(dueAfterAttempt.contains(voiceBriefID))

        let current = try await workspace.getDocument(capturedID)
        let committed = try await workspace.commitDocument(
            capturedID,
            baseRevision: current.revision,
            texts: [.source: "# SQLite canonical\n\nRevision checked."]
        )
        XCTAssertEqual(committed.revision, current.revision + 1)
        do {
            _ = try await workspace.commitDocument(
                capturedID,
                baseRevision: current.revision,
                texts: [.source: "stale write"]
            )
            XCTFail("A stale revision must not commit.")
        } catch SQLiteLibraryError.revisionConflict(let revision) {
            XCTAssertEqual(revision, committed.revision)
        }
        let results = try await workspace.search("revision checked")
        XCTAssertEqual(results.first?.id, capturedID)
        let outbox = try await workspace.documentDatabase().outbox()
        XCTAssertTrue(outbox.contains {
            $0.recordType == "document" && $0.documentID == capturedID
        })
        try await workspace.moveToTrash(entryID: pdfID)
        let activeEntries = try await workspace.loadProjection().entries
        let allEntries = try await workspace.loadProjection(includeDeleted: true).entries
        XCTAssertFalse(activeEntries.contains { $0.id == pdfID })
        XCTAssertTrue(allEntries.contains { $0.id == pdfID })
        #endif

    }
}

private actor ChannelAttemptLog {
    private var items = [String]()
    func record(_ value: String) { items.append(value) }
    func values() -> [String] { items }
}
