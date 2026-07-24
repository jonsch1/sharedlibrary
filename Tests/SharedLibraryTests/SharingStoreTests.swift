import XCTest
@testable import SharedLibrary

final class SharingStoreTests: XCTestCase {
    private let itemID = "capture-id"

    func testShareCopiesSourceAndSummariesIntoFlatLibrary() throws {
        let (privateRoot, sharedRoot) = try makeWorkspaces()
        defer { cleanUp(privateRoot) }
        let sourceURL = try writeCapture(in: privateRoot)
        try writeSummary("Brief", level: .brief, sourceURL: sourceURL, root: privateRoot)
        try writeSummary("Detailed", level: .detailed, sourceURL: sourceURL, root: privateRoot)

        let copied = try SharingStore().shareCapture(
            at: sourceURL,
            privateWorkspaceURL: privateRoot,
            sharedWorkspaceURL: sharedRoot
        )

        XCTAssertEqual(copied.count, 3)
        XCTAssertEqual(try text(sharedRoot, "library/\(itemID).source.md"), sourceText)
        XCTAssertEqual(try text(sharedRoot, "library/\(itemID).brief.md"), "Brief")
        XCTAssertEqual(try text(sharedRoot, "library/\(itemID).detailed.md"), "Detailed")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: sharedRoot.appendingPathComponent("library/summaries").path
        ))
    }

    func testReshareUpdatesSourceAndRemovesStaleSummary() throws {
        let (privateRoot, sharedRoot) = try makeWorkspaces()
        defer { cleanUp(privateRoot) }
        let sourceURL = try writeCapture(in: privateRoot)
        let summaryURL = try writeSummary(
            "Brief",
            level: .brief,
            sourceURL: sourceURL,
            root: privateRoot
        )
        let store = SharingStore()
        try store.shareCapture(
            at: sourceURL,
            privateWorkspaceURL: privateRoot,
            sharedWorkspaceURL: sharedRoot
        )
        try sourceText.replacingOccurrences(of: "Source body", with: "Updated body")
            .write(to: sourceURL, atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: summaryURL)

        try store.shareCapture(
            at: sourceURL,
            privateWorkspaceURL: privateRoot,
            sharedWorkspaceURL: sharedRoot
        )

        XCTAssertTrue(try text(sharedRoot, "library/\(itemID).source.md").contains("Updated body"))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: sharedRoot.appendingPathComponent("library/\(itemID).brief.md").path
        ))
    }

    func testTagWritesOneShareFileAndRecipientInboxIsDerived() throws {
        let context = try makeSharedContext()
        defer { cleanUp(context.privateRoot) }

        let reference = try context.store.tagSharedCapture(
            at: context.sourceURL,
            privateWorkspaceURL: context.privateRoot,
            sharedWorkspaceURL: context.sharedRoot,
            sharedBy: context.sharer,
            sharedWith: [context.recipient]
        )

        XCTAssertEqual(reference.contentPath, "library/\(itemID).source.md")
        XCTAssertEqual(reference.sharedWithIDs, [context.recipient.userID])
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: context.sharedRoot.appendingPathComponent("shares/\(itemID).json").path
        ))
        XCTAssertEqual(
            try context.store.inboxReferences(
                for: context.recipient,
                privateWorkspaceURL: context.recipientRoot,
                sharedWorkspaceURL: context.sharedRoot
            ).map(\.id),
            [reference.id]
        )
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: context.sharedRoot.appendingPathComponent("inbox").path
        ))
    }

    func testDismissWritesOnlyPersonalInboxState() throws {
        let context = try makeSharedContext()
        defer { cleanUp(context.privateRoot) }
        let reference = try context.store.tagSharedCapture(
            at: context.sourceURL,
            privateWorkspaceURL: context.privateRoot,
            sharedWorkspaceURL: context.sharedRoot,
            sharedBy: context.sharer,
            sharedWith: [context.recipient]
        )
        let item = try XCTUnwrap(context.store.inboxItems(
            for: context.recipient,
            privateWorkspaceURL: context.recipientRoot,
            sharedWorkspaceURL: context.sharedRoot
        ).first)
        let sharedFilesBefore = try sharedFilePaths(context.sharedRoot)

        try context.store.dismissInboxItem(item, privateWorkspaceURL: context.recipientRoot)

        XCTAssertTrue(try context.store.inboxItems(
            for: context.recipient,
            privateWorkspaceURL: context.recipientRoot,
            sharedWorkspaceURL: context.sharedRoot
        ).isEmpty)
        XCTAssertEqual(try sharedFilePaths(context.sharedRoot), sharedFilesBefore)
        let state = try JSONSerialization.jsonObject(
            with: Data(contentsOf: context.recipientRoot
                .appendingPathComponent(".shared-library/inbox-state.json"))
        ) as? [String: Any]
        let shares = state?["shares"] as? [String: [String: Any]]
        XCTAssertEqual(shares?[reference.id]?["disposition"] as? String, "dismissed")
    }

    func testNewRevisionMakesDismissedShareVisibleAgain() throws {
        let context = try makeSharedContext()
        defer { cleanUp(context.privateRoot) }
        _ = try context.store.tagSharedCapture(
            at: context.sourceURL,
            privateWorkspaceURL: context.privateRoot,
            sharedWorkspaceURL: context.sharedRoot,
            sharedBy: context.sharer,
            sharedWith: [context.recipient]
        )
        let item = try XCTUnwrap(context.store.inboxItems(
            for: context.recipient,
            privateWorkspaceURL: context.recipientRoot,
            sharedWorkspaceURL: context.sharedRoot
        ).first)
        try context.store.dismissInboxItem(item, privateWorkspaceURL: context.recipientRoot)

        _ = try context.store.tagSharedCapture(
            at: context.sourceURL,
            privateWorkspaceURL: context.privateRoot,
            sharedWorkspaceURL: context.sharedRoot,
            sharedBy: context.sharer,
            sharedWith: [context.recipient]
        )

        XCTAssertEqual(try context.store.inboxItems(
            for: context.recipient,
            privateWorkspaceURL: context.recipientRoot,
            sharedWorkspaceURL: context.sharedRoot
        ).count, 1)
    }

    func testSavingInboxCreatesIndependentPersonalCaptureAndState() throws {
        let context = try makeSharedContext()
        defer { cleanUp(context.privateRoot) }
        try writeSummary(
            "Shared brief",
            level: .brief,
            sourceURL: context.sourceURL,
            root: context.privateRoot
        )
        try context.store.shareCapture(
            at: context.sourceURL,
            privateWorkspaceURL: context.privateRoot,
            sharedWorkspaceURL: context.sharedRoot
        )
        _ = try context.store.tagSharedCapture(
            at: context.sourceURL,
            privateWorkspaceURL: context.privateRoot,
            sharedWorkspaceURL: context.sharedRoot,
            sharedBy: context.sharer,
            sharedWith: [context.recipient]
        )
        let item = try XCTUnwrap(context.store.inboxItems(
            for: context.recipient,
            privateWorkspaceURL: context.recipientRoot,
            sharedWorkspaceURL: context.sharedRoot
        ).first)

        let savedURL = try context.store.saveInboxItem(
            item,
            privateWorkspaceURL: context.recipientRoot,
            sharedWorkspaceURL: context.sharedRoot
        )

        let saved = try String(contentsOf: savedURL, encoding: .utf8)
        XCTAssertTrue(saved.contains("Source body"))
        XCTAssertTrue(saved.contains("shared_from: \"\(itemID)\""))
        let savedSummary = context.recipientRoot
            .appendingPathComponent("library/summaries/brief/\(savedURL.lastPathComponent)")
        XCTAssertEqual(try String(contentsOf: savedSummary, encoding: .utf8), "Shared brief")
        XCTAssertTrue(try context.store.inboxItems(
            for: context.recipient,
            privateWorkspaceURL: context.recipientRoot,
            sharedWorkspaceURL: context.sharedRoot
        ).isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: context.sharedRoot.appendingPathComponent("library/\(itemID).source.md").path
        ))
    }

    func testUnshareRemovesOnlyThisItemsFlatFilesAndShareRecord() throws {
        let context = try makeSharedContext()
        defer { cleanUp(context.privateRoot) }
        _ = try context.store.tagSharedCapture(
            at: context.sourceURL,
            privateWorkspaceURL: context.privateRoot,
            sharedWorkspaceURL: context.sharedRoot,
            sharedBy: context.sharer,
            sharedWith: [context.recipient]
        )
        let unrelated = context.sharedRoot.appendingPathComponent("library/unrelated.source.md")
        try "keep".write(to: unrelated, atomically: true, encoding: .utf8)

        try context.store.unshareCapture(
            at: context.sourceURL,
            privateWorkspaceURL: context.privateRoot,
            sharedWorkspaceURL: context.sharedRoot
        )

        XCTAssertFalse(FileManager.default.fileExists(
            atPath: context.sharedRoot.appendingPathComponent("library/\(itemID).source.md").path
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: context.sharedRoot.appendingPathComponent("shares/\(itemID).json").path
        ))
        XCTAssertEqual(try String(contentsOf: unrelated, encoding: .utf8), "keep")
    }

    func testRejectsEqualOrNestedWorkspaceFolders() {
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

    private var sourceText: String {
        """
        ---
        id: "capture-id"
        title: "Example"
        ---
        Source body
        """
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

    private func makeSharedContext() throws -> (
        privateRoot: URL,
        sharedRoot: URL,
        recipientRoot: URL,
        sourceURL: URL,
        store: SharingStore,
        sharer: SharedPerson,
        recipient: SharedPerson
    ) {
        let (privateRoot, sharedRoot) = try makeWorkspaces()
        let recipientRoot = privateRoot.deletingLastPathComponent()
            .appendingPathComponent("recipient", isDirectory: true)
        try FileManager.default.createDirectory(
            at: recipientRoot.appendingPathComponent("library", isDirectory: true),
            withIntermediateDirectories: true
        )
        let sourceURL = try writeCapture(in: privateRoot)
        let directory = PeopleDirectoryStore()
        let sharer = try directory.register(
            userID: "sharer-id",
            username: "sharer",
            sharedWorkspaceURL: sharedRoot
        )
        let recipient = try directory.register(
            userID: "recipient-id",
            username: "recipient",
            sharedWorkspaceURL: sharedRoot
        )
        let store = SharingStore()
        try store.shareCapture(
            at: sourceURL,
            privateWorkspaceURL: privateRoot,
            sharedWorkspaceURL: sharedRoot
        )
        return (
            privateRoot,
            sharedRoot,
            recipientRoot,
            sourceURL,
            store,
            sharer,
            recipient
        )
    }

    private func writeCapture(in root: URL) throws -> URL {
        let sourceURL = root.appendingPathComponent("library/example.md")
        try sourceText.write(to: sourceURL, atomically: true, encoding: .utf8)
        return sourceURL
    }

    @discardableResult
    private func writeSummary(
        _ contents: String,
        level: SummaryDetailLevel,
        sourceURL: URL,
        root: URL
    ) throws -> URL {
        let url = root
            .appendingPathComponent("library/summaries/\(level.storageDirectoryName)")
            .appendingPathComponent(sourceURL.lastPathComponent)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func text(_ root: URL, _ relativePath: String) throws -> String {
        try String(
            contentsOf: root.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    private func sharedFilePaths(_ root: URL) throws -> [String] {
        let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey]
        )
        let prefix = root.path + "/"
        return try XCTUnwrap(enumerator?.allObjects as? [URL])
            .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
            .map { String($0.path.dropFirst(prefix.count)) }
            .sorted()
    }

    private func cleanUp(_ privateRoot: URL) {
        try? FileManager.default.removeItem(at: privateRoot.deletingLastPathComponent())
    }
}
