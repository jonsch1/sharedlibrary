import XCTest
@testable import SharedLibrary

final class SharingStoreTests: XCTestCase {
    func testShareCopiesSourceAndEveryExistingSummary() throws {
        let (privateRoot, sharedRoot) = try makeWorkspaces()
        defer { cleanUp(privateRoot, sharedRoot) }
        let sourceURL = try writeCapture(in: privateRoot)
        let summaryURLs = LibraryStore.companionSummaryURLs(
            for: sourceURL,
            workspaceRootURL: privateRoot
        )
        for (index, summaryURL) in summaryURLs.enumerated() where index != 2 {
            try FileManager.default.createDirectory(
                at: summaryURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try "Summary \(index)".write(to: summaryURL, atomically: true, encoding: .utf8)
        }

        let store = SharingStore()
        let copied = try store.shareCapture(
            at: sourceURL,
            privateWorkspaceURL: privateRoot,
            sharedWorkspaceURL: sharedRoot
        )

        XCTAssertEqual(copied.count, summaryURLs.count)
        XCTAssertTrue(store.isShared(
            captureAt: sourceURL,
            privateWorkspaceURL: privateRoot,
            sharedWorkspaceURL: sharedRoot
        ))
        XCTAssertEqual(
            try String(contentsOf: sharedRoot.appendingPathComponent("library/example.md")),
            "Source"
        )
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: sharedRoot.appendingPathComponent("library/summaries/concise/example.md").path
        ))
    }

    func testReshareAtomicallyUpdatesExistingCopies() throws {
        let (privateRoot, sharedRoot) = try makeWorkspaces()
        defer { cleanUp(privateRoot, sharedRoot) }
        let sourceURL = try writeCapture(in: privateRoot)
        let store = SharingStore()
        try store.shareCapture(
            at: sourceURL,
            privateWorkspaceURL: privateRoot,
            sharedWorkspaceURL: sharedRoot
        )
        try "Updated".write(to: sourceURL, atomically: true, encoding: .utf8)

        try store.shareCapture(
            at: sourceURL,
            privateWorkspaceURL: privateRoot,
            sharedWorkspaceURL: sharedRoot
        )

        XCTAssertEqual(
            try String(contentsOf: sharedRoot.appendingPathComponent("library/example.md")),
            "Updated"
        )
    }

    func testReshareRemovesAStaleSummaryThatNoLongerExistsPrivately() throws {
        let (privateRoot, sharedRoot) = try makeWorkspaces()
        defer { cleanUp(privateRoot, sharedRoot) }
        let sourceURL = try writeCapture(in: privateRoot)
        let summaryURL = LibraryStore.companionSummaryURLs(
            for: sourceURL,
            workspaceRootURL: privateRoot
        )[0]
        try FileManager.default.createDirectory(
            at: summaryURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "Summary".write(to: summaryURL, atomically: true, encoding: .utf8)
        let store = SharingStore()
        try store.shareCapture(
            at: sourceURL,
            privateWorkspaceURL: privateRoot,
            sharedWorkspaceURL: sharedRoot
        )
        let sharedSummaryURL = sharedRoot.appendingPathComponent("library/summaries/example.md")
        XCTAssertTrue(FileManager.default.fileExists(atPath: sharedSummaryURL.path))
        try FileManager.default.removeItem(at: summaryURL)

        try store.shareCapture(
            at: sourceURL,
            privateWorkspaceURL: privateRoot,
            sharedWorkspaceURL: sharedRoot
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: sharedSummaryURL.path))
    }

    func testUnshareRemovesOnlyMirroredCaptureFiles() throws {
        let (privateRoot, sharedRoot) = try makeWorkspaces()
        defer { cleanUp(privateRoot, sharedRoot) }
        let sourceURL = try writeCapture(in: privateRoot)
        let summaryURL = LibraryStore.companionSummaryURLs(
            for: sourceURL,
            workspaceRootURL: privateRoot
        )[0]
        try FileManager.default.createDirectory(
            at: summaryURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "Summary".write(to: summaryURL, atomically: true, encoding: .utf8)
        let store = SharingStore()
        try store.shareCapture(
            at: sourceURL,
            privateWorkspaceURL: privateRoot,
            sharedWorkspaceURL: sharedRoot
        )
        let unrelatedURL = sharedRoot.appendingPathComponent("library/unrelated.md")
        try "Keep".write(to: unrelatedURL, atomically: true, encoding: .utf8)

        let removed = try store.unshareCapture(
            at: sourceURL,
            privateWorkspaceURL: privateRoot,
            sharedWorkspaceURL: sharedRoot
        )

        XCTAssertEqual(removed.count, 2)
        XCTAssertFalse(store.isShared(
            captureAt: sourceURL,
            privateWorkspaceURL: privateRoot,
            sharedWorkspaceURL: sharedRoot
        ))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sourceURL.path))
        XCTAssertEqual(try String(contentsOf: unrelatedURL), "Keep")
    }

    func testRejectsEqualOrNestedWorkspaceFolders() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sharing-overlap-\(UUID().uuidString)", isDirectory: true)
        let store = SharingStore()

        XCTAssertThrowsError(try store.validateWorkspaceRoots(
            privateWorkspaceURL: root,
            sharedWorkspaceURL: root
        )) { error in
            XCTAssertEqual(error as? SharingStoreError, .overlappingWorkspaces)
        }
        XCTAssertThrowsError(try store.validateWorkspaceRoots(
            privateWorkspaceURL: root,
            sharedWorkspaceURL: root.appendingPathComponent("shared", isDirectory: true)
        )) { error in
            XCTAssertEqual(error as? SharingStoreError, .overlappingWorkspaces)
        }
    }

    func testUnshareStillWorksAfterPrivateSourceWasDeleted() throws {
        let (privateRoot, sharedRoot) = try makeWorkspaces()
        defer { cleanUp(privateRoot, sharedRoot) }
        let sourceURL = try writeCapture(in: privateRoot)
        let store = SharingStore()
        try store.shareCapture(
            at: sourceURL,
            privateWorkspaceURL: privateRoot,
            sharedWorkspaceURL: sharedRoot
        )
        try FileManager.default.removeItem(at: sourceURL)

        try store.unshareCapture(
            at: sourceURL,
            privateWorkspaceURL: privateRoot,
            sharedWorkspaceURL: sharedRoot
        )

        XCTAssertFalse(FileManager.default.fileExists(
            atPath: sharedRoot.appendingPathComponent("library/example.md").path
        ))
    }

    private func makeWorkspaces() throws -> (URL, URL) {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("sharing-store-\(UUID().uuidString)", isDirectory: true)
        let privateRoot = base.appendingPathComponent("private", isDirectory: true)
        let sharedRoot = base.appendingPathComponent("shared", isDirectory: true)
        try FileManager.default.createDirectory(
            at: privateRoot.appendingPathComponent("library", isDirectory: true),
            withIntermediateDirectories: true
        )
        return (privateRoot, sharedRoot)
    }

    private func writeCapture(in root: URL) throws -> URL {
        let sourceURL = root.appendingPathComponent("library/example.md")
        try "Source".write(to: sourceURL, atomically: true, encoding: .utf8)
        return sourceURL
    }

    private func cleanUp(_ privateRoot: URL, _: URL) {
        try? FileManager.default.removeItem(at: privateRoot.deletingLastPathComponent())
    }
}
