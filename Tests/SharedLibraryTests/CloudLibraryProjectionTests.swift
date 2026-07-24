import XCTest
@testable import SharedLibrary

final class CloudLibraryProjectionTests: XCTestCase {
    func testProjectionPublishesPersonalSourceAndEverySummaryVariant() throws {
        let workspace = try makeWorkspace(named: "personal")
        let sharedWorkspace = try makeWorkspace(named: "unused-shared")
        defer {
            try? FileManager.default.removeItem(at: workspace)
            try? FileManager.default.removeItem(at: sharedWorkspace)
        }
        let sourceURL = try writeCapture(
            workspace: workspace,
            filename: "personal.md",
            id: "capture-personal",
            title: "Personal capture",
            body: "The original personal source."
        )
        try writeSummaries(for: sourceURL, workspace: workspace, prefix: "Personal")

        let projection = try CloudLibraryProjectionBuilder().build(
            privateWorkspaceURL: workspace,
            sharedWorkspaceURL: sharedWorkspace,
            currentUserID: nil,
            generatedAt: Date(timeIntervalSince1970: 100)
        )

        XCTAssertEqual(projection.schemaVersion, 2)
        XCTAssertEqual(projection.entries.count, 1)
        let entry = try XCTUnwrap(projection.entries.first)
        XCTAssertEqual(entry.id, "personal:capture-personal")
        XCTAssertEqual(entry.origin, .personal)
        XCTAssertEqual(Set(entry.texts.map(\.variant)), Set(CloudLibraryVariant.allCases))
        XCTAssertEqual(
            entry.texts.first(where: { $0.variant == .brief })?.text,
            "Personal brief"
        )
        XCTAssertEqual(
            entry.texts.first(where: { $0.variant == .source })?.text,
            "The original personal source."
        )
    }

    func testProjectionIncludesOnlyCapturesSharedWithCurrentStableUserID() throws {
        let personal = try makeWorkspace(named: "personal-empty")
        let shared = try makeWorkspace(named: "shared")
        defer {
            try? FileManager.default.removeItem(at: personal)
            try? FileManager.default.removeItem(at: shared)
        }
        let directory = PeopleDirectoryStore()
        let people = [
            try directory.register(
                userID: "user-sharer",
                username: "sharer",
                sharedWorkspaceURL: shared
            ),
            try directory.register(
                userID: "user-me",
                username: "me",
                sharedWorkspaceURL: shared
            ),
            try directory.register(
                userID: "user-other",
                username: "other",
                sharedWorkspaceURL: shared
            )
        ]

        let privateForSharing = try makeWorkspace(named: "sharing-source")
        defer { try? FileManager.default.removeItem(at: privateForSharing) }
        let mine = try writeCapture(
            workspace: privateForSharing,
            filename: "mine.md",
            id: "mine",
            title: "Shared with me",
            body: "Mine source."
        )
        let other = try writeCapture(
            workspace: privateForSharing,
            filename: "other.md",
            id: "other",
            title: "Shared with someone else",
            body: "Other source."
        )
        try writeSummaries(for: mine, workspace: privateForSharing, prefix: "Mine")
        try writeSummaries(for: other, workspace: privateForSharing, prefix: "Other")

        let sharingStore = SharingStore()
        try sharingStore.shareCapture(
            at: mine,
            privateWorkspaceURL: privateForSharing,
            sharedWorkspaceURL: shared
        )
        try sharingStore.shareCapture(
            at: other,
            privateWorkspaceURL: privateForSharing,
            sharedWorkspaceURL: shared
        )
        _ = try sharingStore.tagSharedCapture(
            at: mine,
            privateWorkspaceURL: privateForSharing,
            sharedWorkspaceURL: shared,
            sharedBy: people[0],
            sharedWith: [people[1]]
        )
        _ = try sharingStore.tagSharedCapture(
            at: other,
            privateWorkspaceURL: privateForSharing,
            sharedWorkspaceURL: shared,
            sharedBy: people[0],
            sharedWith: [people[2]]
        )

        let projection = try CloudLibraryProjectionBuilder().build(
            privateWorkspaceURL: personal,
            sharedWorkspaceURL: shared,
            currentUserID: "user-me"
        )

        XCTAssertEqual(projection.entries.count, 1)
        let entry = try XCTUnwrap(projection.entries.first)
        XCTAssertEqual(entry.title, "Shared with me")
        XCTAssertEqual(entry.origin, .shared)
        XCTAssertEqual(entry.sharedByUserID, "user-sharer")
        XCTAssertEqual(entry.sharedByUsername, "sharer")
        XCTAssertTrue(entry.id.hasPrefix("shared:"))
    }

    func testCloudRecordNamesAndContentHashesAreStable() {
        let text = CloudLibraryTextPayload(variant: .concise, text: "Stable text")
        let entry = CloudLibraryEntryPayload(
            id: "personal:stable",
            captureID: "stable",
            title: "Stable",
            excerpt: "Excerpt",
            topicIDs: ["topic"],
            topicNames: ["Topic"],
            tags: [],
            sourceURL: nil,
            createdAt: Date(timeIntervalSince1970: 10),
            updatedAt: Date(timeIntervalSince1970: 20),
            reviewedAt: nil,
            origin: .personal,
            sharedByUserID: nil,
            sharedByUsername: nil,
            texts: [text]
        )

        XCTAssertEqual(entry.recordName, entry.recordName)
        XCTAssertEqual(entry.metadataContentHash, entry.metadataContentHash)
        XCTAssertEqual(text.contentHash, text.contentHash)
        XCTAssertNotEqual(entry.recordName, entry.textRecordName(for: .concise))
        XCTAssertEqual(entry.recordName.count, 70)
    }

    private func makeWorkspace(named name: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cloud-library-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("library/summaries", isDirectory: true),
            withIntermediateDirectories: true
        )
        try """
        version: 1

        areas:
          - id: "work"
            title: "Work"
            description: ""

        topics:
          - id: "research"
            area: "work"
            title: "Research"
            description: ""
        """.write(
            to: root.appendingPathComponent("topics.md"),
            atomically: true,
            encoding: .utf8
        )
        return root
    }

    @discardableResult
    private func writeCapture(
        workspace: URL,
        filename: String,
        id: String,
        title: String,
        body: String
    ) throws -> URL {
        let url = workspace.appendingPathComponent("library/\(filename)")
        try """
        ---
        id: "\(id)"
        type: "text"
        title: "\(title)"
        created_at: "2026-07-23T10:00:00.000Z"
        updated_at: "2026-07-23T11:00:00.000Z"
        tags: []
        topics:
          - research
        source_url: "clipboard:"
        ---

        \(body)
        """.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func writeSummaries(
        for sourceURL: URL,
        workspace: URL,
        prefix: String
    ) throws {
        let summaries = workspace.appendingPathComponent("library/summaries", isDirectory: true)
        for level in SummaryDetailLevel.allCases {
            let directory = summaries.appendingPathComponent(
                level.storageDirectoryName,
                isDirectory: true
            )
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try "\(prefix) \(level.storageDirectoryName)".write(
                to: directory.appendingPathComponent(sourceURL.lastPathComponent),
                atomically: true,
                encoding: .utf8
            )
        }
    }
}
