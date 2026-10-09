#if os(macOS)
import AppKit
import SwiftUI

/// Builds the text people copy to connect an assistant to the embedded briefly-mcp server.
enum BrieflyAgentSetup {
    static var helperPath: String {
        Bundle.main.bundleURL
            .appending(path: "Contents/Helpers/BrieflyMCP.app/Contents/MacOS/briefly-mcp")
            .path
    }

    /// The agent skill body, bundled from packages/mcp/plugin/skills/briefly/SKILL.md so the
    /// plugin and these instructions share one source. The YAML front matter is dropped, and
    /// so are the skill's `##` subsections: they cover the developer SDK, not everyday use.
    static var guidelines: String {
        guard
            let url = Bundle.main.url(forResource: "SKILL", withExtension: "md"),
            let text = try? String(contentsOf: url, encoding: .utf8)
        else { return "" }
        let body = withoutFrontMatter(text)
        let core = body.range(of: "\n## ").map { String(body[..<$0.lowerBound]) } ?? body
        return core.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func withoutFrontMatter(_ text: String) -> String {
        var body = Substring(text)
        if body.hasPrefix("---\n"),
           let end = body.dropFirst(4).range(of: "\n---\n") {
            body = body[end.upperBound...]
        }
        return body.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func instructions(path: String = helperPath, guidelines: String = guidelines) -> String {
        """
        Set up Briefly for me. Briefly is a Mac app that keeps my reading library: saved articles, videos, papers, and their summaries. It includes a local MCP server so you can search and read my library and save things to it when I ask.

        MCP server
        - Name: briefly
        - Transport: stdio
        - Command: \(path)
        - No arguments, environment variables, or API key. It only works while the Briefly app is open.

        Please:
        1. Register this MCP server for my user account (not only this project):
           - Claude Code: run `\(claudeCommand(path: path))`
           - Codex: run `\(codexCommand(path: path))`, or add this to ~/.codex/config.toml:
             [mcp_servers.briefly]
             command = \(quoted(path))
           - Other MCP clients (Cursor, Claude Desktop, and others): add a stdio server named "briefly" with the command above to your MCP configuration.
        2. Save the usage guidelines below where you keep reusable instructions: as a skill named "briefly" if you support skills, otherwise in your global instructions.
        3. Tell me if I need to restart you. Once the server is available, call the `search` tool with no arguments and show me the titles it returns, to confirm it works.

        Usage guidelines for Briefly
        \(guidelines)
        """
    }

    static func claudeCommand(path: String = helperPath) -> String {
        "claude mcp add --scope user briefly -- \(quoted(path))"
    }

    static func codexCommand(path: String = helperPath) -> String {
        "codex mcp add briefly -- \(quoted(path))"
    }

    static func jsonConfig(path: String = helperPath) -> String {
        """
        {
          "mcpServers": {
            "briefly": {
              "command": \(quoted(path))
            }
          }
        }
        """
    }

    /// A double-quoted string that is valid in shells, JSON, and TOML for ordinary paths.
    private static func quoted(_ value: String) -> String {
        let data = (try? JSONEncoder().encode(value)) ?? Data()
        return String(data: data, encoding: .utf8)?
            .replacingOccurrences(of: "\\/", with: "/") ?? "\"\(value)\""
    }
}

struct AgentConnectionSettings: View {
    @Bindable var model: LibraryModel
    @State private var copied: String?

    var body: some View {
        SettingsGroup(title: nil) {
            Text("Your assistant can search and read your summaries and save links when you ask. Briefly must be open.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                Button {
                    copy(BrieflyAgentSetup.instructions(), id: "instructions")
                } label: {
                    Label("Copy setup instructions", systemImage: "doc.on.doc")
                }
                .buttonStyle(.borderedProminent)
                if copied == "instructions" {
                    Label("Copied", systemImage: "checkmark")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .transition(.opacity)
                }
            }
            .padding(.top, 4)
            Text("Paste them into Claude Code, Codex, or another coding assistant and it will set itself up.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }

        SettingsGroup(title: "Status") {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                if let lastUsed = model.lastAgentRequestAt {
                    SettingsRow(
                        icon: "checkmark.circle.fill",
                        title: "Connected",
                        subtitle: "Last used \(relative(lastUsed, now: context.date)).",
                        iconTint: .green
                    )
                } else {
                    SettingsRow(
                        icon: "circle.dashed",
                        title: "Not connected yet",
                        subtitle: "This changes once an assistant reads your library."
                    )
                }
            }
        }

        SettingsGroup(title: nil) {
            DisclosureGroup("Set up manually") {
                VStack(alignment: .leading, spacing: 20) {
                    snippet(
                        "Claude Code",
                        code: BrieflyAgentSetup.claudeCommand()
                    )
                    snippet(
                        "Codex",
                        code: BrieflyAgentSetup.codexCommand()
                    )
                    snippet(
                        "Claude Desktop and Cursor",
                        note: "Claude Desktop: Settings → Developer → Edit Config " +
                            "(~/Library/Application Support/Claude/claude_desktop_config.json). " +
                            "Cursor: ~/.cursor/mcp.json. Add “briefly” to any existing mcpServers.",
                        code: BrieflyAgentSetup.jsonConfig()
                    )
                }
                .padding(.top, 12)
            }
            .font(.callout)
        }

        SettingsGroup(
            title: "Advanced",
            footer: "Custom source handlers built with the Briefly SDK connect through the same channel. " +
                "The capture shortcut tries connected handlers first."
        ) {
            TimelineView(.periodic(from: .now, by: 5)) { _ in
                let status = model.processing.inputService.captureCoordinator.runnerStatus()
                SettingsRow(
                    icon: "puzzlepiece.extension",
                    title: "Adapter runner",
                    subtitle: status.connected
                        ? "Connected · \(status.adapterCount) \(status.adapterCount == 1 ? "handler" : "handlers")"
                        : "Not connected. Briefly captures items itself."
                )
            }
        }
    }

    private func snippet(_ title: String, note: String? = nil, code: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button(copied == title ? "Copied" : "Copy") { copy(code, id: title) }
                    .buttonStyle(.borderless)
                    .font(.caption.weight(.medium))
                    .accessibilityLabel("Copy \(title) setup")
            }
            if let note {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(code)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.055), in: Rectangle())
        }
    }

    private func copy(_ text: String, id: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        withAnimation { copied = id }
        Task {
            try? await Task.sleep(for: .seconds(2))
            if copied == id { withAnimation { copied = nil } }
        }
    }

    private func relative(_ date: Date, now: Date) -> String {
        guard now.timeIntervalSince(date) >= 60 else { return "just now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: now)
    }
}
#endif
