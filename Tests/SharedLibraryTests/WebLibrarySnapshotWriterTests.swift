import Foundation
import XCTest
@testable import SharedLibrary

final class DriveLibraryMirrorBuilderTests: XCTestCase {
    func testBuildsIndexOfMirroredMarkdownWithoutEmbeddingDocumentText() throws {
        let workspaceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("drive-library-mirror-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: workspaceURL) }

        let libraryURL = workspaceURL.appendingPathComponent("library", isDirectory: true)
        let conciseURL = libraryURL.appendingPathComponent(
            "summaries/concise",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: conciseURL,
            withIntermediateDirectories: true
        )
        let source = """
        ---
        id: "capture-1"
        type: "text"
        title: "Example"
        topics: []
        tags: ["test"]
        created_at: "2023-11-14T22:13:20Z"
        ---

        Original document body.
        """
        try source.write(
            to: libraryURL.appendingPathComponent("example.md"),
            atomically: true,
            encoding: .utf8
        )
        try "A concise summary.\n".write(
            to: conciseURL.appendingPathComponent("example.md"),
            atomically: true,
            encoding: .utf8
        )
        try "# Topics\n".write(
            to: workspaceURL.appendingPathComponent("topics.md"),
            atomically: true,
            encoding: .utf8
        )

        let mirror = try DriveLibraryMirrorBuilder(
            knowledgeStore: KnowledgeStore(),
            sharingStore: SharingStore()
        ).build(workspaceURL: workspaceURL)

        XCTAssertEqual(mirror.index.schemaVersion, 3)
        XCTAssertEqual(
            mirror.index.files.map(\.path),
            [
                "library/example.md",
                "library/summaries/concise/example.md",
                "topics.md"
            ]
        )
        let entry = try XCTUnwrap(mirror.index.entries.first)
        XCTAssertEqual(entry.id, "personal:capture-1")
        XCTAssertEqual(
            entry.texts.map(\.path),
            [
                "library/summaries/concise/example.md",
                "library/example.md"
            ]
        )

        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: mirror.indexData) as? [String: Any]
        )
        XCTAssertEqual(json["schemaVersion"] as? Int, 3)
        let encodedEntries = try XCTUnwrap(json["entries"] as? [[String: Any]])
        let encodedTexts = try XCTUnwrap(encodedEntries.first?["texts"] as? [[String: Any]])
        XCTAssertTrue(encodedTexts.allSatisfy { $0["text"] == nil })
        XCTAssertEqual(mirror.files.count, 3)
    }
}
