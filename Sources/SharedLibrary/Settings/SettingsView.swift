import SwiftUI
import AppKit
import KeyboardShortcuts

struct SettingsView: View {
    @EnvironmentObject var env: AppEnvironment

    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
            CaptureSettings()
                .tabItem { Label("Capture", systemImage: "tray.and.arrow.down") }
            AgentSettings()
                .tabItem { Label("Agent", systemImage: "sparkles") }
            SyncSettings(coordinator: env.gitSyncCoordinator)
                .tabItem { Label("Sync", systemImage: "arrow.triangle.2.circlepath") }
            HotkeySettings()
                .tabItem { Label("Hotkeys", systemImage: "keyboard") }
        }
        .frame(width: 740, height: 720)
    }
}

private struct GeneralSettings: View {
    @EnvironmentObject var env: AppEnvironment
    @AppStorage("libraryDarkMode") private var libraryDarkMode = false
    @State private var workspaceFolderPath = ""
    @State private var workspaceFolderStatus: String?

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Workspace", selection: $libraryDarkMode) {
                    Text("Light").tag(false)
                    Text("Dark").tag(true)
                }
                .pickerStyle(.segmented)
                .onChange(of: libraryDarkMode) { _, _ in
                    notifyLibraryAppearanceChanged()
                }

                Text("Controls the Shared Library workspace. Settings continue to follow macOS.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Section("Workspace folder") {
                HStack {
                    TextField("Folder", text: $workspaceFolderPath)
                        .onSubmit { applyWorkspaceFolder() }
                    Button("Choose...") { chooseWorkspaceFolder() }
                    Button("Default") {
                        workspaceFolderPath = env.settings.defaultWorkspaceRootURL.path
                        applyWorkspaceFolder()
                    }
                }

                if let workspaceFolderStatus {
                    Text(workspaceFolderStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Text("Captured sources, summaries, topics, and AGENTS.md all live inside this folder.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            workspaceFolderPath = env.settings.workspaceRootURL.path
        }
    }

    private func applyWorkspaceFolder() {
        let trimmed = workspaceFolderPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let url = URL(
            fileURLWithPath: NSString(string: trimmed).expandingTildeInPath,
            isDirectory: true
        )
        do {
            try env.setWorkspaceFolder(url)
            workspaceFolderPath = url.path
            workspaceFolderStatus = "Using \(url.path)"
        } catch {
            workspaceFolderStatus = error.localizedDescription
        }
    }

    private func chooseWorkspaceFolder() {
        let panel = NSOpenPanel()
        panel.canCreateDirectories = true
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.title = "Choose workspace folder"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        workspaceFolderPath = url.path
        applyWorkspaceFolder()
    }

    private func notifyLibraryAppearanceChanged() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .libraryAppearanceDidChange, object: nil)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            NotificationCenter.default.post(name: .libraryAppearanceDidChange, object: nil)
        }
    }
}

private struct CaptureSettings: View {
    @EnvironmentObject var env: AppEnvironment
    @AppStorage(AppSettings.includeTranscriptTimestampsKey) private var includeTranscriptTimestamps = false
    @State private var firecrawlAPIKey = ""
    @State private var firecrawlStatus: String?
    @State private var processingPrompt = ""
    @State private var processingStatus: String?

    var body: some View {
        Form {
            Section("Capture") {
                Toggle("Include transcript timestamps", isOn: $includeTranscriptTimestamps)

                HStack {
                    SecureField("Firecrawl API key", text: $firecrawlAPIKey)
                    Button("Save") { saveFirecrawlKey() }
                        .disabled(firecrawlAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("Remove") { removeFirecrawlKey() }
                }

                if let firecrawlStatus {
                    Text(firecrawlStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Categorization") {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Text captures")
                        Text("GPT-5.6-Terra with medium reasoning")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                    Button("Categorize Uncategorized") {
                        env.processingCoordinator.organizeUncategorizedCaptures(
                            workspaceRootURL: env.settings.workspaceRootURL
                        )
                        processingStatus = "Categorizing uncategorized text captures in the background."
                    }
                    Button("Recategorize All") {
                        env.processingCoordinator.reorganizeAllCaptures(
                            workspaceRootURL: env.settings.workspaceRootURL
                        )
                        processingStatus = "Regenerating text summaries and topics in the background."
                    }
                }

                if let processingStatus {
                    Text(processingStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Processing prompt") {
                TextEditor(text: $processingPrompt)
                    .font(.system(.caption, design: .monospaced))
                    .frame(minHeight: 260)
                    .onChange(of: processingPrompt) { _, value in
                        env.settings.processingPrompt = value
                    }

                HStack(alignment: .firstTextBaseline) {
                    Text("Keep \(AppSettings.existingTopicsPromptPlaceholder) and \(AppSettings.sourcePromptPlaceholder) where their JSON data should appear.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Spacer()
                    Button("Restore Default") {
                        processingPrompt = AppSettings.defaultProcessingPrompt
                    }
                }
            }

        }
        .formStyle(.grouped)
        .onAppear {
            processingPrompt = env.settings.processingPrompt
            loadFirecrawlKey()
        }
    }

    private func loadFirecrawlKey() {
        do {
            firecrawlAPIKey = try KeychainStore.string(for: KeychainStore.firecrawlAPIKeyAccount) ?? ""
            firecrawlStatus = firecrawlAPIKey.isEmpty ? nil : "Firecrawl key stored in Keychain."
        } catch {
            firecrawlStatus = error.localizedDescription
        }
    }

    private func saveFirecrawlKey() {
        do {
            try KeychainStore.setString(firecrawlAPIKey, for: KeychainStore.firecrawlAPIKeyAccount)
            firecrawlAPIKey = try KeychainStore.string(for: KeychainStore.firecrawlAPIKeyAccount) ?? ""
            firecrawlStatus = firecrawlAPIKey.isEmpty ? "Removed." : "Saved."
        } catch {
            firecrawlStatus = error.localizedDescription
        }
    }

    private func removeFirecrawlKey() {
        do {
            try KeychainStore.delete(account: KeychainStore.firecrawlAPIKeyAccount)
            firecrawlAPIKey = ""
            firecrawlStatus = "Removed."
        } catch {
            firecrawlStatus = error.localizedDescription
        }
    }
}

private struct AgentSettings: View {
    @EnvironmentObject var env: AppEnvironment
    @State private var agentCommand = AppSettings.defaultAgentCommand
    @State private var agentInstructions = ""
    @State private var loadedAgentInstructions = ""
    @State private var agentInstructionsStatus: String?

    var body: some View {
        Form {
            Section("Agent button") {
                TextField("Command", text: $agentCommand)
                    .font(.system(.body, design: .monospaced))
                    .onChange(of: agentCommand) { _, value in
                        env.settings.agentCommand = value
                    }

                HStack(alignment: .firstTextBaseline) {
                    Text("\(AppSettings.workspaceCommandPlaceholder) is replaced with the shell-quoted workspace path. The command runs from that folder.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Spacer()
                    Button("Restore Default") {
                        agentCommand = AppSettings.defaultAgentCommand
                    }
                }
            }

            Section("AGENTS.md") {
                TextEditor(text: $agentInstructions)
                    .font(.system(.caption, design: .monospaced))
                    .frame(minHeight: 410)

                HStack(alignment: .firstTextBaseline) {
                    Text(agentsURL.path)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("Reload") { loadAgentInstructions() }
                    Button("Save") { saveAgentInstructions() }
                        .keyboardShortcut("s", modifiers: .command)
                        .disabled(agentInstructions == loadedAgentInstructions)
                }

                if let agentInstructionsStatus {
                    Text(agentInstructionsStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            agentCommand = env.settings.agentCommand
            loadAgentInstructions()
        }
    }

    private var agentsURL: URL {
        env.settings.workspaceRootURL.appendingPathComponent("AGENTS.md")
    }

    private func loadAgentInstructions() {
        do {
            try env.settings.ensureWorkspace()
            agentInstructions = try String(contentsOf: agentsURL, encoding: .utf8)
            loadedAgentInstructions = agentInstructions
            agentInstructionsStatus = nil
        } catch {
            agentInstructionsStatus = error.localizedDescription
        }
    }

    private func saveAgentInstructions() {
        do {
            try agentInstructions.write(to: agentsURL, atomically: true, encoding: .utf8)
            loadedAgentInstructions = agentInstructions
            agentInstructionsStatus = "Saved."
            env.gitSyncCoordinator.requestAutomaticSync(reason: "AGENTS.md edited")
        } catch {
            agentInstructionsStatus = error.localizedDescription
        }
    }
}

private struct SyncSettings: View {
    @ObservedObject var coordinator: GitSyncCoordinator
    @State private var remote = ""
    @State private var newRepositoryName = ""
    @State private var newRepositoryVisibility = GitHubRepositoryVisibility.privateRepository

    var body: some View {
        Form {
            Section("Prerequisites") {
                statusRow("Git", isReady: coordinator.repositoryStatus.gitAvailable)
                statusRow("GitHub CLI", isReady: coordinator.repositoryStatus.ghAvailable)
                statusRow("GitHub authentication", isReady: coordinator.repositoryStatus.ghAuthenticated)
            }

            Section("Workspace repository") {
                statusRow("Git repository", isReady: coordinator.repositoryStatus.isRepository)

                if let branch = coordinator.repositoryStatus.branch {
                    LabeledContent("Branch", value: branch)
                }
                if let remoteURL = coordinator.repositoryStatus.remoteURL {
                    LabeledContent("Origin") {
                        Text(remoteURL)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                }

                HStack {
                    Button("Refresh Status") { coordinator.refreshStatus() }
                    Button("Initialize Repository") { coordinator.initializeRepository() }
                        .disabled(coordinator.repositoryStatus.isRepository || coordinator.state.isBusy)
                    Spacer()
                    Button("Sync Now") { coordinator.syncNow() }
                        .buttonStyle(.borderedProminent)
                        .disabled(coordinator.state.isBusy)
                }
            }

            Section("GitHub repository") {
                HStack {
                    TextField("owner/repository or remote URL", text: $remote)
                        .font(.system(.body, design: .monospaced))
                    Button("Connect") { coordinator.connectRemote(remote) }
                        .disabled(
                            remote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                || coordinator.state.isBusy
                        )
                }
                Text("Connects this normal workspace directly to origin. Authentication uses your existing GitHub CLI login.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            if !coordinator.repositoryStatus.hasRemote {
                Section("Create GitHub repository") {
                    TextField("repository or owner/repository", text: $newRepositoryName)
                        .font(.system(.body, design: .monospaced))

                    Picker("Visibility", selection: $newRepositoryVisibility) {
                        ForEach(GitHubRepositoryVisibility.allCases) { visibility in
                            Text(visibility.title).tag(visibility)
                        }
                    }
                    .pickerStyle(.segmented)

                    HStack(alignment: .firstTextBaseline) {
                        Text("Creates the repository with GitHub CLI, adds it as origin, and pushes the current branch. New repositories are private by default.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                        Spacer()
                        Button("Create Repository") {
                            coordinator.createRemoteRepository(
                                name: newRepositoryName,
                                visibility: newRepositoryVisibility
                            )
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(
                            newRepositoryName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                || coordinator.state.isBusy
                                || !coordinator.repositoryStatus.ghAvailable
                                || !coordinator.repositoryStatus.ghAuthenticated
                        )
                    }
                }
            }

            Section("Sync status") {
                Label(coordinator.state.message, systemImage: syncStatusSymbol)
                    .foregroundStyle(syncStatusColor)
                    .textSelection(.enabled)
                Text("Sync commits local workspace changes, fetches and rebases the current branch, pushes to origin, and refreshes the library.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            if remote.isEmpty {
                remote = coordinator.repositoryStatus.remoteURL ?? ""
            }
            if newRepositoryName.isEmpty {
                newRepositoryName = coordinator.suggestedRepositoryName
            }
            coordinator.refreshStatus()
        }
        .onReceive(coordinator.$repositoryStatus) { status in
            if remote.isEmpty { remote = status.remoteURL ?? "" }
        }
    }

    @ViewBuilder
    private func statusRow(_ title: String, isReady: Bool) -> some View {
        LabeledContent(title) {
            Label(isReady ? "Ready" : "Not ready", systemImage: isReady ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(isReady ? Color.green : Color.orange)
        }
    }

    private var syncStatusSymbol: String {
        switch coordinator.state {
        case .checking, .syncing:
            return "arrow.triangle.2.circlepath"
        case .ready, .succeeded:
            return "checkmark.circle.fill"
        case .needsSetup:
            return "wrench.and.screwdriver.fill"
        case .unavailable, .failed:
            return "exclamationmark.triangle.fill"
        }
    }

    private var syncStatusColor: Color {
        switch coordinator.state {
        case .ready, .succeeded:
            return .green
        case .needsSetup:
            return .orange
        case .unavailable, .failed:
            return .red
        case .checking, .syncing:
            return .secondary
        }
    }
}

private struct HotkeySettings: View {
    var body: some View {
        Form {
            Section("Global hotkeys") {
                KeyboardShortcuts.Recorder("Shared Library", name: .toggleLibrary)
                KeyboardShortcuts.Recorder("Capture clipboard", name: .captureClipboard)
            }
            Text("Capture clipboard saves the current clipboard into library/.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }
}
