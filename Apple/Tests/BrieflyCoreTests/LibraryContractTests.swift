import CryptoKit
import XCTest
@testable import BrieflyCore

final class LibraryContractTests: XCTestCase {
    func testContractAndAtomicCacheBoundary() async throws {
        let projection = LibraryProjection.demo
        XCTAssertEqual(projection.schemaVersion, librarySchemaVersion)
        XCTAssertEqual(projection.entries.first?.preferredVariant, .concise)
        XCTAssertTrue(projection.entries[0].matches("systems biology"))
        XCTAssertEqual(projection.voiceBriefDefinitions.count, 4)
        XCTAssertEqual(projection.episodes(for: "hacker-news").count, 1)
        XCTAssertTrue(projection.channelSources.contains("https://news.ycombinator.com"))

        let invalid = Data("""
        {"schemaVersion":99,"generatedAt":"2026-07-31T08:00:00Z","files":[],"entries":[]}
        """.utf8)
        XCTAssertThrowsError(try LibraryProjection.decode(invalid))

        let temporary = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let cache = LibraryCache(root: temporary)
        try await cache.saveProjection(projection)
        let cachedProjection = try await cache.loadProjection()
        XCTAssertEqual(cachedProjection, projection)

        let data = Data("cached markdown".utf8)
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let file = LibraryFile(path: "library/item.md", contentHash: hash, byteCount: data.count)
        try await cache.save(data, for: file)
        let text = LibraryText(
            variant: .concise,
            path: file.path,
            contentHash: hash,
            wordCount: 2
        )
        let cachedText = try await cache.text(for: text)
        XCTAssertEqual(cachedText, "cached markdown")

        #if os(macOS)
        let commandOutput = try await runWorkspaceProcessingCommand(
            "/bin/cat",
            prompt: "native command boundary",
            timeout: 5
        )
        XCTAssertEqual(
            commandOutput,
            "native command boundary"
        )
        #endif

        let workspaceRoot = temporary.appending(
            path: "workspace",
            directoryHint: .isDirectory
        )
        let workspace = WorkspaceLibrary(root: workspaceRoot)
        let capturedID = try await workspace.capture("# Native capture\n\nEditable text.")
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
        let prompt = try await workspace.processingPrompt(entryID: capturedID)
        XCTAssertTrue(prompt.contains("Updated capture"))
        let suggestion = try WorkspaceProcessingSuggestion.decode(
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
        XCTAssertEqual(channels.first?.briefTitles, ["Native Daily"])
        try await workspace.updateChannel(
            "https://example.com/feed",
            retrievalCount: 12
        )
        channels = try await workspace.loadChannels()
        XCTAssertEqual(channels.first?.retrievalCount, 12)
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
            ]
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
            ]
        )
        XCTAssertTrue(signedInAgain.newEntryIDs.isEmpty)

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
        let stateDirectory = workspaceRoot.appending(
            path: ".shared-library",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: stateDirectory,
            withIntermediateDirectories: true
        )
        let channelState = """
        {
          "schemaVersion": 1,
          "sources": {
            "https://example.com/feed": {
              "retrievalCount": 12,
              "seen": ["one"],
              "items": [{
                "id": "one",
                "title": "Native source",
                "url": "https://example.com/one",
                "entryID": "\(capturedID)",
                "ingestedAt": "2026-07-31T09:00:00Z"
              }]
            }
          },
          "voiceBriefs": {}
        }
        """
        try Data(channelState.utf8).write(
            to: stateDirectory.appending(path: "voice-brief-state.json"),
            options: .atomic
        )
        let episode = try await workspace.runVoiceBrief(
            id: voiceBriefID,
            command: "/bin/cat",
            runner: { prompt in
                XCTAssertTrue(prompt.contains("Native source"))
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
        XCTAssertEqual(savedEpisode.sourceIDs, [capturedID])
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
        try await workspace.markVoiceBriefAttempt(
            id: voiceBriefID,
            at: scheduledCheck
        )
        let dueAfterAttempt = try await workspace.dueVoiceBriefIDs(at: scheduledCheck)
        XCTAssertFalse(dueAfterAttempt.contains(voiceBriefID))

        let baselineMirror = try await workspace.buildCloudMirror()
        XCTAssertTrue(
            baselineMirror.files.contains {
                $0.reference.path.hasPrefix("library/") &&
                    $0.reference.path.hasSuffix(".md")
            }
        )
        XCTAssertTrue(baselineMirror.media.contains { $0.reference.kind == .audio })
        XCTAssertTrue(baselineMirror.media.contains { $0.reference.kind == .favicon })
        try await workspace.saveSyncBaseline(baselineMirror.projection.files)
        let sourceURL = try await workspace.fileURL(entryID: capturedID)
        let sourcePath = "library/\(sourceURL.lastPathComponent)"
        try await workspace.writeText(
            entryID: capturedID,
            variant: .source,
            text: "# Local edit\n\nKeep this conflict copy."
        )
        let remoteData = Data("# Remote edit\n\nUse this synchronized copy.\n".utf8)
        let remoteReference = LibraryFile(
            path: sourcePath,
            contentHash: SHA256.hash(data: remoteData)
                .map { String(format: "%02x", $0) }
                .joined(),
            byteCount: remoteData.count
        )
        let remoteProjection = LibraryProjection(
            schemaVersion: librarySchemaVersion,
            generatedAt: ISO8601DateFormatter().string(from: Date()),
            files: baselineMirror.projection.files.map {
                $0.path == sourcePath ? remoteReference : $0
            },
            entries: baselineMirror.projection.entries,
            voiceBriefs: baselineMirror.projection.voiceBriefs
        )
        let merge = try await workspace.mergeCloudProjection(remoteProjection) { file in
            if file.path == sourcePath { return remoteData }
            return try XCTUnwrap(
                baselineMirror.files.first { $0.reference.path == file.path }?.data
            )
        }
        XCTAssertEqual(merge.conflicts, 1)
        XCTAssertEqual(try Data(contentsOf: sourceURL), remoteData)
        let conflicts = try FileManager.default.contentsOfDirectory(
            at: sourceURL.deletingLastPathComponent(),
            includingPropertiesForKeys: nil
        )
        XCTAssertTrue(conflicts.contains { $0.lastPathComponent.contains("-conflict") })
        #endif

        do {
            _ = try await CloudLibrary().accountStatus()
            XCTFail("Unconfigured CloudKit must fail before creating a container.")
        } catch {
            XCTAssertEqual(
                error.localizedDescription,
                "Set Briefly’s CloudKit container in the native target before synchronizing."
            )
        }
    }
}
