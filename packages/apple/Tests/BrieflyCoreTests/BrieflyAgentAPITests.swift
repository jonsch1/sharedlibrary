import XCTest
@testable import BrieflyCore

final class BrieflyAgentAPITests: XCTestCase {
    func testLocalAgentBoundarySearchesAndReadsSummariesWithoutExposingSource() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "briefly-agent-\(UUID())", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let store = SQLiteLibraryStore(databaseURL: root.appending(path: "library.sqlite3"))
        let database = try await store.documentDatabase()
        let detailed = "Detailed compact interface. " + String(repeating: "x", count: 12_100)
        let ready = try database.createDocument(
            title: "Minimal agent interface",
            body: "classified-source-token",
            texts: [
                .source: "classified-source-token",
                .concise: "A compact interface keeps agent context small.",
                .detailed: detailed
            ],
            addToOutbox: false
        )
        let pending = try database.createDocument(
            title: "Pending capture",
            body: "Source text that is not an agent summary.",
            addToOutbox: false
        )
        let agent = BrieflyAgentLibrary(store: store)

        #if os(macOS)
        let socketURL = URL(filePath: "/tmp/briefly-agent-\(UUID().uuidString).sock")
        let server = BrieflyAgentSocketServer(socketURL: socketURL) { call in
            do {
                switch call.op {
                case "save":
                    guard let request = call.save else {
                        throw BrieflyAgentFailure.invalid("Missing save request.")
                    }
                    return BrieflyAgentReply(save: try await agent.save(request))
                case "search":
                    guard let request = call.search else {
                        throw BrieflyAgentFailure.invalid("Missing search request.")
                    }
                    return BrieflyAgentReply(search: try await agent.search(request))
                case "read":
                    guard let request = call.read else {
                        throw BrieflyAgentFailure.invalid("Missing read request.")
                    }
                    return BrieflyAgentReply(read: try await agent.read(request))
                default:
                    return BrieflyAgentReply(error: .invalid("Unsupported test operation."))
                }
            } catch let failure as BrieflyAgentFailure {
                return BrieflyAgentReply(error: failure)
            } catch {
                return BrieflyAgentReply(error: .init(code: "failed", message: "Test failure."))
            }
        }
        try server.start()
        defer { server.stop() }
        let client = BrieflyAgentSocketClient(socketURL: socketURL)

        let suppliedURL = "https://unavailable.example/agent-extracted-document"
        let saved = try await client.call(BrieflyAgentCall(
            op: "save",
            save: .init(
                title: "Agent extracted document",
                content: "Source supplied entirely by the agent.",
                url: suppliedURL,
                concise: "Agent supplied concise summary.",
                detailed: "Agent supplied detailed summary."
            )
        ))
        let savedID = try XCTUnwrap(saved.save?.id)
        XCTAssertEqual(saved.save?.status, "ready")
        let savedConcise = try await client.call(BrieflyAgentCall(
            op: "read",
            read: .init(id: savedID)
        ))
        XCTAssertEqual(savedConcise.read?.text, "Agent supplied concise summary.")
        let savedDetailed = try await client.call(BrieflyAgentCall(
            op: "read",
            read: .init(id: savedID, detail: true)
        ))
        XCTAssertEqual(savedDetailed.read?.text, "Agent supplied detailed summary.")
        let stored = try await store.getDocument(savedID)
        XCTAssertEqual(stored.texts[.source], "Source supplied entirely by the agent.")
        XCTAssertEqual(stored.sourceURL, suppliedURL)
        let noQueuedJob = try await store.claimNextProcessingJob()
        XCTAssertNil(noQueuedJob)

        let updated = try await client.call(BrieflyAgentCall(
            op: "save",
            save: .init(
                title: "Updated agent document",
                content: "Updated source supplied by the agent.",
                url: suppliedURL
            )
        ))
        XCTAssertEqual(updated.save?.id, savedID)
        XCTAssertEqual(updated.save?.status, "processing")
        let updatedRead = try await client.call(BrieflyAgentCall(
            op: "read",
            read: .init(id: savedID)
        ))
        XCTAssertEqual(updatedRead.read?.status, "processing")
        let queuedJob = try await store.claimNextProcessingJob()
        XCTAssertEqual(queuedJob?.documentID, savedID)

        let hiddenSource = try await client.call(BrieflyAgentCall(
            op: "search",
            search: .init(q: "classified-source-token")
        ))
        XCTAssertEqual(hiddenSource.search?.items, [])

        let found = try await client.call(BrieflyAgentCall(
            op: "search",
            search: .init(q: "compact interface")
        ))
        XCTAssertEqual(found.search?.items.first?.id, ready.id)
        XCTAssertTrue(found.search?.items.first?.snippet?.contains("compact interface") == true)

        let firstChunk = try await client.call(BrieflyAgentCall(
            op: "read",
            read: .init(id: ready.id, detail: true)
        ))
        XCTAssertEqual(firstChunk.read?.text?.count, 12_000)
        XCTAssertEqual(firstChunk.read?.next, 12_000)

        let pendingRead = try await client.call(BrieflyAgentCall(
            op: "read",
            read: .init(id: pending.id)
        ))
        XCTAssertNil(pendingRead.read?.text)
        XCTAssertEqual(pendingRead.read?.status, "processing")
        server.stop()
        do {
            _ = try await client.call(BrieflyAgentCall(op: "search", search: .init()))
            XCTFail("A closed app must remain unavailable to agent requests.")
        } catch let failure as BrieflyAgentFailure {
            XCTAssertEqual(failure.code, "library_unavailable")
        }
        #else
        let hiddenSource = try await agent.search(.init(q: "classified-source-token"))
        XCTAssertEqual(hiddenSource.items, [])
        #endif
    }
}
