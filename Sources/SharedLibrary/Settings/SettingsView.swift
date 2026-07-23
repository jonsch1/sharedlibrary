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
            SyncSettings(coordinator: env.gitSyncCoordinator, purpose: .privateLibrary)
                .tabItem { Label("Sync", systemImage: "arrow.triangle.2.circlepath") }
            SyncSettings(coordinator: env.sharedGitSyncCoordinator, purpose: .sharedLibrary)
                .tabItem { Label("Sharing", systemImage: "person.2") }
            PeopleSettings(peopleStore: env.peopleStore)
                .tabItem { Label("People", systemImage: "person.3") }
            MobileSettings(publisher: env.cloudLibraryPublisher)
                .tabItem { Label("Mobile", systemImage: "iphone") }
            HotkeySettings()
                .tabItem { Label("Hotkeys", systemImage: "keyboard") }
        }
        .frame(width: 740, height: 720)
    }
}

private struct MobileSettings: View {
    @EnvironmentObject var env: AppEnvironment
    @ObservedObject var publisher: CloudLibraryPublisher
    @AppStorage(AppSettings.cloudLibrarySyncEnabledKey) private var syncEnabled = true

    var body: some View {
        Form {
            Section("iCloud mobile library") {
                Toggle("Publish My Library to iCloud", isOn: $syncEnabled)
                    .onChange(of: syncEnabled) { _, enabled in
                        publisher.setEnabled(enabled)
                    }

                Text("The personal library and captures shared with your stable GitHub ID are published as a private, read-only CloudKit projection. Git remains the source of truth.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Section("Status") {
                Label(publisher.state.message, systemImage: statusSymbol)
                    .foregroundStyle(statusColor)
                    .textSelection(.enabled)

                if let lastPublishedAt = env.settings.cloudLibraryLastPublishedAt {
                    LabeledContent(
                        "Last published",
                        value: lastPublishedAt.formatted(date: .abbreviated, time: .shortened)
                    )
                }

                LabeledContent("Container", value: CloudLibrarySchema.containerIdentifier)
                    .textSelection(.enabled)

                HStack {
                    Spacer()
                    Button("Publish Now") {
                        publisher.publishNow()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!syncEnabled || publisher.state.isBusy)
                }
            }

            Section("Mobile behavior") {
                Text("Only text, metadata, and the four summary variants are uploaded. The iPhone app generates speech on-device and does not store audio in Git or CloudKit.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .formStyle(.grouped)
    }

    private var statusSymbol: String {
        switch publisher.state {
        case .publishing:
            return "icloud.and.arrow.up"
        case .succeeded:
            return "checkmark.icloud.fill"
        case .failed, .unavailable:
            return "exclamationmark.icloud.fill"
        case .disabled:
            return "icloud.slash"
        case .idle:
            return "icloud"
        }
    }

    private var statusColor: Color {
        switch publisher.state {
        case .succeeded:
            return .green
        case .failed, .unavailable:
            return .red
        case .idle, .disabled, .publishing:
            return .secondary
        }
    }
}

private struct PeopleSettings: View {
    @EnvironmentObject var env: AppEnvironment
    @ObservedObject var peopleStore: GitHubPeopleStore
    @State private var organization = ""

    var body: some View {
        Form {
            Section("GitHub organization") {
                TextField("Organization", text: $organization)
                    .font(.system(.body, design: .monospaced))

                HStack(alignment: .firstTextBaseline) {
                    Text("People are read from the authenticated organization roster only when you request it.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Spacer()
                    Button("Sync People from GitHub") {
                        peopleStore.synchronize(organization: organization) {
                            env.sharedGitSyncCoordinator.requestAutomaticSync(
                                reason: "people directory refreshed"
                            )
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(
                        organization.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || peopleStore.state.isBusy
                    )
                }
            }

            Section("People directory") {
                LabeledContent("People", value: "\(peopleStore.people.count)")
                if let currentUser = peopleStore.currentUser {
                    LabeledContent("You", value: "\(currentUser.displayName) (@\(currentUser.login))")
                }
                LabeledContent("Folder") {
                    Text(
                        env.settings.sharedWorkspaceRootURL
                            .appendingPathComponent("people", isDirectory: true)
                            .path
                    )
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                }

                Label(peopleStore.state.message, systemImage: peopleStatusSymbol)
                    .foregroundStyle(peopleStatusColor)
                    .textSelection(.enabled)

                Text("Each login folder stores only profile.json with the stable GitHub ID and display name, plus shared and shared_with reference folders. Avatars and email addresses are not imported.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Section("Refresh behavior") {
                Text("The GitHub roster is never refreshed automatically. Repository synchronization remains automatic after a manual people refresh so other collaborators receive the updated directory.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            if organization.isEmpty {
                organization = env.settings.githubPeopleOrganization
            }
        }
    }

    private var peopleStatusSymbol: String {
        switch peopleStore.state {
        case .syncing:
            return "arrow.triangle.2.circlepath"
        case .succeeded:
            return "checkmark.circle.fill"
        case .failed:
            return "exclamationmark.triangle.fill"
        case .idle:
            return "person.3"
        }
    }

    private var peopleStatusColor: Color {
        switch peopleStore.state {
        case .succeeded:
            return .green
        case .failed:
            return .red
        case .idle, .syncing:
            return .secondary
        }
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

private enum RepositorySettingsPurpose: Equatable {
    case privateLibrary
    case sharedLibrary

    var repositorySectionTitle: String {
        switch self {
        case .privateLibrary: return "Workspace repository"
        case .sharedLibrary: return "Shared repository"
        }
    }

    var connectionHelp: String {
        switch self {
        case .privateLibrary:
            return "Connects the private workspace directly to origin. Authentication uses your existing GitHub CLI login."
        case .sharedLibrary:
            return "Connects the separate shared workspace to its own origin. Authentication uses your existing GitHub CLI login."
        }
    }

    var synchronizationHelp: String {
        switch self {
        case .privateLibrary:
            return "Sync commits local workspace changes and fetches the current branch. It rebases or pushes only when Git finds remote or local commits to apply."
        case .sharedLibrary:
            return "Share and Unshare mirror files into this repository. Sync fetches its current branch, then rebases or pushes only when needed."
        }
    }
}

private struct SyncSettings: View {
    @EnvironmentObject var env: AppEnvironment
    @ObservedObject var coordinator: GitSyncCoordinator
    let purpose: RepositorySettingsPurpose
    @State private var remote = ""
    @State private var newRepositoryName = ""
    @State private var newRepositoryVisibility = GitHubRepositoryVisibility.privateRepository
    @State private var sharedWorkspaceFolderPath = ""
    @State private var sharedWorkspaceFolderStatus: String?

    var body: some View {
        Form {
            if purpose == .sharedLibrary {
                Section("Shared folder") {
                    HStack {
                        TextField("Folder", text: $sharedWorkspaceFolderPath)
                            .onSubmit { applySharedWorkspaceFolder() }
                        Button("Choose...") { chooseSharedWorkspaceFolder() }
                        Button("Default") {
                            sharedWorkspaceFolderPath = env.settings.defaultSharedWorkspaceRootURL.path
                            applySharedWorkspaceFolder()
                        }
                    }

                    if let sharedWorkspaceFolderStatus {
                        Text(sharedWorkspaceFolderStatus)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Text("Shared captures and summaries are copied into this separate folder. The private workspace remains authoritative.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Text("Unshare removes files from the current shared tree, but previously pushed copies remain in Git history.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }

            Section("Prerequisites") {
                statusRow("Git", isReady: coordinator.repositoryStatus.gitAvailable)
                statusRow("GitHub CLI", isReady: coordinator.repositoryStatus.ghAvailable)
                statusRow("GitHub authentication", isReady: coordinator.repositoryStatus.ghAuthenticated)
            }

            Section(purpose.repositorySectionTitle) {
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
                Text(purpose.connectionHelp)
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

            Section("Background sync status") {
                Label(coordinator.state.message, systemImage: syncStatusSymbol)
                    .foregroundStyle(syncStatusColor)
                    .textSelection(.enabled)
                Text(purpose.synchronizationHelp)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            if purpose == .sharedLibrary {
                sharedWorkspaceFolderPath = env.settings.sharedWorkspaceRootURL.path
            }
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

    private func applySharedWorkspaceFolder() {
        let trimmed = sharedWorkspaceFolderPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let url = URL(
            fileURLWithPath: NSString(string: trimmed).expandingTildeInPath,
            isDirectory: true
        )
        do {
            try env.setSharedWorkspaceFolder(url)
            sharedWorkspaceFolderPath = url.path
            sharedWorkspaceFolderStatus = "Using \(url.path)"
            remote = ""
            newRepositoryName = coordinator.suggestedRepositoryName
        } catch {
            sharedWorkspaceFolderStatus = error.localizedDescription
        }
    }

    private func chooseSharedWorkspaceFolder() {
        let panel = NSOpenPanel()
        panel.canCreateDirectories = true
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.title = "Choose shared repository folder"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        sharedWorkspaceFolderPath = url.path
        applySharedWorkspaceFolder()
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
