import Foundation

enum AgentLauncherError: LocalizedError {
    case emptyCommand

    var errorDescription: String? {
        switch self {
        case .emptyCommand:
            return "The Agent command is empty. Set it in Shared Library Settings."
        }
    }
}

enum AgentLauncher {
    static func launch(commandTemplate: String, workspaceURL: URL) throws {
        let command = renderedCommand(
            from: commandTemplate,
            workspaceURL: workspaceURL
        )
        guard !command.isEmpty else {
            throw AgentLauncherError.emptyCommand
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", command]
        process.currentDirectoryURL = workspaceURL
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }

    static func renderedCommand(from template: String, workspaceURL: URL) -> String {
        template
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(
                of: AppSettings.workspaceCommandPlaceholder,
                with: shellQuoted(workspaceURL.standardizedFileURL.path)
            )
    }

    private static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}
