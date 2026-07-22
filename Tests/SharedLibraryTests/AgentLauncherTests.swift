import XCTest
@testable import SharedLibrary

final class AgentLauncherTests: XCTestCase {
    func testRenderedCommandShellQuotesWorkspacePlaceholder() {
        let workspace = URL(fileURLWithPath: "/tmp/Someone's Workspace", isDirectory: true)

        let command = AgentLauncher.renderedCommand(
            from: "open -a ChatGPT {{workspace}}",
            workspaceURL: workspace
        )

        XCTAssertEqual(command, "open -a ChatGPT '/tmp/Someone'\"'\"'s Workspace'")
    }

    func testRenderedCommandLeavesTemplateWithoutPlaceholderUnchanged() {
        let command = AgentLauncher.renderedCommand(
            from: "  custom-agent .  ",
            workspaceURL: URL(fileURLWithPath: "/tmp/workspace", isDirectory: true)
        )

        XCTAssertEqual(command, "custom-agent .")
    }
}
