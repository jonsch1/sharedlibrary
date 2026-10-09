import Foundation
import XCTest
@testable import BrieflyCore
#if os(macOS)
import CryptoKit
#endif

private let realItemTestURLs: [(ItemInputID, URL)] = [
    (.text, URL(string: "https://www.rfc-editor.org/rfc/rfc9110.txt")!),
    (.pdf, URL(string: "https://www.rfc-editor.org/rfc/rfc9110.pdf")!),
    (.arxiv, URL(string: "https://arxiv.org/abs/1706.03762")!),
    (.biorxiv, URL(string: "https://www.biorxiv.org/content/10.64898/2026.07.09.737605v1")!),
    (.youtube, URL(string: "https://www.youtube.com/watch?v=jNQXAC9IVRw")!),
    (.podcast, URL(string: "https://inandaroundpodcasting.com/episode/behind-the-scenes")!),
    (.reddit, URL(string: "https://www.reddit.com/r/IAmA/comments/z1c9z/i_am_barack_obama_president_of_the_united_states/")!),
    (.x, URL(string: "https://x.com/jack/status/20")!),
    (.bluesky, URL(string: "https://bsky.app/profile/bsky.app/post/3lsyqmukj3c2b")!),
    (.threads, URL(string: "https://www.threads.com/@zuck/post/C-srcchPpp7")!),
    (.tiktok, URL(string: "https://www.tiktok.com/@scout2015/video/6718335390845095173")!),
    (.webPage, URL(string: "https://example.com/")!)
]

private let realChannelTestURLs: [(ChannelInputID, URL)] = [
    (.feed, URL(string: "https://hnrss.org/frontpage")!),
    (.youtube, URL(string: "https://www.youtube.com/channel/UC_x5XG1OV2P6uZZ5FSM9Ttw")!),
    (.podcast, URL(string: "https://feeds.truefans.fm/rss/6750170d97d4af53ccbaec06/")!),
    (.reddit, URL(string: "https://www.reddit.com/r/swift/")!),
    (.x, URL(string: "https://x.com/openai")!),
    (.arxiv, URL(string: "https://arxiv.org/list/cs.AI/recent")!),
    (.biorxiv, URL(string: "https://www.biorxiv.org/search/rare%20disease")!),
    (.hackerNews, URL(string: "https://news.ycombinator.com/")!),
    (.page, URL(string: "https://example.com/")!)
]

@MainActor
final class NativeItemInputTests: XCTestCase {
    private let router = NativeItemInputRouter()

    #if os(macOS)
    func testOpenRouterBrowserAuthorizationUsesPKCEAndRejectsUnrelatedCallbacks() async throws {
        let browser = OpenRouterBrowserFixture()
        let key = try await OpenRouterOAuth().signIn(
            openBrowser: browser.open,
            http: InputHTTPClient { request, _ in try await browser.exchange(request) }
        )
        try await browser.requests?.value
        XCTAssertEqual(key, "test-openrouter-key")
        let callback = try XCTUnwrap(browser.callback)
        var request = URLRequest(url: callback, timeoutInterval: 1)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        do {
            _ = try await URLSession.shared.data(for: request)
            XCTFail("The authorization listener must close after sign-in")
        } catch {}

        let canceled = Task { @MainActor in
            try await OpenRouterOAuth().signIn(openBrowser: { _ in
                Task { @MainActor in browser.pendingSignIn?.cancel() }
                return true
            }, http: InputHTTPClient { _, _ in
                XCTFail("Canceling must not exchange a code")
                throw CancellationError()
            })
        }
        browser.pendingSignIn = canceled
        do {
            _ = try await canceled.value
            XCTFail("Canceling must not create a credential")
        } catch is CancellationError {}

        let deniedBrowser = OpenRouterBrowserFixture()
        deniedBrowser.denied = true
        do {
            _ = try await OpenRouterOAuth().signIn(openBrowser: deniedBrowser.open, http: InputHTTPClient { _, _ in
                XCTFail("Declining authorization must not create a credential")
                throw CancellationError()
            }, timeout: 10)
            XCTFail("Declining must end the authorization attempt")
        } catch {
            XCTAssertEqual(error.localizedDescription, "OpenRouter authorization was declined.")
        }
        try await deniedBrowser.requests?.value
    }

    func testOpenRouterModelAndEffortReachSummaryRequestAndPersistedOutput() async throws {
        let modelJSON = Data(#"""
        {"data":{
          "id":"example/reasoner","name":"Example Reasoner",
          "architecture":{"input_modalities":["text"],"output_modalities":["text"]},
          "supported_parameters":["structured_outputs","response_format","reasoning"],
          "top_provider":{"max_completion_tokens":8192},
          "reasoning":{"supported_efforts":["high","medium","low","none"],"default_effort":"medium","mandatory":true}
        }}
        """#.utf8)
        let suggestionJSON = #"{"short_filename":"source-summary","topic_name":"Reading","summaries":{"concise":"The selected model’s concise summary.","detailed":"The selected model’s detailed summary."}}"#
        let http = InputHTTPClient { request, _ in
            if request.url?.path == "/api/v1/model/example/reasoner" {
                XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"), "Public model lookup must not expose the account key")
                return InputHTTPResponse(data: modelJSON, finalURL: request.url!)
            }
            XCTAssertEqual(request.url?.absoluteString, "https://openrouter.ai/api/v1/chat/completions")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")
            let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
            XCTAssertEqual(payload["model"] as? String, "example/reasoner")
            let reasoning = try XCTUnwrap(payload["reasoning"] as? [String: Any])
            XCTAssertEqual(reasoning["effort"] as? String, "high")
            let provider = try XCTUnwrap(payload["provider"] as? [String: Any])
            XCTAssertEqual(provider["require_parameters"] as? Bool, true)
            XCTAssertNil(provider["order"], "Model selection must not pin an unrelated provider")
            XCTAssertEqual((payload["response_format"] as? [String: Any])?["type"] as? String, "json_schema")
            XCTAssertLessThanOrEqual(try XCTUnwrap(payload["max_tokens"] as? Int), 8192)
            let messages = try XCTUnwrap(payload["messages"] as? [[String: String]])
            XCTAssertTrue(messages.first?["content"]?.contains("The original source remains saved.") == true)
            let response = try JSONSerialization.data(withJSONObject: [
                "choices": [["message": ["content": suggestionJSON], "finish_reason": "stop"]]
            ])
            return InputHTTPResponse(data: response, finalURL: request.url!)
        }
        let model = try await fetchOpenRouterModel("example/reasoner", http: http)
        let storedSelection = try JSONDecoder().decode(OpenRouterModelSelection.self, from:
            JSONEncoder().encode(OpenRouterModelSelection(modelID: "example/reasoner", model: model)))
        let root = FileManager.default.temporaryDirectory.appending(path: "openrouter-summary-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SQLiteLibraryStore(databaseURL: root.appending(path: "library.sqlite3"))
        let entryID = try await store.captureDocument(title: "Source", content: "The original source remains saved.")
        let prompt = try await store.processingPrompt(entryID: entryID, template: defaultProcessingPrompt)
        let output = try await runOpenRouterProcessing(
            prompt: prompt, format: "json", apiKey: "test-key", modelID: storedSelection.modelID,
            reasoningEffort: "high", model: storedSelection.model, http: http
        )
        let resultID = try await store.applyProcessingSuggestion(entryID: entryID, suggestion: .decode(output))
        let document = try await store.getDocument(resultID)
        XCTAssertEqual(document.texts[.source], "The original source remains saved.")
        XCTAssertEqual(document.texts[.concise], "The selected model’s concise summary.")
        do {
            _ = try await runOpenRouterProcessing(
                prompt: prompt, format: "json", apiKey: "test-key", modelID: storedSelection.modelID,
                reasoningEffort: "none", model: storedSelection.model, http: http
            )
            XCTFail("Mandatory reasoning must reject disabled reasoning before sending a paid request")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("supported by this model"))
        }
    }
    #endif

    func testPermanentDeletionClearsTrashAndSurvivesOfflineSync() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "trash-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SQLiteLibraryStore(databaseURL: root.appending(path: "local.sqlite3"))
        let database = try await store.documentDatabase()
        let peer = try SQLiteLibrary(databaseURL: root.appending(path: "peer.sqlite3"))
        let saved = try database.createDocument(title: "Private item", body: "Private original")
        try database.saveAttachment(documentID: saved.id, kind: "original-pdf", mimeType: "application/pdf", data: Data("%PDF-original".utf8))
        let attachment = try XCTUnwrap(database.attachment(saved.id + ":original-pdf"))
        try peer.applyRemote(saved)
        try peer.applyRemote(attachment)
        do {
            try await store.permanentlyDelete([saved.id])
            XCTFail("Active items cannot be permanently deleted")
        } catch {}
        XCTAssertEqual(try database.getDocument(saved.id).texts[.source], "Private original")
        _ = try database.commitDocument(.init(id: saved.id, baseRevision: saved.revision, deleted: true))
        try await store.permanentlyDelete([saved.id])
        XCTAssertTrue(try database.deletedDocuments().isEmpty)
        XCTAssertTrue(try database.allDocuments(includeDeleted: true).isEmpty)
        XCTAssertNil(try database.attachment(saved.id + ":original-pdf"))
        XCTAssertThrowsError(try database.getDocument(saved.id, includeDeleted: true))
        let marker = try XCTUnwrap(database.readDocument(saved.id))
        XCTAssertTrue(marker.isPermanentlyDeleted)
        XCTAssertTrue(marker.title.isEmpty)
        XCTAssertTrue(marker.texts.isEmpty)
        XCTAssertNil(marker.captureRequest)
        XCTAssertTrue(try database.outbox().contains { $0.recordType == "attachment" && $0.operation == "delete" })
        try peer.applyRemote(marker)
        XCTAssertTrue(try peer.allDocuments(includeDeleted: true).isEmpty)
        XCTAssertNil(try peer.attachment(saved.id + ":original-pdf"))
        var offlineEdit = saved
        offlineEdit.revision = marker.revision + 10
        offlineEdit.updatedAt = Date().addingTimeInterval(60)
        try database.applyRemote(offlineEdit)
        try database.applyRemote(attachment)
        XCTAssertTrue(try database.allDocuments(includeDeleted: true).isEmpty)
        XCTAssertNil(try database.attachment(saved.id + ":original-pdf"))
        XCTAssertThrowsError(try database.saveAttachment(documentID: saved.id, kind: "audio", mimeType: "audio/mp4", data: Data([1])))
        XCTAssertThrowsError(try database.commitDocument(.init(id: saved.id, baseRevision: marker.revision, deleted: false)))
        let active = try database.createDocument(title: "Keep", body: "Keep this")
        let trash = try database.createDocument(title: "Remove", body: "Delete this")
        _ = try database.commitDocument(.init(id: trash.id, baseRevision: trash.revision, deleted: true))
        try await store.emptyTrash()
        XCTAssertEqual(try database.allDocuments().map(\.id), [active.id])
        XCTAssertTrue(try database.deletedDocuments().isEmpty)
    }

    func testCompleteLibraryExportsPreserveContentAndPendingFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "export-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SQLiteLibraryStore(databaseURL: root.appending(path: "live.sqlite3"))
        let database = try await store.documentDatabase()
        let item = try database.createDocument(title: "../../Same title", body: "Original",
            texts: [.source: "Original", .concise: "Short", .detailed: "Detailed"], tags: ["saved"])
        let duplicate = try database.createDocument(title: "../../Same title", body: "Another")
        _ = try database.commitDocument(SQLiteDocumentCommit(id: duplicate.id, baseRevision: duplicate.revision, deleted: true))
        try await store.addHighlight(entryID: item.id, variant: .source, text: "Original")
        try database.saveChannelRecords([SQLiteChannelRecord(source: "https://example.com/feed")])
        let pdf = Data("%PDF-1.4\noriginal queued bytes".utf8)
        let pdfURL = root.appending(path: "Original.pdf")
        try pdf.write(to: pdfURL)
        let pendingID = try await store.queueCapture(ItemInputRequest(source: .file(pdfURL)))
        try FileManager.default.removeItem(at: pdfURL)
        let before = try database.allDocuments(includeDeleted: true)
        let snapshot = root.appending(path: "Library.sqlite3")
        try await store.exportLibrary(as: .sqlite, to: snapshot)
        XCTAssertFalse(FileManager.default.fileExists(atPath: snapshot.path + "-wal"))
        let exported = try SQLiteLibrary(databaseURL: snapshot)
        XCTAssertEqual(try exported.query("PRAGMA integrity_check") { columnText($0, 0) }, ["ok"])
        XCTAssertEqual(try exported.allDocuments(includeDeleted: true), before)
        XCTAssertEqual(try exported.attachment(documentID: pendingID, kind: "original-pdf")?.1, pdf)
        XCTAssertEqual(try exported.channelRecords().first?.source, "https://example.com/feed")
        _ = try database.createDocument(title: "After snapshot", body: "Later")
        XCTAssertEqual(try exported.allDocuments(includeDeleted: true).count, before.count)

        let folder = root.appending(path: "Markdown")
        try await store.exportLibrary(as: .markdown, to: folder)
        let pathsData = try Data(contentsOf: folder.appending(path: "Metadata/item-paths.json"))
        let paths = try JSONDecoder().decode([String: String].self, from: pathsData)
        let itemFolder = folder.appending(path: try XCTUnwrap(paths[item.id]))
        XCTAssertEqual(try String(contentsOf: itemFolder.appending(path: "source.md"), encoding: .utf8), "Original")
        XCTAssertEqual(try String(contentsOf: itemFolder.appending(path: "concise.md"), encoding: .utf8), "Short")
        XCTAssertEqual(try String(contentsOf: itemFolder.appending(path: "detailed.md"), encoding: .utf8), "Detailed")
        XCTAssertTrue(try XCTUnwrap(paths[duplicate.id]).hasPrefix("Trash/"))
        XCTAssertNotEqual(paths[item.id], paths[duplicate.id])
        XCTAssertTrue(paths.values.allSatisfy { !$0.contains("..") })
        XCTAssertNotNil(paths["system:highlights"])
        let attachments = try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appending(path: "Metadata/attachments.json"))) as! [[String: Any]]
        let attachment = try XCTUnwrap(attachments.first { $0["document_id"] as? String == pendingID })
        let relativeFile = try XCTUnwrap((attachment["data"] as? [String: String])?["file"])
        XCTAssertEqual(try Data(contentsOf: folder.appending(path: relativeFile)), pdf)
        let pendingMetadata = try Data(contentsOf: folder.appending(path: try XCTUnwrap(paths[pendingID])).appending(path: "metadata.json"))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        XCTAssertEqual(try decoder.decode(SQLiteDocument.self, from: pendingMetadata).captureRequest?.state, .queued)
        do {
            try await store.exportLibrary(as: .sqlite, to: snapshot)
            XCTFail("Exports must not overwrite an existing file")
        } catch { XCTAssertEqual((error as NSError).code, CocoaError.fileWriteFileExists.rawValue) }
        XCTAssertEqual(try exported.allDocuments(includeDeleted: true), before)
    }

    func testPhoneInboxSurvivesHandoffAndMacProcessing() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "handoff-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let phone = SQLiteLibraryStore(databaseURL: root.appending(path: "phone.sqlite3"))
        let phoneDB = try await phone.documentDatabase()
        let inbox = try SharedCaptureInbox(directoryURL: root.appending(path: "Inbox"))
        let url = URL(string: "https://example.com/saved.txt")!
        let shared = try inbox.enqueue(url: url)
        let claim = try XCTUnwrap(inbox.claimNext())
        let id = try await phone.queueCapture(try inbox.inputRequest(for: claim), captureID: claim.captureID)
        // Simulate termination after the database commit but before extension acknowledgement.
        try inbox.recoverInterruptedClaims()
        let retried = try XCTUnwrap(inbox.claimNext())
        let retryID = try await phone.queueCapture(try inbox.inputRequest(for: retried), captureID: retried.captureID)
        XCTAssertEqual(id, retryID)
        try inbox.complete(retried)
        XCTAssertEqual(try phoneDB.allDocuments().count, 1)
        let saved = try phoneDB.getDocument(id)
        XCTAssertEqual(saved.captureRequest?.payload, .url(url.absoluteString))
        XCTAssertEqual(saved.captureRequest?.state, .queued)
        XCTAssertTrue(saved.texts.isEmpty, "Saving must not produce extracted source or summaries")
        let phoneJob = try await phone.claimNextProcessingJob()
        XCTAssertNil(phoneJob, "The phone creates no local worker job")
        XCTAssertTrue(try phoneDB.outbox().contains { $0.documentID == id })

        let mac = SQLiteLibraryStore(databaseURL: root.appending(path: "mac.sqlite3"))
        let macDB = try await mac.documentDatabase()
        // Exercise the same remote-document boundary CloudKit uses, including its encoded payload.
        try macDB.applyRemote(JSONDecoder().decode(SQLiteDocument.self, from: JSONEncoder().encode(saved)))
        do {
            try await mac.extractQueuedCapture(id, context: .init(http: fixtureHTTP([:])))
            XCTFail("Unavailable extraction must remain visible as a failed capture")
        } catch {}
        let failed = try macDB.getDocument(id)
        XCTAssertEqual(failed.captureRequest?.state, .failed)
        XCTAssertEqual(failed.captureRequest?.payload, saved.captureRequest?.payload)
        XCTAssertNotNil(failed.captureRequest?.error)
        try phoneDB.applyRemote(failed)
        try await phone.retryCapture(id)
        try macDB.applyRemote(phoneDB.getDocument(id))
        try await mac.extractQueuedCapture(id, context: .init(http: fixtureHTTP([
            "saved.txt": .text("Saved article\nThe original body is available now.", "text/plain")
        ])))
        let extracted = try macDB.getDocument(id)
        XCTAssertEqual(extracted.captureRequest?.state, .summarizing)
        XCTAssertTrue(extracted.texts[.source]?.contains("original body") == true)
        let job = try await mac.claimNextProcessingJob()
        XCTAssertEqual(job?.documentID, id)
        _ = try await mac.applyProcessingSuggestion(entryID: id, suggestion: .init(
            shortFilename: "saved-article", topicName: "Saved Reading",
            summaries: .init(concise: "A concise summary.", detailed: "A detailed summary.")
        ))
        try await mac.completeProcessingJob(entryID: id)
        try phoneDB.applyRemote(macDB.getDocument(id))
        let ready = try await phone.loadLibraryIndex().entries.first { $0.id == id }
        XCTAssertEqual(ready?.captureRequest?.state, .ready)
        XCTAssertEqual(try phoneDB.getDocument(id).texts[.concise], "A concise summary.")
        XCTAssertEqual(try phoneDB.getDocument(id).captureID, shared.captureID)
        XCTAssertEqual(try phoneDB.allDocuments().count, 1)
        // Repeated delivery of the original queue record cannot replace completed results.
        try macDB.applyRemote(saved)
        XCTAssertEqual(try macDB.getDocument(id).captureRequest?.state, .ready)
        let remaining = try await mac.pendingCaptureIDs()
        XCTAssertTrue(remaining.isEmpty)

        let pdfURL = root.appending(path: "original.pdf")
        let pdf = fixturePDF(text: "A durable PDF body", title: "Original PDF")
        try pdf.write(to: pdfURL)
        // If storing the original fails, the pending item must not be acknowledged.
        try phoneDB.execute("CREATE TEMP TRIGGER reject_original BEFORE INSERT ON attachments BEGIN SELECT RAISE(ABORT, 'disk full'); END")
        do {
            _ = try await phone.queueCapture(.init(source: .file(pdfURL)))
            XCTFail("A missing original must roll back the item")
        } catch {}
        XCTAssertEqual(try phoneDB.allDocuments().count, 1)
        try phoneDB.execute("DROP TRIGGER reject_original")
        let pdfID = try await phone.queueCapture(.init(source: .file(pdfURL)))
        try FileManager.default.removeItem(at: pdfURL)
        let reopened = try SQLiteLibrary(databaseURL: root.appending(path: "phone.sqlite3"))
        XCTAssertEqual(try reopened.attachment(documentID: pdfID, kind: "original-pdf")?.1, pdf)
        try macDB.applyRemote(reopened.getDocument(pdfID))
        try await mac.extractQueuedCapture(pdfID, context: .init(http: fixtureHTTP([:])))
        XCTAssertEqual(try macDB.getDocument(pdfID).captureRequest?.state, .queued,
                       "A document arriving before its PDF must wait for the attachment")
        let originalID = try XCTUnwrap(reopened.outbox().first { $0.recordType == "attachment" }?.documentID)
        try macDB.applyRemote(XCTUnwrap(reopened.attachment(originalID)))
        try await mac.extractQueuedCapture(pdfID, context: .init(http: fixtureHTTP([:])))
        XCTAssertTrue(try macDB.getDocument(pdfID).texts[.source]?.contains("durable PDF body") == true)

        let textURL = root.appending(path: "Reading notes.md")
        try Data("# Reading notes\n\nA note from a text file.".utf8).write(to: textURL)
        let textID = try await phone.queueCapture(CaptureFileInput.read(textURL))
        try FileManager.default.removeItem(at: textURL)
        let textDocument = try phoneDB.getDocument(textID)
        XCTAssertEqual(textDocument.title, "Reading notes")
        XCTAssertTrue(textDocument.texts.isEmpty)
        try macDB.applyRemote(textDocument)
        try await mac.extractQueuedCapture(textID, context: .init(http: fixtureHTTP([:])))
        XCTAssertTrue(try macDB.getDocument(textID).texts[.source]?.contains("A note from a text file") == true)

        let removedID = try await phone.queueCapture(.init(source: .text("Do not process this removed item")))
        let removed = try phoneDB.getDocument(removedID)
        _ = try phoneDB.commitDocument(.init(id: removedID, baseRevision: removed.revision, deleted: true))
        try macDB.applyRemote(phoneDB.getDocument(removedID, includeDeleted: true))
        let pending = try await mac.pendingCaptureIDs()
        XCTAssertFalse(pending.contains(removedID))
    }

    func testEveryItemInputHasARealTestURL() {
        assertRealTestURLs(
            realItemTestURLs.map { ($0.0.rawValue, $0.1) },
            expectedIDs: ItemInputID.allCases.map(\.rawValue)
        )
    }

    func testTextInput() async throws {
        let url = itemTestURL(.text)
        let value = try await router.ingest(
            .init(source: .url(url)),
            context: .init(http: fixtureHTTP([
                "rfc/rfc9110.txt": .text("HTTP Semantics\nWith detail.", "text/plain")
            ]))
        )
        XCTAssertEqual(value.inputID, .text)
        XCTAssertEqual(value.title, "HTTP Semantics")
        XCTAssertEqual(value.sourceURL, url)
    }

    func testClipboardTextInput() async throws {
        let value = try await router.ingest(.init(source: .text("A useful note\nWith detail.")))
        XCTAssertEqual(value.inputID, .text)
        XCTAssertEqual(value.title, "A useful note")
    }

    func testLocalPDFInput() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "input-\(UUID()).pdf")
        try fixturePDF(text: "Native PDF content", title: "Native report").write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let value = try await router.ingest(.init(source: .file(url)))
        XCTAssertEqual(value.inputID, .pdf)
        XCTAssertEqual(value.title, "Native report")
        XCTAssertTrue(value.content.contains("Native PDF content"))
    }

    func testLocalPDFInputUsesFilenameWhenMetadataIsEmpty() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "briefly-native-report.pdf")
        try? FileManager.default.removeItem(at: url)
        try fixturePDF(text: "Filename fallback content", title: "").write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let value = try await router.ingest(.init(source: .file(url)))

        XCTAssertEqual(value.inputID, .pdf)
        XCTAssertEqual(value.title, "briefly native report")
        XCTAssertTrue(value.content.contains("Filename fallback content"))
    }

    func testLocalPDFInputRejectsFilesOverTheImportLimit() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "oversized-\(UUID()).pdf")
        try Data(repeating: 0, count: 20_000_001).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        do {
            _ = try await router.ingest(.init(source: .file(url)))
            XCTFail("Expected the PDF import limit to be enforced")
        } catch let error as NativeInputError {
            XCTAssertEqual(error, .responseTooLarge)
        }
    }

    func testSharedCaptureInboxRetriesIdempotentlyAtTheLibraryBoundary() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "shared-capture-\(UUID())", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let inbox = try SharedCaptureInbox(directoryURL: root.appending(path: "Inbox"))
        let store = SQLiteLibraryStore(databaseURL: root.appending(path: "library.sqlite3"))
        let database = try await store.documentDatabase()

        let queued = try inbox.enqueue(text: "A durable shared note\nWith useful detail.")
        let firstClaim = try XCTUnwrap(inbox.claimNext())
        var firstDraft = try await router.ingest(try inbox.inputRequest(for: firstClaim))
        firstDraft.audioData = Data("recorded audio".utf8)
        firstDraft.audioMimeType = "audio/mp4"
        try database.execute("""
            CREATE TEMP TRIGGER fail_capture_attachment BEFORE INSERT ON attachments
            BEGIN SELECT RAISE(ABORT, 'Attachment storage unavailable'); END
            """)
        do {
            _ = try await store.captureItem(firstDraft, captureID: firstClaim.captureID)
            XCTFail("Capture must fail when its attachment cannot be saved")
        } catch is SQLiteLibraryError {}
        XCTAssertTrue(try database.allDocuments().isEmpty)
        XCTAssertTrue(try database.outbox().isEmpty)
        try database.execute("DROP TRIGGER fail_capture_attachment")
        let firstID = try await store.captureItem(firstDraft, captureID: firstClaim.captureID)

        // An older interrupted capture may already have the document but no attachment.
        try database.execute("DELETE FROM attachments")
        try inbox.release(firstClaim, error: NativeInputError.requestFailed(503))
        XCTAssertNil(try inbox.claimNext(excluding: [firstClaim.id]))
        let retriedClaim = try XCTUnwrap(inbox.claimNext())
        let retriedID = try await store.captureItem(firstDraft, captureID: retriedClaim.captureID)
        try inbox.complete(retriedClaim)

        XCTAssertEqual(queued.id, retriedClaim.id)
        XCTAssertEqual(firstID, retriedID)
        XCTAssertTrue(try inbox.pendingCaptures().isEmpty)
        XCTAssertEqual(try database.allDocuments().count, 1)
        XCTAssertEqual(try database.attachment(documentID: firstID, kind: "audio")?.1, firstDraft.audioData)

        _ = try inbox.enqueue(text: "A recoverable failed capture")
        for _ in 0..<SharedCaptureInbox.maximumAttempts {
            let failed = try XCTUnwrap(inbox.claimNext())
            try inbox.release(failed, error: NativeInputError.requestFailed(503))
        }
        XCTAssertNil(try inbox.claimNext())
        try inbox.retryFailedCaptures()
        XCTAssertNotNil(try inbox.claimNext())
    }

    func testSharedCaptureInboxKeepsItsOwnPDFCopy() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "shared-pdf-\(UUID())", directoryHint: .isDirectory)
        let source = root.appending(path: "provider-copy")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try fixturePDF(text: "Shared PDF content", title: "Shared report").write(to: source)
        let inbox = try SharedCaptureInbox(directoryURL: root.appending(path: "Inbox"))

        _ = try inbox.enqueuePDF(at: source)
        try FileManager.default.removeItem(at: source)
        let claimed = try XCTUnwrap(inbox.claimNext())
        let draft = try await router.ingest(try inbox.inputRequest(for: claimed))
        try inbox.complete(claimed)

        XCTAssertEqual(draft.inputID, .pdf)
        XCTAssertEqual(draft.title, "Shared report")
        XCTAssertTrue(draft.content.contains("Shared PDF content"))
        XCTAssertTrue(try inbox.pendingCaptures().isEmpty)
    }

    func testArxivInput() async throws {
        let value = try await router.ingest(
            .init(source: .url(itemTestURL(.arxiv))),
            context: .init(http: fixtureHTTP([
                "markxiv.org/abs/1706.03762": .text("# Attention Is All You Need\n\nPaper body.", "text/markdown")
            ]))
        )
        XCTAssertEqual(value.inputID, .arxiv)
        XCTAssertEqual(value.title, "Attention Is All You Need")
    }

    func testArxivInputFallsBackToOriginalPDFWhenMarkxivFails() async throws {
        let pdf = fixturePDF(text: "Original arXiv PDF content", title: "Attention Is All You Need")
        let value = try await router.ingest(
            .init(source: .url(URL(string: "https://arxiv.org/abs/1706.03762")!)),
            context: .init(http: InputHTTPClient { request, maximumBytes in
                if request.url!.host == "markxiv.org" {
                    throw NativeInputError.requestFailed(502)
                }
                guard request.url!.absoluteString.contains("arxiv.org/pdf/1706.03762.pdf") else {
                    throw FixtureError.missing(request.url!.absoluteString)
                }
                guard pdf.count <= maximumBytes else { throw NativeInputError.responseTooLarge }
                return InputHTTPResponse(
                    data: pdf,
                    finalURL: request.url!,
                    contentType: "application/pdf"
                )
            })
        )
        XCTAssertEqual(value.inputID, .arxiv)
        XCTAssertEqual(value.title, "Attention Is All You Need")
        XCTAssertTrue(value.content.contains("Original arXiv PDF content"))
        XCTAssertEqual(value.sourceURL?.host, "arxiv.org")
    }

    func testBiorxivInputUsesTheFullPaperPDF() async throws {
        let url = itemTestURL(.biorxiv)
        let pdf = fixturePDF(text: "Complete manuscript body", title: "PDF title")
        let attempts = AttemptCounter()
        let value = try await router.ingest(
            .init(source: .url(url)),
            context: .init(http: InputHTTPClient { request, maximumBytes in
                if request.url!.path.hasSuffix(".full.pdf") {
                    if await attempts.increment() == 1 {
                        throw NativeInputError.requestFailed(500)
                    }
                    guard pdf.count <= maximumBytes else {
                        throw NativeInputError.responseTooLarge
                    }
                    return InputHTTPResponse(
                        data: pdf,
                        finalURL: request.url!,
                        contentType: "application/pdf"
                    )
                }
                let html = """
                    <meta property="og:title" content="MSstatsBioNet">
                    <meta property="og:description" content="Abstract only">
                    """
                return InputHTTPResponse(
                    data: Data(html.utf8),
                    finalURL: request.url!,
                    contentType: "text/html"
                )
            })
        )
        let attemptCount = await attempts.value
        XCTAssertEqual(value.inputID, .biorxiv)
        XCTAssertEqual(value.title, "MSstatsBioNet")
        XCTAssertEqual(value.sourceURL, url)
        XCTAssertEqual(value.canonicalURL, url)
        XCTAssertEqual(attemptCount, 2)
        XCTAssertTrue(value.content.contains("Complete manuscript body"))
        XCTAssertFalse(value.content.contains("Abstract only"))
    }

    func testBiorxivInputRendersTheFullArticleWhenThePDFIsBlocked() async throws {
        let url = itemTestURL(.biorxiv)
        let fullText = String(repeating: "Complete rendered manuscript body. ", count: 50)
        let value = try await router.ingest(
            .init(source: .url(url)),
            context: .init(
                http: InputHTTPClient { request, _ in
                    if request.url!.path.hasSuffix(".full.pdf") {
                        throw NativeInputError.requestFailed(429)
                    }
                    return InputHTTPResponse(
                        data: Data(),
                        finalURL: request.url!,
                        contentType: "text/html"
                    )
                },
                render: { renderedURL in
                    XCTAssertTrue(renderedURL.path.hasSuffix(".full"))
                    return RenderedInputPage(
                        title: "Rendered bioRxiv paper",
                        content: fullText,
                        sourceURL: renderedURL
                    )
                }
            )
        )
        XCTAssertEqual(value.inputID, .biorxiv)
        XCTAssertEqual(value.title, "Rendered bioRxiv paper")
        XCTAssertEqual(value.sourceURL, url)
        XCTAssertTrue(value.content.contains("Complete rendered manuscript body"))
        XCTAssertGreaterThan(value.content.count, 1_000)
    }

    func testYouTubeInput() async throws {
        let player: [String: Any] = [
            "videoDetails": ["title": "Native video", "author": "Briefly", "shortDescription": "Demo"],
            "captions": ["playerCaptionsTracklistRenderer": ["captionTracks": [[
                "baseUrl": "https://www.youtube.com/api/timedtext?v=jNQXAC9IVRw&lang=en",
                "languageCode": "en"
            ]]]],
            "streamingData": ["adaptiveFormats": [[
                "mimeType": "audio/mpeg", "url": "https://traffic.libsyn.com/atpfm/atp300.mp3"
            ]]]
        ]
        let captions: [String: Any] = ["events": [
            ["segs": [["utf8": "First line."]]], ["segs": [["utf8": "Second line."]]]
        ]]
        let value = try await router.ingest(
            .init(source: .url(itemTestURL(.youtube)), retainAudio: true),
            context: .init(
                http: fixtureHTTP([
                    "youtubei/v1/player": .json(player),
                    "youtube.com/api/timedtext": .json(captions)
                ]),
                downloadAudio: { _ in (Data("audio".utf8), "audio/mp4") }
            )
        )
        XCTAssertEqual(value.inputID, .youtube)
        XCTAssertTrue(value.transcriptAvailable)
        XCTAssertTrue(value.content.contains("Second line"))
        XCTAssertEqual(value.audioData, Data("audio".utf8))
    }

    func testYouTubeInputFallsBackToPagePlayerAndPrefersManualXMLCaptions() async throws {
        let player = #"{"videoDetails":{"title":"Page video","author":"Page channel"},"captions":{"playerCaptionsTracklistRenderer":{"captionTracks":[{"baseUrl":"https://www.youtube.com/api/timedtext?lang=fr","languageCode":"fr"},{"baseUrl":"https://www.youtube.com/api/timedtext?lang=en&kind=asr","languageCode":"en","kind":"asr"},{"baseUrl":"https://www.youtube.com/api/timedtext?lang=en&kind=manual","languageCode":"en","kind":"manual"}]}}}"#
        let page = """
            <html><head>
            <meta property="og:description" content="Page description fallback">
            <link rel="icon" href="https://cdn.example.org/youtube-icon.png">
            <script>var ytInitialPlayerResponse = \(player);</script>
            </head></html>
            """
        let manualXML = #"<transcript><text start="0">Preferred &amp; <b>manual</b>.</text><text start="1">Second line.</text></transcript>"#
        let asrXML = #"<transcript><text start="0">ASR should not win.</text></transcript>"#
        let value = try await router.ingest(
            .init(source: .url(itemTestURL(.youtube))),
            context: .init(http: fixtureHTTP([
                "youtube.com/watch": .text(page),
                "timedtext?lang=en&kind=manual": .text(manualXML, "text/xml"),
                "timedtext?lang=en&kind=asr": .text(asrXML, "text/xml")
            ]))
        )

        XCTAssertEqual(value.title, "Page video")
        XCTAssertEqual(value.transcriptLanguage, "en")
        XCTAssertTrue(value.content.contains("Preferred & manual."))
        XCTAssertTrue(value.content.contains("Second line."))
        XCTAssertFalse(value.content.contains("ASR should not win"))
        XCTAssertEqual(value.faviconURL?.absoluteString, "https://cdn.example.org/youtube-icon.png")
    }

    func testYouTubeInputUsesTranscriptionWhenPublishedCaptionsAreUnavailable() async throws {
        let player: [String: Any] = [
            "videoDetails": ["title": "Generated video", "author": "Briefly"],
            "streamingData": ["adaptiveFormats": [[
                "mimeType": "audio/mpeg", "url": "https://cdn.example.org/generated.mp3"
            ]]]
        ]
        let value = try await router.ingest(
            .init(source: .url(itemTestURL(.youtube))),
            context: .init(
                http: fixtureHTTP(["youtubei/v1/player": .json(player)]),
                transcribe: { url in
                    XCTAssertEqual(url.absoluteString, "https://cdn.example.org/generated.mp3")
                    return InputTranscript(text: "Generated transcript.", language: "en")
                }
            )
        )

        XCTAssertTrue(value.transcriptAvailable)
        XCTAssertEqual(value.transcriptLanguage, "en")
        XCTAssertTrue(value.content.contains("Generated transcript."))
    }

    func testPodcastInput() async throws {
        let episode = itemTestURL(.podcast)
        let media = URL(string: "https://traffic.libsyn.com/atpfm/atp300.mp3")!
        let value = try await router.ingest(
            .init(
                source: .url(episode),
                hints: .init(
                    preferredInput: .podcast,
                    title: "Behind the Scenes",
                    mediaURL: media
                )
            ),
            context: .init(http: fixtureHTTP([:]), transcribe: { _ in
                InputTranscript(text: "Spoken words.", language: "en")
            })
        )
        XCTAssertEqual(value.inputID, .podcast)
        XCTAssertEqual(value.mediaURL, media)
        XCTAssertTrue(value.content.contains("Spoken words"))
    }

    func testPodcastInputIncludesTranscriptionFailureInFallbackContent() async throws {
        let media = URL(string: "https://traffic.libsyn.com/atpfm/atp300.mp3")!
        let value = try await router.ingest(
            .init(
                source: .url(itemTestURL(.podcast)),
                hints: .init(
                    preferredInput: .podcast,
                    title: "Behind the Scenes",
                    content: "Episode description.",
                    mediaURL: media
                )
            ),
            context: .init(http: fixtureHTTP([:]), transcribe: { _ in
                throw NativeInputError.requestFailed(429)
            })
        )

        XCTAssertFalse(value.transcriptAvailable)
        XCTAssertEqual(value.transcriptError, "The input returned HTTP 429.")
        XCTAssertTrue(value.content.contains("Transcript unavailable for this podcast episode."))
        XCTAssertTrue(
            value.content.contains(
                "Automatic transcription could not be completed: The input returned HTTP 429."
            )
        )
        XCTAssertTrue(value.content.contains("Episode description."))
    }

    func testPodcastInputDiscoversFeedAndParsesPreferredVTTTranscript() async throws {
        let page = """
            <html><head>
            <meta property="og:title" content="Behind the Scenes | Apple Podcasts">
            <meta property="og:description" content="Episode page description">
            <link rel="canonical" href="https://inandaroundpodcasting.com/episode/behind-the-scenes">
            <link rel="alternate" type="application/rss+xml" href="/feed.xml">
            </head></html>
            """
        let feed = """
            <rss xmlns:podcastindex="https://podcastindex.org/namespace/1.0"><channel>
            <title>Native podcast show</title><item>
            <guid>https://inandaroundpodcasting.com/episode/behind-the-scenes</guid>
            <title>Behind the Scenes</title>
            <link>https://inandaroundpodcasting.com/episode/behind-the-scenes</link>
            <description><![CDATA[<p>Episode description.</p>]]></description>
            <enclosure url="https://cdn.example.org/episode.mp3" type="audio/mpeg"/>
            <podcastindex:transcript url="https://cdn.example.org/episode.txt" type="text/plain"/>
            <podcastindex:transcript url="https://cdn.example.org/episode.json" type="application/json"/>
            <podcastindex:transcript url="https://cdn.example.org/episode.vtt" type="text/vtt" language="en"/>
            </item></channel></rss>
            """
        let vtt = """
            WEBVTT

            00:00:00.000 --> 00:00:01.000
            <v Host>Hello there.</v>

            00:00:01.000 --> 00:00:02.000
            <v Guest>Native transcript.</v>
            """
        let value = try await router.ingest(
            .init(source: .url(itemTestURL(.podcast)), hints: .init(preferredInput: .podcast)),
            context: .init(http: fixtureHTTP([
                "inandaroundpodcasting.com/episode/behind-the-scenes": .text(page),
                "feed.xml": .text(feed, "application/rss+xml"),
                "episode.vtt": .text(vtt, "text/vtt")
            ]))
        )

        XCTAssertEqual(value.title, "Behind the Scenes")
        XCTAssertEqual(value.mediaURL?.absoluteString, "https://cdn.example.org/episode.mp3")
        XCTAssertEqual(value.transcriptLanguage, "en")
        XCTAssertTrue(value.content.contains("Host: Hello there."))
        XCTAssertTrue(value.content.contains("Guest: Native transcript."))
        XCTAssertFalse(value.content.contains("00:00:00"))
    }

    func testPodcastInputParsesStructuredJSONSpeakers() async throws {
        let media = URL(string: "https://cdn.example.org/json-episode.mp3")!
        let transcript = URL(string: "https://cdn.example.org/json-episode.json")!
        let json: [String: Any] = ["segments": [
            ["speaker": "Host", "body": "Welcome."],
            ["speaker": "Host", "body": "Let us begin."],
            ["speaker": "Guest", "body": "Thanks for having me."]
        ]]
        let value = try await router.ingest(
            .init(
                source: .url(itemTestURL(.podcast)),
                hints: .init(
                    preferredInput: .podcast,
                    title: "JSON episode",
                    mediaURL: media,
                    transcriptURL: transcript,
                    transcriptType: "application/json",
                    transcriptLanguage: "en"
                )
            ),
            context: .init(http: fixtureHTTP(["json-episode.json": .json(json)]))
        )

        XCTAssertTrue(value.transcriptAvailable)
        XCTAssertEqual(value.transcriptLanguage, "en")
        XCTAssertTrue(value.content.contains("Host: Welcome. Let us begin. Guest: Thanks for having me."))
    }

    func testRedditInput() async throws {
        let linkedURL = "https://news.example.org/native-reddit-story"
        let payload: [Any] = [
            ["data": ["children": [["kind": "t3", "data": [
                "title": "Native Reddit post", "author": "reader", "subreddit_name_prefixed": "r/native",
                "selftext": "", "url_overridden_by_dest": linkedURL,
                "permalink": "/r/IAmA/comments/z1c9z/i_am_barack_obama_president_of_the_united_states/"
            ]]]]],
            ["data": ["children": [["kind": "t1", "data": [
                "author": "commenter", "body": "Useful reply",
                "replies": ["data": ["children": [["kind": "t1", "data": [
                    "author": "nested", "body": "Nested reply"
                ]]]]]
            ]]]]]
        ]
        let value = try await router.ingest(
            .init(source: .url(itemTestURL(.reddit))),
            context: .init(http: fixtureHTTP([
                "comments/z1c9z.json": .json(payload),
                linkedURL: .text("""
                    <html><head><title>Linked report</title></head>
                    <body><main>Full linked article content with enough detail to be readable.</main></body></html>
                    """)
            ]))
        )
        XCTAssertEqual(value.inputID, .reddit)
        XCTAssertTrue(value.content.contains("Full linked article content"))
        XCTAssertTrue(value.content.contains("[Open linked content](\(linkedURL))"))
        XCTAssertTrue(value.content.contains("Useful reply"))
        XCTAssertTrue(value.content.contains("Nested reply"))
    }

    func testXInput() async throws {
        let longText = String(repeating: "x", count: 100)
        let value = try await router.ingest(
            .init(source: .url(itemTestURL(.x))),
            context: .init(http: fixtureHTTP(["api.fxtwitter.com/2/status/20": .json([
                "status": [
                    "id": "20", "raw_text": longText, "created_at": "today",
                    "likes": 1234, "reposts": 23,
                    "author": ["name": "Briefly", "screen_name": "briefly"],
                    "quote": ["text": "Quoted post", "author": ["screen_name": "quoted"]],
                    "twitter_card": ["url": "https://example.com/card"]
                ]
            ])]))
        )
        XCTAssertEqual(value.inputID, .x)
        XCTAssertEqual(
            value.title,
            "Post by Briefly (@briefly): \(String(longText.prefix(89)))…"
        )
        XCTAssertTrue(value.content.contains("1,234 likes"))
        XCTAssertTrue(value.content.contains("23 reposts"))
        XCTAssertTrue(value.content.contains("> @quoted: Quoted post"))
        XCTAssertTrue(value.content.contains("Link: https://example.com/card"))
    }

    func testXArticleInputRendersBlocksEntitiesAndMedia() async throws {
        let article: [String: Any] = [
            "title": " Native article \u{200B}",
            "preview_text": "A preview",
            "cover_media": ["media_info": [
                "original_img_url": "https://images.example/cover(hero).jpg"
            ]],
            "media_entities": [[
                "media_id": "media-1",
                "media_info": [
                    "original_img_url": "https://images.example/article(image).jpg"
                ]
            ]],
            "content": [
                "blocks": [
                    ["type": "header-two", "text": "Heading"],
                    [
                        "type": "unstyled", "text": "🙂 Bold link",
                        "inlineStyleRanges": [["offset": 3, "length": 4, "style": "BOLD"]],
                        "entityRanges": [["offset": 8, "length": 4, "key": 0]]
                    ],
                    [
                        "type": "unstyled", "text": "styled mono",
                        "inlineStyleRanges": [
                            ["offset": 0, "length": 2, "style": "ITALIC"],
                            ["offset": 2, "length": 2, "style": "STRIKETHROUGH"],
                            ["offset": 4, "length": 2, "style": "UNDERLINE"],
                            ["offset": 7, "length": 4, "style": "MONOSPACE"]
                        ]
                    ],
                    ["type": "unordered-list-item", "depth": 1, "text": "nested"],
                    ["type": "ordered-list-item", "text": "step"],
                    ["type": "blockquote", "text": "quoted\nline"],
                    ["type": "code-block", "text": "let x = ```"],
                    ["type": "atomic", "entityRanges": [["offset": 0, "length": 1, "key": 1]]]
                ],
                "entityMap": [
                    ["key": 0, "value": [
                        "type": "LINK", "data": ["url": "https://example.com/a(b)"]
                    ]],
                    ["key": 1, "value": [
                        "type": "MEDIA", "data": ["mediaItems": [["mediaId": "media-1"]]]
                    ]]
                ]
            ]
        ]
        let value = try await router.ingest(
            .init(source: .url(itemTestURL(.x))),
            context: .init(http: fixtureHTTP([
                "api.fxtwitter.com/2/status/20": .json(["status": [
                    "id": "20", "article": article
                ]])
            ]))
        )

        XCTAssertEqual(value.inputID, .x)
        XCTAssertEqual(value.title, "Native article")
        XCTAssertEqual(value.content, """
            ![Cover image](https://images.example/cover%28hero%29.jpg)

            ## Heading

            🙂 **Bold** [link](https://example.com/a%28b%29)

            _st_~~yl~~<u>ed</u> `mono`

              - nested

            1. step

            > quoted
            > line

            ````
            let x = ```
            ````

            ![Article image](https://images.example/article%28image%29.jpg)
            """)
    }

    func testBlueskyInput() async throws {
        let value = try await router.ingest(
            .init(source: .url(itemTestURL(.bluesky))),
            context: .init(http: fixtureHTTP([
                "resolveHandle": .json(["did": "did:plc:native"]),
                "getPostThread": .json(["thread": ["post": [
                    "record": [
                        "$type": "app.bsky.feed.post", "text": "Native Bluesky post", "createdAt": "today"
                    ],
                    "author": ["handle": "test.bsky.social", "displayName": "Tester"],
                    "likeCount": 2
                ]]])
            ]))
        )
        XCTAssertEqual(value.inputID, .bluesky)
        XCTAssertTrue(value.content.contains("Native Bluesky post"))
    }

    func testThreadsInput() async throws {
        let html = """
        <html><head><meta property="og:title" content="Native thread">
        <meta property="og:description" content="A native Threads post"></head></html>
        """
        let value = try await router.ingest(
            .init(source: .url(itemTestURL(.threads))),
            context: .init(http: fixtureHTTP(["threads.com/@zuck/post/C-srcchPpp7": .text(html)]))
        )
        XCTAssertEqual(value.inputID, .threads)
        XCTAssertTrue(value.content.contains("native Threads"))
    }

    func testTikTokInput() async throws {
        let value = try await router.ingest(
            .init(source: .url(itemTestURL(.tiktok))),
            context: .init(http: fixtureHTTP(["tiktok.com/oembed": .json([
                "title": " Native\nTikTok   caption ", "author_name": " Briefly ",
                "thumbnail_url": "https://example.com/thumb.jpg"
            ])]))
        )
        XCTAssertEqual(value.inputID, .tiktok)
        XCTAssertTrue(value.content.contains("Native TikTok caption"))
        XCTAssertTrue(value.content.contains("Thumbnail: https://example.com/thumb.jpg"))
    }

    func testGeneralPageInput() async throws {
        let html = """
        <html><head><title>Example Domain</title><link rel="canonical" href="https://example.com/"></head>
        <body><article><h1>Native web page</h1><p>This is the readable article body.</p></article></body></html>
        """
        let value = try await router.ingest(
            .init(source: .url(itemTestURL(.webPage))),
            context: .init(http: fixtureHTTP(["example.com": .text(html)]))
        )
        XCTAssertEqual(value.inputID, .webPage)
        XCTAssertTrue(value.content.contains("readable article body"))
        XCTAssertEqual(value.canonicalKey, "https://example.com/")
    }

    func testGeneralPageUsesJSONLDMetadataAndArticleBody() async throws {
        let articleBody = String(repeating: "JSON-LD article body with useful context. ", count: 5)
        let html = """
        <html><head>
        <title>Application shell</title>
        <link rel="apple-touch-icon" href="/touch-icon.png">
        <script type="application/ld+json">
        {"@graph":[{"@type":"Article","headline":"Structured native article",
        "articleBody":"\(articleBody)","description":"A structured description",
        "publisher":{"name":"Native Press"}}]}
        </script></head><body><div id="app">Structured native article</div></body></html>
        """
        let value = try await router.ingest(
            .init(source: .url(itemTestURL(.webPage))),
            context: .init(http: fixtureHTTP(["example.com": .text(html)]))
        )
        XCTAssertEqual(value.title, "Structured native article")
        XCTAssertTrue(value.content.contains("JSON-LD article body"))
        XCTAssertEqual(value.faviconURL?.absoluteString, "https://example.com/touch-icon.png")
    }

    func testGenericPageRejectsBinaryContent() async {
        do {
            _ = try await router.ingest(
                .init(source: .url(itemTestURL(.webPage))),
                context: .init(http: fixtureHTTP([
                    "example.com": .init(data: Data([0, 1, 2, 3]), contentType: "application/zip")
                ]))
            )
            XCTFail("Expected binary content to be rejected")
        } catch let error as NativeInputError {
            XCTAssertEqual(error, .unsupportedInput)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testRedirectToCredentialURLIsRejected() async {
        do {
            _ = try await router.ingest(
                .init(source: .url(itemTestURL(.webPage))),
                context: .init(http: InputHTTPClient { request, _ in
                    InputHTTPResponse(
                        data: Data("<main>Readable content</main>".utf8),
                        finalURL: URL(string: "https://user:secret@example.com/")!,
                        contentType: "text/html"
                    )
                })
            )
            XCTFail("Expected credential-bearing redirect to be rejected")
        } catch let error as NativeInputError {
            XCTAssertEqual(error, .invalidResponse)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testURLCredentialsAreRejected() async {
        do {
            _ = try await router.ingest(
                .init(source: .url(URL(string: "https://user:secret@example.com/")!)),
                context: .init(http: fixtureHTTP([:]))
            )
            XCTFail("Expected credentials to be rejected")
        } catch {}
    }

    func testPDFInput() async throws {
        let url = itemTestURL(.pdf)
        let value = try await router.ingest(
            .init(source: .url(url)),
            context: .init(http: fixtureHTTP([
                "rfc/rfc9110.pdf": .init(
                    data: fixturePDF(text: "Remote PDF", title: "Remote report"),
                    contentType: "application/pdf"
                )
            ]))
        )
        XCTAssertEqual(value.inputID, .pdf)
        XCTAssertEqual(value.sourceURL, url)
        XCTAssertTrue(value.content.contains("Remote PDF"))
    }

    func testSpecializedFailureUsesFirecrawlFallback() async throws {
        let url = itemTestURL(.x)
        let value = try await router.ingest(
            .init(source: .url(url)),
            context: .init(
                http: fixtureHTTP([:]),
                firecrawl: { url in
                    ItemDraft(
                        inputID: .webPage,
                        title: "Fallback capture",
                        content: "Fallback content",
                        sourceURL: url,
                        canonicalURL: url
                    )
                }
            )
        )
        XCTAssertEqual(value.inputID, .webPage)
        XCTAssertEqual(value.content, "Fallback content")
    }

    func testFirecrawlFallbackRejectsErrorShells() async {
        do {
            _ = try await router.ingest(
                .init(source: .url(itemTestURL(.webPage))),
                context: .init(
                    http: InputHTTPClient { request, _ in
                        InputHTTPResponse(
                            data: Data("blocked".utf8),
                            finalURL: request.url!,
                            statusCode: 403
                        )
                    },
                    firecrawl: { url in
                        ItemDraft(
                            inputID: .webPage,
                            title: "Checking your browser",
                            content: "Checking your browser",
                            sourceURL: url,
                            canonicalURL: url
                        )
                    }
                )
            )
            XCTFail("Expected Firecrawl error-shell content to be rejected")
        } catch let error as NativeInputError {
            XCTAssertEqual(error, .requestFailed(403))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}

#if os(macOS)
@MainActor
private final class OpenRouterBrowserFixture {
    var denied = false
    var callback: URL?
    var challenge: String?
    var requests: Task<Void, Error>?
    var pendingSignIn: Task<String, Error>?

    func open(_ url: URL) -> Bool {
        XCTAssertEqual(url.scheme, "https")
        XCTAssertEqual(url.host, "openrouter.ai")
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertNil(items.first { $0.name == "code_verifier" })
        XCTAssertEqual(items.first { $0.name == "code_challenge_method" }?.value, "S256")
        challenge = items.first { $0.name == "code_challenge" }?.value
        guard let value = items.first(where: { $0.name == "callback_url" })?.value,
              let callback = URL(string: value) else { return false }
        self.callback = callback
        XCTAssertEqual(callback.host, "127.0.0.1")
        requests = Task { @MainActor in
            var components = URLComponents(url: callback, resolvingAgainstBaseURL: false)!
            if denied {
                components.queryItems = [URLQueryItem(name: "error", value: "access_denied")]
                let (body, response) = try await URLSession.shared.data(from: components.url!)
                XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
                XCTAssertTrue(String(decoding: body, as: UTF8.self).contains("Authorization was declined"))
                return
            }
            components.path += "/unrelated"
            components.queryItems = [URLQueryItem(name: "code", value: "wrong-session")]
            let (_, unrelated) = try await URLSession.shared.data(from: components.url!)
            XCTAssertEqual((unrelated as? HTTPURLResponse)?.statusCode, 400)
            components.path = callback.path
            components.queryItems = [URLQueryItem(name: "code", value: "one"), URLQueryItem(name: "code", value: "two")]
            let (_, duplicate) = try await URLSession.shared.data(from: components.url!)
            XCTAssertEqual((duplicate as? HTTPURLResponse)?.statusCode, 400)
            components.queryItems = [URLQueryItem(name: "code", value: "authorized-code")]
            let (body, accepted) = try await URLSession.shared.data(from: components.url!)
            XCTAssertEqual((accepted as? HTTPURLResponse)?.statusCode, 200)
            XCTAssertFalse(String(decoding: body, as: UTF8.self).contains("authorized-code"))
        }
        return true
    }

    func exchange(_ request: URLRequest) throws -> InputHTTPResponse {
        XCTAssertEqual(request.url?.absoluteString, "https://openrouter.ai/api/v1/auth/keys")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        let data = try XCTUnwrap(request.httpBody)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: String])
        XCTAssertEqual(payload["code"], "authorized-code")
        XCTAssertEqual(payload["code_challenge_method"], "S256")
        let verifier = try XCTUnwrap(payload["code_verifier"])
        XCTAssertEqual(verifier.utf8.count, 43)
        let actual = Data(SHA256.hash(data: Data(verifier.utf8))).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        XCTAssertEqual(actual, challenge)
        return InputHTTPResponse(data: Data(#"{"key":"test-openrouter-key"}"#.utf8), finalURL: request.url!)
    }
}
#endif

@MainActor
final class NativeChannelInputTests: XCTestCase {
    private let router = NativeChannelInputRouter()

    func testChannelRefreshPreservesDecisionsAndCloudDocumentState() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "channel-sync-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SQLiteLibraryStore(databaseURL: root.appending(path: "local.sqlite3"))
        let database = try await store.documentDatabase()
        let source = "https://example.com/feed.xml"
        let storyURL = URL(string: "https://example.com/story")!
        let batch = ChannelInputBatch(inputID: .feed, title: "Feed", kind: .feed, items: [
            .init(id: "original-feed-id", title: "Story", url: storyURL),
            .init(id: "rejected", title: "Rejected", url: URL(string: "https://example.com/rejected")!)
        ])
        try await store.addChannel(source)
        _ = try await store.checkChannelInput(source) { _ in batch }
        let document = try database.createDocument(
            title: "Story", body: "Full story", texts: [.source: "Full story", .concise: "Summary"],
            sourceURL: storyURL.absoluteString
        )
        try database.acknowledgeOutbox(documentID: document.id, revision: document.revision)

        let refreshed = try await store.checkChannelInput(source) { _ in
            _ = try await store.acceptChannelItem(channelID: source, itemID: "original-feed-id") { _ in
                document.id
            }
            try await store.rejectChannelItem(channelID: source, itemID: "rejected")
            try await store.updateChannel(source, reviewLimit: 3, schedule: "daily 08:30")
            return batch
        }
        XCTAssertTrue(refreshed.channel.items.isEmpty)
        XCTAssertEqual(refreshed.channel.reviewLimit, 3)
        XCTAssertEqual(refreshed.channel.schedule, "daily 08:30")
        XCTAssertEqual(try database.channelSources(documentID: document.id), [source])
        XCTAssertTrue(try database.outbox().contains {
            $0.recordType == "document" && $0.documentID == document.id && $0.revision > document.revision
        })

        let otherStore = SQLiteLibraryStore(databaseURL: root.appending(path: "remote.sqlite3"))
        let otherDatabase = try await otherStore.documentDatabase()
        var remote = try database.getDocument(document.id)
        try otherDatabase.applyRemote(remote)
        remote.texts.removeValue(forKey: .concise)
        remote.revision += 1
        try otherDatabase.applyRemote(remote)
        try otherDatabase.restoreCloudChannelSources([source], for: document.id)
        let synced = try await otherStore.checkChannelInput(source) { _ in
            ChannelInputBatch(inputID: .feed, title: "Feed", kind: .feed, items: [batch.items[0]])
        }
        XCTAssertTrue(synced.channel.items.isEmpty)
        XCTAssertNil(try otherDatabase.getDocument(document.id).texts[.concise])
        XCTAssertTrue(try otherDatabase.search("Summary").isEmpty)
        XCTAssertTrue(try otherDatabase.outbox().allSatisfy { $0.recordType != "document" })

        do {
            _ = try await store.checkChannelInput(source) { _ in
                try await store.removeChannel(source)
                return batch
            }
            XCTFail("A deleted channel must not be restored by a completed refresh")
        } catch LibraryError.missingChannel {}
        let remaining = try await store.loadChannels()
        XCTAssertTrue(remaining.isEmpty)
        XCTAssertEqual(try database.getDocument(document.id).texts[.source], "Full story")
    }

    func testEveryChannelInputHasARealTestURL() {
        assertRealTestURLs(
            realChannelTestURLs.map { ($0.0.rawValue, $0.1) },
            expectedIDs: ChannelInputID.allCases.map(\.rawValue)
        )
    }

    func testFeedChannelInput() async throws {
        let batch = try await enumerate(
            channelTestURL(.feed).absoluteString,
            fixtures: ["hnrss.org/frontpage": .text(feedXML(), "application/rss+xml")]
        )
        XCTAssertEqual(batch.inputID, .feed)
        XCTAssertEqual(batch.items.first?.title, "Native story")
    }

    func testFeedDiscoveryTriesAllAlternateCandidates() async throws {
        let html = """
        <html><head>
        <link rel="alternate" type="application/rss+xml" href="/broken.xml">
        <link rel="alternate" type="application/atom+xml" href="/working.xml">
        </head><body>Feed landing page</body></html>
        """
        let batch = try await enumerate(
            "https://example.com/news",
            fixtures: [
                "example.com/news": .text(html),
                "example.com/working.xml": .text(feedXML(), "application/atom+xml")
            ]
        )
        XCTAssertEqual(batch.inputID, .feed)
        XCTAssertEqual(batch.items.first?.title, "Native story")
    }

    func testAtomFeedUsesAlternateLinkAndNormalizesDate() async throws {
        let atom = """
        <feed><title>Native Atom</title><entry><id>entry-1</id><title>Atom story</title>
        <link rel="self" href="https://example.com/feed.xml"/>
        <link rel="alternate" href="/stories/atom-story"/>
        <updated>2026-06-01T10:00:00.123Z</updated></entry></feed>
        """
        let batch = try await enumerate(
            "https://example.com/feed.xml",
            fixtures: ["example.com/feed.xml": .text(atom, "application/atom+xml")]
        )
        XCTAssertEqual(batch.items.first?.url.absoluteString, "https://example.com/stories/atom-story")
        XCTAssertEqual(batch.items.first?.publishedAt, "2026-06-01T10:00:00.123Z")
    }

    func testArxivQueryChannelInput() async throws {
        let atom = """
        <feed><title>Search results</title><entry><id>https://arxiv.org/abs/1706.03762</id>
        <title>Attention Is All You Need</title><link href="https://arxiv.org/abs/1706.03762"/>
        <published>2026-06-01T10:00:00Z</published></entry></feed>
        """
        let batch = try await enumerate(
            "arxiv:transformers",
            fixtures: ["export.arxiv.org/api/query": .text(atom, "application/atom+xml")]
        )
        XCTAssertEqual(batch.inputID, .arxiv)
        XCTAssertEqual(batch.items.first?.hints.preferredInput, .arxiv)
    }

    func testArxivSearchURLChannelEnumeratesPapersForMarkxivIngestion() async throws {
        let atom = """
        <feed><title>Biomedical search</title><entry><id>https://arxiv.org/abs/2606.07677</id>
        <title>Rare disease pathways</title><link href="https://arxiv.org/abs/2606.07677"/>
        <published>2026-06-01T10:00:00Z</published></entry></feed>
        """
        let requests = URLLog()
        let source = "https://arxiv.org/search/?query=%22rare+disease%22+AND+pathway" +
            "&searchtype=all&order=-announced_date_first"
        let batch = try await router.enumerate(
            source: source,
            context: .init(http: InputHTTPClient { request, _ in
                await requests.append(request.url!)
                return InputHTTPResponse(
                    data: Data(atom.utf8),
                    finalURL: request.url!,
                    contentType: "application/atom+xml"
                )
            })
        )

        XCTAssertEqual(batch.inputID, .arxiv)
        XCTAssertEqual(batch.items.first?.url.absoluteString, "https://arxiv.org/abs/2606.07677")
        XCTAssertEqual(batch.items.first?.hints.preferredInput, .arxiv)
        let requestedURLs = await requests.values
        let requestedURL = try XCTUnwrap(requestedURLs.first)
        let searchQuery = URLComponents(url: requestedURL, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "search_query" }?.value
        XCTAssertEqual(searchQuery, #"all:"rare disease" AND all:pathway"#)
    }

    func testPageChannelFallsBackToRenderedResultsAfterHTTP429() async throws {
        let renders = AttemptCounter()
        let source = "https://example.com/rate-limited-channel"
        let paper = URL(string: "https://www.biorxiv.org/content/10.1101/2026.08.01.123456v1")!
        let batch = try await router.enumerate(
            source: source,
            context: .init(
                http: InputHTTPClient { request, _ in
                    InputHTTPResponse(
                        data: Data("rate limited".utf8),
                        finalURL: request.url!,
                        statusCode: 429
                    )
                },
                render: { _, _ in
                    _ = await renders.increment()
                    return ChannelInputBatch(
                        inputID: .page,
                        title: "Search Results | bioRxiv",
                        kind: .page,
                        items: [.init(
                            id: "10.1101/2026.08.01.123456v1",
                            title: "Rare disease pathways",
                            url: paper,
                            hints: .init(preferredInput: .biorxiv)
                        )]
                    )
                }
            )
        )

        let renderCount = await renders.value
        XCTAssertEqual(renderCount, 1)
        XCTAssertEqual(batch.items.first?.url, paper)
        XCTAssertEqual(batch.items.first?.hints.preferredInput, .biorxiv)
    }

    func testBiorxivSearchChannelUsesStructuredPreprintResults() async throws {
        let response: [String: Any] = [
            "resultList": ["result": [[
                "doi": "10.1101/2026.08.01.123456",
                "title": "Rare disease pathways",
                "firstPublicationDate": "2026-08-01",
                "abstractText": "A complete pathway study."
            ]]]
        ]
        let source = "https://www.biorxiv.org/search/%22rare%20disease%22%20AND%20pathway%20" +
            "numresults%3A50%20sort%3Apublication-date%20direction%3Adescending"
        let batch = try await enumerate(
            source,
            fixtures: ["ebi.ac.uk/europepmc/webservices/rest/search": .json(response)]
        )

        XCTAssertEqual(batch.inputID, .biorxiv)
        XCTAssertEqual(
            batch.items.first?.url.absoluteString,
            "https://www.biorxiv.org/content/10.1101/2026.08.01.123456"
        )
        XCTAssertEqual(batch.items.first?.hints.preferredInput, .biorxiv)
        XCTAssertEqual(batch.items.first?.hints.content, "A complete pathway study.")
    }

    func testYouTubeChannelInput() async throws {
        let atom = """
        <feed><title>Google for Developers</title><entry><id>yt:video:jNQXAC9IVRw</id><title>Me at the zoo</title>
        <link href="https://www.youtube.com/watch?v=jNQXAC9IVRw"/><published>2005-04-24T03:31:52Z</published></entry></feed>
        """
        let batch = try await enumerate(
            channelTestURL(.youtube).absoluteString,
            fixtures: ["feeds/videos.xml": .text(atom, "application/atom+xml")]
        )
        XCTAssertEqual(batch.inputID, .youtube)
        XCTAssertEqual(batch.items.first?.hints.preferredInput, .youtube)
    }

    func testPodcastChannelInput() async throws {
        let podcast = """
        <rss><channel><title>In &amp; Around Podcasting</title><item><guid>behind-the-scenes</guid><title>Behind the Scenes</title>
        <link>\(itemTestURL(.podcast).absoluteString)</link><description>Why we created the show.</description>
        <enclosure url="https://traffic.libsyn.com/atpfm/atp300.mp3" type="audio/mpeg"/>
        </item></channel></rss>
        """
        let batch = try await enumerate(
            channelTestURL(.podcast).absoluteString,
            fixtures: [
                "feeds.truefans.fm/rss/6750170d97d4af53ccbaec06": .text(podcast, "application/rss+xml")
            ]
        )
        XCTAssertEqual(batch.inputID, .podcast)
        XCTAssertEqual(batch.items.first?.url, itemTestURL(.podcast))
        XCTAssertEqual(batch.items.first?.hints.mediaURL?.absoluteString, "https://traffic.libsyn.com/atpfm/atp300.mp3")
    }

    func testPodcastChannelUsesAudioWhenEpisodeHasNoWebLink() async throws {
        let podcast = """
        <rss xmlns:podcast="https://podcastindex.org/namespace/1.0"><channel><title>Audio-only feed</title><item>
        <guid>episode-without-page</guid><title>Audio-only episode</title>
        <enclosure url="https://cdn.example.org/episode.mp3" type="audio/mpeg"/>
        <podcast:transcript url="https://cdn.example.org/episode.txt" type="text/plain"/>
        <podcast:transcript url="https://cdn.example.org/episode.vtt" type="text/vtt"/>
        </item></channel></rss>
        """
        let batch = try await enumerate(
            "https://feeds.example.org/podcast.xml",
            fixtures: ["feeds.example.org/podcast.xml": .text(podcast, "application/rss+xml")]
        )
        XCTAssertEqual(batch.inputID, .podcast)
        XCTAssertEqual(batch.items.first?.url.absoluteString, "https://cdn.example.org/episode.mp3")
        XCTAssertEqual(batch.items.first?.hints.mediaURL?.absoluteString, "https://cdn.example.org/episode.mp3")
        XCTAssertEqual(batch.items.first?.hints.transcriptURL?.absoluteString, "https://cdn.example.org/episode.vtt")
    }

    func testPodcastNamespaceMarksFeedAsPodcastWithoutAudioEnclosure() async throws {
        let podcast = """
        <rss xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd"><channel><title>Native show</title><item>
        <guid>episode-1</guid><title>Native episode</title><link>https://example.com/episode</link>
        <itunes:summary>Episode summary.</itunes:summary>
        </item></channel></rss>
        """
        let batch = try await enumerate(
            "https://example.com/podcast.xml",
            fixtures: ["example.com/podcast.xml": .text(podcast, "application/rss+xml")]
        )
        XCTAssertEqual(batch.inputID, .podcast)
        XCTAssertEqual(batch.items.first?.hints.preferredInput, .podcast)
    }

    func testRedditCommunityChannelInput() async throws {
        let batch = try await enumerate(
            channelTestURL(.reddit).absoluteString,
            fixtures: ["/r/swift/.rss": .text(
                feedXML(itemURL: itemTestURL(.reddit).absoluteString),
                "application/atom+xml"
            )]
        )
        XCTAssertEqual(batch.inputID, .reddit)
        XCTAssertEqual(batch.items.first?.hints.preferredInput, .reddit)
        XCTAssertEqual(batch.items.first?.id, "reddit-linked-content-v2:native-1")
    }

    func testXProfileChannelInput() async throws {
        let fullText = "A complete long X post that continues beyond the text shown on the profile page."
        let context = ChannelInputContext(http: fixtureHTTP([
            "api.fxtwitter.com/2/profile/openai/statuses": .json([
                "results": [[
                    "type": "status",
                    "id": "123456",
                    "text": fullText,
                    "raw_text": ["text": fullText],
                    "created_at": "Fri Aug 01 12:00:00 +0000 2026",
                    "likes": 42,
                    "author": ["name": "OpenAI", "screen_name": "openai"]
                ]]
            ])
        ]))
        let batch = try await router.enumerate(
            source: channelTestURL(.x).absoluteString,
            context: context
        )
        XCTAssertEqual(batch.inputID, .x)
        XCTAssertEqual(batch.items.first?.id, "123456")
        XCTAssertEqual(batch.items.first?.hints.preferredInput, .x)
        XCTAssertTrue(batch.items.first?.hints.content?.contains(fullText) == true)
        XCTAssertFalse(batch.items.first?.hints.content?.contains("Show more") == true)
    }

    func testArxivChannelInput() async throws {
        let atom = """
        <feed><title>cs.AI</title><entry><id>https://arxiv.org/abs/1706.03762</id><title>Attention Is All You Need</title>
        <link href="https://arxiv.org/abs/1706.03762"/><updated>2023-08-02T00:00:00Z</updated></entry></feed>
        """
        let batch = try await enumerate(
            channelTestURL(.arxiv).absoluteString,
            fixtures: ["export.arxiv.org/api/query": .text(atom, "application/atom+xml")]
        )
        XCTAssertEqual(batch.inputID, .arxiv)
        XCTAssertEqual(batch.items.first?.hints.preferredInput, .arxiv)
    }

    func testHackerNewsChannelInput() async throws {
        let html = """
        <html><table><tr class="athing" id="8863"><td><span class="titleline">
        <a href="/item?id=8863">My YC app: Dropbox &amp; more</a></span></td></tr></table></html>
        """
        let batch = try await enumerate(
            channelTestURL(.hackerNews).absoluteString,
            fixtures: ["news.ycombinator.com": .text(html)]
        )
        XCTAssertEqual(batch.inputID, .hackerNews)
        XCTAssertEqual(batch.items.first?.id, "8863")
        XCTAssertEqual(batch.items.first?.url.absoluteString, "https://news.ycombinator.com/item?id=8863")
        XCTAssertEqual(batch.items.first?.title, "My YC app: Dropbox & more")
    }

    func testPageWatcherChannelInputUsesContentHash() async throws {
        let first = try await enumerate(
            channelTestURL(.page).absoluteString,
            fixtures: ["example.com": .text("<title>Example Domain</title><main>First native version</main>")]
        )
        let second = try await enumerate(
            channelTestURL(.page).absoluteString,
            fixtures: ["example.com": .text("<title>Example Domain</title><main>Second native version</main>")]
        )
        XCTAssertEqual(first.inputID, .page)
        XCTAssertNotEqual(first.items.first?.id, second.items.first?.id)
        XCTAssertEqual(first.items.first?.url, channelTestURL(.page))
    }

    private func enumerate(
        _ source: String,
        fixtures: [String: Fixture]
    ) async throws -> ChannelInputBatch {
        try await router.enumerate(
            source: source,
            context: .init(http: fixtureHTTP(fixtures))
        )
    }
}

@MainActor
final class LiveInputURLTests: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        guard ProcessInfo.processInfo.environment["BRIEFLY_RUN_LIVE_TESTS"] == "1" else {
            throw XCTSkip("Set BRIEFLY_RUN_LIVE_TESTS=1 to run live network tests.")
        }
    }

    func testTextItemIngestsLiveContent() async throws {
        let draft = try await assertLiveItem(.text, contains: ["HTTP Semantics", "IANA Considerations"])
        XCTAssertTrue(draft.title.contains("Internet Engineering Task Force"))
        XCTAssertFalse(draft.title.contains("\u{FEFF}"))
        XCTAssertGreaterThan(draft.content.count, 400_000)
    }

    func testPDFItemIngestsLiveContent() async throws {
        let draft = try await assertLiveItem(.pdf, contains: ["HTTP Semantics", "IANA Considerations"])
        XCTAssertGreaterThan(draft.content.count, 400_000)
    }

    func testArxivItemIngestsLiveContent() async throws {
        let draft = try await assertLiveItem(
            .arxiv,
            contains: ["Attention Is All You Need", "English Constituency Parsing"]
        )
        XCTAssertGreaterThan(draft.content.count, 40_000)
    }

    func testBiorxivItemIngestsLiveContent() async throws {
        let draft = try await assertLiveItem(
            .biorxiv,
            contains: ["MSstatsBioNet", "quantitative proteomics"]
        )
        XCTAssertGreaterThan(draft.content.count, 20_000)
    }

    func testYouTubeItemIngestsLiveContent() async throws {
        let draft = try await assertLiveItem(
            .youtube,
            contains: ["in front of the\nelephants", "pretty much all there is to\nsay"]
        )
        XCTAssertTrue(draft.transcriptAvailable)
        XCTAssertGreaterThan(draft.content.count, 200)
    }

    func testPodcastItemIngestsLiveContent() async throws {
        let draft = try await assertLiveItem(
            .podcast,
            hints: .init(preferredInput: .podcast),
            contains: ["Hello and welcome to this bonus episode", "their chance to shine"]
        )
        XCTAssertTrue(draft.transcriptAvailable)
        XCTAssertGreaterThan(draft.content.count, 30_000)
    }

    func testRedditItemIngestsLiveContent() async throws {
        let draft = try await assertLiveItem(
            .reddit,
            contains: [
                "Ask me anything", "NOT BAD!", "## Top comments",
                "He said he would do an AMA for 30 min"
            ]
        )
        XCTAssertGreaterThan(draft.content.count, 5_000)
    }

    func testXItemIngestsLiveContent() async throws {
        try await assertLiveItem(.x, contains: ["just setting up my twttr"])
    }

    func testBlueskyItemIngestsLiveContent() async throws {
        let draft = try await assertLiveItem(.bluesky, contains: ["Verification update"])
        XCTAssertGreaterThan(draft.content.count, 400)
    }

    func testThreadsItemIngestsLiveContent() async throws {
        try await assertLiveItem(.threads, contains: ["post insights", "multiple drafts"])
    }

    func testTikTokItemIngestsLiveContent() async throws {
        try await assertLiveItem(.tiktok, contains: ["Scramble up ur name"])
    }

    func testWebPageItemIngestsLiveContent() async throws {
        try await assertLiveItem(.webPage, contains: ["Example Domain", "documentation examples"])
    }

    func testFeedChannelDiscoversAndIngestsLiveItem() async throws {
        try await assertLiveChannel(.feed, contains: ["Hacker News"])
    }

    func testYouTubeChannelDiscoversAndIngestsLiveItem() async throws {
        let draft = try await assertLiveChannel(.youtube, contains: ["Google"])
        XCTAssertEqual(draft.inputID, .youtube)
        XCTAssertTrue(draft.transcriptAvailable)
    }

    func testPodcastChannelDiscoversAndIngestsLiveItem() async throws {
        let draft = try await assertLiveChannel(.podcast, contains: ["Podcasting 2.0 in Practice"])
        XCTAssertEqual(draft.inputID, .podcast)
        XCTAssertTrue(draft.transcriptAvailable)
        XCTAssertGreaterThan(draft.content.count, 5_000)
    }

    func testRedditChannelDiscoversAndIngestsLiveItem() async throws {
        try await assertLiveChannel(.reddit, contains: ["Swift"])
    }

    func testXChannelDiscoversAndIngestsLiveItem() async throws {
        try await assertLiveChannel(.x, contains: ["OpenAI"])
    }

    func testArxivChannelDiscoversAndIngestsLiveItem() async throws {
        let draft = try await assertLiveChannel(.arxiv, contains: ["cs.AI"])
        XCTAssertEqual(draft.inputID, .arxiv)
        XCTAssertGreaterThan(draft.content.count, 10_000)
    }

    func testBiorxivChannelDiscoversAndIngestsLiveItem() async throws {
        let draft = try await assertLiveChannel(.biorxiv, contains: ["bioRxiv"])
        XCTAssertEqual(draft.inputID, .biorxiv)
        XCTAssertGreaterThan(draft.content.count, 1_000)
    }

    func testHackerNewsChannelDiscoversAndIngestsLiveItem() async throws {
        try await assertLiveChannel(.hackerNews, contains: ["Hacker News"])
    }

    func testPageChannelDiscoversAndIngestsLiveItem() async throws {
        try await assertLiveChannel(.page, contains: ["Example Domain"])
    }

    @discardableResult
    private func assertLiveItem(
        _ id: ItemInputID,
        hints: ItemInputHints = .init(),
        contains expected: [String]
    ) async throws -> ItemDraft {
        let draft = try await NativeItemInputRouter().ingest(
            .init(source: .url(itemTestURL(id)), hints: hints)
        )
        XCTAssertEqual(draft.inputID, id)
        let output = "\(draft.title)\n\(draft.content)"
        XCTAssertGreaterThan(draft.content.trimmingCharacters(in: .whitespacesAndNewlines).count, 20)
        for value in expected {
            XCTAssertTrue(
                output.localizedCaseInsensitiveContains(value),
                "\(id.rawValue) did not ingest expected live content ‘\(value)’\n\(output.prefix(1_000))"
            )
        }
        return draft
    }

    @discardableResult
    private func assertLiveChannel(
        _ id: ChannelInputID,
        contains expected: [String]
    ) async throws -> ItemDraft {
        let batch = try await NativeChannelInputRouter().enumerate(
            source: channelTestURL(id).absoluteString,
            maximumItems: 3
        )
        XCTAssertEqual(batch.inputID, id)
        let item = try XCTUnwrap(batch.items.first)
        let discovery = ([batch.title] + batch.items.map(\.title)).joined(separator: "\n")
        for value in expected {
            XCTAssertTrue(
                discovery.localizedCaseInsensitiveContains(value),
                "\(id.rawValue) did not discover expected live content ‘\(value)’\n\(discovery)"
            )
        }
        let draft = try await NativeItemInputRouter().ingest(
            .init(source: .url(item.url), hints: item.hints)
        )
        XCTAssertFalse(draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        XCTAssertGreaterThan(
            draft.content.trimmingCharacters(in: .whitespacesAndNewlines).count,
            20,
            "\(id.rawValue) discovered \(item.url), but item ingestion returned no real content"
        )
        return draft
    }

}

private func itemTestURL(_ id: ItemInputID) -> URL {
    realItemTestURLs.first { $0.0 == id }!.1
}

private func channelTestURL(_ id: ChannelInputID) -> URL {
    realChannelTestURLs.first { $0.0 == id }!.1
}

private func assertRealTestURLs(
    _ registrations: [(String, URL)],
    expectedIDs: [String],
    file: StaticString = #filePath,
    line: UInt = #line
) {
    XCTAssertEqual(
        registrations.map(\.0).sorted(),
        expectedIDs.sorted(),
        "Every input must have exactly one test URL",
        file: file,
        line: line
    )
    XCTAssertEqual(
        Set(registrations.map { $0.1.absoluteString }).count,
        registrations.count,
        "Test URLs must be unique within each input family",
        file: file,
        line: line
    )
    for (_, url) in registrations {
        let host = url.host?.lowercased() ?? ""
        XCTAssertEqual(url.scheme, "https", "Test URLs must use HTTPS: \(url)", file: file, line: line)
        XCTAssertNil(url.user, "Test URLs cannot contain credentials: \(url)", file: file, line: line)
        XCTAssertNil(url.password, "Test URLs cannot contain credentials: \(url)", file: file, line: line)
        XCTAssertTrue(host.contains("."), "Test URLs need a public host: \(url)", file: file, line: line)
        XCTAssertFalse(
            host == "localhost" || host.hasSuffix(".test") || host.hasSuffix(".invalid"),
            "Placeholder test URL is forbidden: \(url)",
            file: file,
            line: line
        )
    }
}

private struct Fixture: Sendable {
    let data: Data
    let contentType: String

    static func text(_ value: String, _ contentType: String = "text/html") -> Self {
        .init(data: Data(value.utf8), contentType: contentType)
    }

    static func json(_ value: Any) -> Self {
        .init(
            data: try! JSONSerialization.data(withJSONObject: value),
            contentType: "application/json"
        )
    }
}

private enum FixtureError: Error { case missing(String) }

private actor AttemptCounter {
    private(set) var value = 0

    func increment() -> Int {
        value += 1
        return value
    }
}

private actor URLLog {
    private(set) var values = [URL]()

    func append(_ value: URL) {
        values.append(value)
    }
}

private func fixtureHTTP(_ fixtures: [String: Fixture]) -> InputHTTPClient {
    InputHTTPClient { request, maximumBytes in
        let value = request.url!.absoluteString
        guard let fixture = fixtures.sorted(by: { $0.key.count > $1.key.count })
            .first(where: { value.contains($0.key) })?.value else {
            throw FixtureError.missing(value)
        }
        guard fixture.data.count <= maximumBytes else { throw NativeInputError.responseTooLarge }
        return InputHTTPResponse(
            data: fixture.data,
            finalURL: request.url!,
            contentType: fixture.contentType
        )
    }
}

private func feedXML(itemURL: String = "https://example.com/") -> String {
    """
    <rss><channel><title>Native feed</title><item><guid>native-1</guid><title>Native story</title>
    <link>\(itemURL)</link><description>Native summary</description>
    <pubDate>Mon, 01 Jun 2026 10:00:00 +0000</pubDate></item></channel></rss>
    """
}

private func fixturePDF(text: String, title: String) -> Data {
    let stream = "BT /F1 18 Tf 72 720 Td (\(text)) Tj ET"
    let objects = [
        "<< /Type /Catalog /Pages 2 0 R >>",
        "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>",
        "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
        "<< /Length \(stream.utf8.count) >>\nstream\n\(stream)\nendstream",
        "<< /Title (\(title)) >>"
    ]
    var pdf = "%PDF-1.4\n"
    var offsets = [0]
    for (index, object) in objects.enumerated() {
        offsets.append(pdf.utf8.count)
        pdf += "\(index + 1) 0 obj\n\(object)\nendobj\n"
    }
    let xref = pdf.utf8.count
    pdf += "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
    pdf += offsets.dropFirst().map { String(format: "%010d 00000 n \n", $0) }.joined()
    pdf += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R /Info 6 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
    return Data(pdf.utf8)
}
