import XCTest
@testable import SharedLibrary

final class AppSettingsTests: XCTestCase {
    func testEnsureWorkspaceCreatesLibraryWithoutNotes() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("app-settings-agents-\(UUID().uuidString)", isDirectory: true)

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

        try AppSettings().ensureWorkspace()

        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("notes").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("gather").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("output").path))
        let instructions = try String(contentsOf: root.appendingPathComponent("AGENTS.md"))
        XCTAssertTrue(instructions.contains("# Shared Library"))
        XCTAssertFalse(instructions.localizedCaseInsensitiveContains("notes"))
    }

    func testEnsureWorkspaceFlattensLegacySynthesisFoldersIntoOutput() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("app-settings-\(UUID().uuidString)", isDirectory: true)
        let gatherSyntheses = root.appendingPathComponent("gather/syntheses", isDirectory: true)
        let outputSyntheses = root.appendingPathComponent("output/syntheses", isDirectory: true)
        try FileManager.default.createDirectory(at: gatherSyntheses, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outputSyntheses, withIntermediateDirectories: true)
        try "legacy".write(
            to: gatherSyntheses.appendingPathComponent("market-map.md"),
            atomically: true,
            encoding: .utf8
        )
        try "newer".write(
            to: outputSyntheses.appendingPathComponent("brief.md"),
            atomically: true,
            encoding: .utf8
        )

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

        let settings = AppSettings()
        try settings.ensureWorkspace()

        XCTAssertTrue(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("output/market-map.md").path
        ))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("output/brief.md").path
        ))
        XCTAssertFalse(FileManager.default.fileExists(atPath: gatherSyntheses.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: outputSyntheses.path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("gather/images", isDirectory: true).path
        ))

        let taxonomy = try TaxonomyStore().load(from: root.appendingPathComponent("topics.md"))
        XCTAssertEqual(taxonomy.areas.map(\.id), ["personal", "work", "learning"])
        XCTAssertTrue(taxonomy.topics.contains { $0.id == "career" && $0.areaID == "work" })

        let agentText = try String(contentsOf: root.appendingPathComponent("AGENTS.md"))
        XCTAssertTrue(agentText.contains("automatically processes each new text capture"))
        XCTAssertTrue(agentText.contains("remains visible in Recent"))
        XCTAssertFalse(agentText.contains("Inbox"))
        XCTAssertTrue(agentText.contains("Images do not have topics or companion summaries"))
        XCTAssertTrue(agentText.contains("They appear newest first in Images"))
        XCTAssertTrue(agentText.contains("masonry gallery"))
        XCTAssertTrue(agentText.contains("gather/images/"))
        XCTAssertTrue(agentText.contains("brief,concise,detailed,comprehensive"))
        XCTAssertFalse(agentText.contains("scope: text"))
        XCTAssertFalse(agentText.contains("scope: image"))
        XCTAssertFalse(agentText.contains("embedding"))
        XCTAssertFalse(agentText.contains("cluster"))
    }
}
