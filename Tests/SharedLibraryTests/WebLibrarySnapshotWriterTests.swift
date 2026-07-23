import Foundation
import XCTest
@testable import SharedLibrary

final class WebLibrarySnapshotWriterTests: XCTestCase {
    func testWritesProjectionAsPortableISO8601JSON() throws {
        let folderURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("web-library-writer-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folderURL) }

        let generatedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let projection = CloudLibraryProjection(
            generatedAt: generatedAt,
            entries: [
                CloudLibraryEntryPayload(
                    id: "personal:example",
                    captureID: "example",
                    title: "Example",
                    excerpt: "A portable snapshot.",
                    topicIDs: ["research"],
                    topicNames: ["Research"],
                    tags: ["test"],
                    sourceURL: "https://example.com",
                    createdAt: generatedAt,
                    updatedAt: nil,
                    reviewedAt: nil,
                    origin: .personal,
                    sharedByGitHubID: nil,
                    sharedByDisplayName: nil,
                    texts: [
                        CloudLibraryTextPayload(
                            variant: .concise,
                            text: "A concise summary."
                        )
                    ]
                )
            ]
        )

        let destinationURL = try WebLibrarySnapshotWriter().write(
            projection,
            to: folderURL
        )
        XCTAssertEqual(destinationURL.lastPathComponent, "Shared Library Web.json")

        let data = try Data(contentsOf: destinationURL)
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertEqual(json["schemaVersion"] as? Int, CloudLibraryProjection.schemaVersion)
        XCTAssertEqual(json["generatedAt"] as? String, "2023-11-14T22:13:20Z")

        let decoded = try JSONDecoder.sharedLibraryWeb.decode(
            CloudLibraryProjection.self,
            from: data
        )
        XCTAssertEqual(decoded, projection)
    }
}

private extension JSONDecoder {
    static var sharedLibraryWeb: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
