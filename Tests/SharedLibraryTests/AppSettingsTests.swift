import XCTest
@testable import SharedLibrary

final class AppSettingsTests: XCTestCase {
    func testEnsureWorkspaceCreatesCaptureLibraryOnly() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("app-settings-library-\(UUID().uuidString)", isDirectory: true)

        try withWorkspaceRoot(root) {
            try AppSettings().ensureWorkspace()

            XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("gather").path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("gather/summaries").path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("topics.md").path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("notes").path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("output").path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("gather/images").path))

            let instructions = try String(contentsOf: root.appendingPathComponent("AGENTS.md"))
            XCTAssertTrue(instructions.contains("# Shared Library"))
            XCTAssertTrue(instructions.contains("The workspace is the library"))
            XCTAssertTrue(instructions.contains("automatically processes each new capture"))
            XCTAssertTrue(instructions.contains("brief,concise,detailed,comprehensive"))
            XCTAssertFalse(instructions.localizedCaseInsensitiveContains("notes"))
            XCTAssertFalse(instructions.localizedCaseInsensitiveContains("output"))
            XCTAssertFalse(instructions.localizedCaseInsensitiveContains("image"))
        }
    }

    func testEnsureWorkspacePreservesExistingFilesInDeprecatedFolders() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("app-settings-preserve-\(UUID().uuidString)", isDirectory: true)
        let outputFile = root.appendingPathComponent("output/deliverable.md")
        let assetFile = root.appendingPathComponent("gather/images/asset.png")
        try FileManager.default.createDirectory(
            at: outputFile.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: assetFile.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "Keep me".write(to: outputFile, atomically: true, encoding: .utf8)
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: assetFile)

        try withWorkspaceRoot(root) {
            try AppSettings().ensureWorkspace()

            XCTAssertTrue(FileManager.default.fileExists(atPath: outputFile.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: assetFile.path))
        }
    }

    private func withWorkspaceRoot(_ root: URL, operation: () throws -> Void) throws {
        let defaults = UserDefaults.standard
        let key = "workspaceFolderPath"
        let previousValue = defaults.object(forKey: key)
        defaults.set(root.path, forKey: key)
        defer {
            if let previousValue {
                defaults.set(previousValue, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
            try? FileManager.default.removeItem(at: root)
        }
        try operation()
    }
}
