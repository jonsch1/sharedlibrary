import XCTest
@testable import SharedLibrary

final class KnowledgeStoreTests: XCTestCase {
    private func makeWorkspace() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("knowledge-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("gather", isDirectory: true), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("gather/summaries", isDirectory: true), withIntermediateDirectories: true)
        return root
    }

    func testSnapshotGroupsSourceRecordsByTopic() throws {
        let root = try makeWorkspace()

        try """
        version: 1

        areas:
          - id: "work"
            title: "Work"
            description: "Professional projects."

        topics:
          - id: "voice-live-building"
            area: "work"
            title: "Voice Live-Building"
            description: "Building conversational voice products."
        """.write(to: root.appendingPathComponent("topics.md"), atomically: true, encoding: .utf8)

        try """
        ---
        id: "source-1"
        type: "link"
        title: "LiveKit docs"
        created_at: "2026-07-07T10:05:00.000Z"
        updated_at: "2026-07-07T10:05:00.000Z"
        reviewed_at: "2026-07-07T11:05:00.000Z"
        tags: []
        topics:
          - voice-live-building
        source_url: "https://example.com/livekit"
        ---

        LiveKit voice agent documentation.
        """.write(
            to: root.appendingPathComponent("gather/260707-1.md"),
            atomically: true,
            encoding: .utf8
        )

        try """
        # Latency optimizations

        Summary of 260707-1.md.
        """.write(
            to: root.appendingPathComponent("gather/summaries/260707-1.md"),
            atomically: true,
            encoding: .utf8
        )

        let snapshot = try KnowledgeStore().snapshot(workspaceRootURL: root)
        let voiceRecords = snapshot.records.filter { $0.topicIDs.contains("voice-live-building") }

        XCTAssertEqual(snapshot.topics.first?.title, "Voice Live-Building")
        XCTAssertEqual(snapshot.topics.first?.areaID, "work")
        XCTAssertEqual(snapshot.areas.first?.title, "Work")
        XCTAssertEqual(voiceRecords.count, 1)
        XCTAssertEqual(voiceRecords.filter { $0.typeID == "source" }.count, 1)
        XCTAssertEqual(voiceRecords.filter { $0.typeID == "summary" }.count, 0)
        XCTAssertTrue(voiceRecords.first { $0.typeID == "source" }?.isReviewed == true)
    }

    func testSnapshotExcludesUnsupportedCaptureTypes() throws {
        let root = try makeWorkspace()
        try """
        version: 1

        areas:
          - id: "learning"
            title: "Learning"
            description: ""

        topics:
          - id: "diagrams"
            area: "learning"
            title: "Diagrams"
            description: "Visual diagrams."
        """.write(to: root.appendingPathComponent("topics.md"), atomically: true, encoding: .utf8)
        try """
        ---
        id: "unsupported-1"
        type: "binary"
        title: "Unsupported record"
        created_at: "2026-07-15T10:00:00.000Z"
        updated_at: "2026-07-15T10:00:00.000Z"
        tags: []
        topics:
          - diagrams
        source_url: "asset.bin"
        ---

        Unsupported content.
        """.write(
            to: root.appendingPathComponent("gather/unsupported.md"),
            atomically: true,
            encoding: .utf8
        )

        let snapshot = try KnowledgeStore().snapshot(workspaceRootURL: root)
        XCTAssertTrue(snapshot.records.isEmpty)
    }
}
