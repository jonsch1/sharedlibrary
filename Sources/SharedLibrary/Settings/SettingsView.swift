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
            ConnectionSettings(
                googleDrive: env.googleDriveAuthorization,
                libraryPublisher: env.googleDriveLibraryPublisher
            )
                .tabItem { Label("Connections", systemImage: "network") }
            HotkeySettings()
                .tabItem { Label("Hotkeys", systemImage: "keyboard") }
        }
        .frame(width: 740, height: 720)
    }
}

private struct ConnectionSettings: View {
    @EnvironmentObject var env: AppEnvironment
    @ObservedObject var googleDrive: GoogleDriveAuthorizationCoordinator
    @ObservedObject var libraryPublisher: GoogleDriveLibraryPublisher

    var body: some View {
        Form {
            Section("Google Drive") {
                Text(googleIsConfigured
                    ? "Connect your own Google account. Shared Library mirrors its Markdown folder structure and stores generated audio in a visible “Shared Library” folder in your Drive, with fast local caches."
                    : "This build has not been configured with the Shared Library Google OAuth client yet. The distributor must add the Desktop Client ID and secret before accounts can connect.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)

                Text("The drive.file permission lets Shared Library access only the library and audio files it creates or that you explicitly open with it—not the rest of your Drive.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)

                Label(googleDrive.state.message, systemImage: googleStatusSymbol)
                    .foregroundStyle(googleStatusColor)
                    .textSelection(.enabled)

                HStack {
                    Spacer()
                    if case .connected = googleDrive.state {
                        Button("Disconnect") {
                            googleDrive.disconnect()
                        }
                    } else {
                        Button("Connect Google Drive") {
                            googleDrive.connect()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(
                            !googleIsConfigured || googleDrive.state.isBusy
                        )
                    }
                }
            }

            Section("Library synchronization") {
                Label(libraryPublisher.state.message, systemImage: snapshotStatusSymbol)
                    .foregroundStyle(snapshotStatusColor)
                    .textSelection(.enabled)

                LabeledContent("Local projection") {
                    Text(libraryPublisher.snapshotURL.path)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.trailing)
                        .textSelection(.enabled)
                }

                Text("Shared Library synchronizes automatically after meaningful changes and every few minutes while the app is running. Every connected client keeps the complete Markdown library and existing generated audio available locally.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Section("Share links") {
                Text("The Share button opens the web reader, where you can publish one document as a hard-to-guess, forwardable link. Only the selected document and any complete narration that already exists are copied to the sharing service.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            googleDrive.refreshStatus()
        }
        .onReceive(googleDrive.$state) { state in
            if case .connected = state {
                libraryPublisher.requestAutomaticUpdate(reason: "the library")
            }
        }
    }

    private var googleIsConfigured: Bool {
        !env.settings.googleDriveDesktopClientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !env.settings.googleDriveDesktopClientSecret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var googleStatusSymbol: String {
        switch googleDrive.state {
        case .connecting:
            return "arrow.triangle.2.circlepath"
        case .connected:
            return "checkmark.circle.fill"
        case .failed:
            return "exclamationmark.triangle.fill"
        case .disconnected:
            return "externaldrive.badge.questionmark"
        }
    }

    private var googleStatusColor: Color {
        switch googleDrive.state {
        case .connected:
            return .green
        case .failed:
            return .red
        case .disconnected, .connecting:
            return .secondary
        }
    }

    private var snapshotStatusSymbol: String {
        switch libraryPublisher.state {
        case .updating:
            return "arrow.triangle.2.circlepath"
        case .upToDate, .succeeded:
            return "checkmark.circle.fill"
        case .failed:
            return "exclamationmark.triangle.fill"
        case .idle:
            return "doc.badge.arrow.up"
        }
    }

    private var snapshotStatusColor: Color {
        switch libraryPublisher.state {
        case .upToDate, .succeeded:
            return .green
        case .failed:
            return .red
        case .idle, .updating:
            return .secondary
        }
    }
}

private struct PeopleSettings: View {
    @EnvironmentObject var env: AppEnvironment
    @ObservedObject var peopleStore: PeopleStore
    @State private var username = ""

    var body: some View {
        Form {
            Section("Your username") {
                TextField("Username", text: $username)
                    .font(.system(.body, design: .monospaced))
                    .onSubmit(saveUsername)

                HStack(alignment: .firstTextBaseline) {
                    Text("This is how other people find and tag you. Usernames are lowercase and unique within the shared library.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Spacer()
                    Button(peopleStore.currentUser == nil ? "Save Username" : "Update Username") {
                        saveUsername()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!PeopleDirectoryStore.isValidUsername(username))
                }
            }

            Section("People directory") {
                LabeledContent("People", value: "\(peopleStore.people.count)")
                if let currentUser = peopleStore.currentUser {
                    LabeledContent("You", value: "@\(currentUser.username)")
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

                Text("The group folder keeps one people.json directory of stable user IDs and searchable usernames. Shared items use one current record each; personal Inbox decisions stay in your private Drive.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Section("Find other users") {
                HStack(alignment: .firstTextBaseline) {
                    Text("Tagging searches every profile currently present in the shared people folder. Refresh after the shared folder receives changes from another person.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Spacer()
                    Button("Refresh Users") {
                        peopleStore.reloadFromDisk()
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            if username.isEmpty {
                username = peopleStore.currentUser?.username ?? env.settings.username
            }
        }
    }

    private func saveUsername() {
        peopleStore.saveUsername(username) {
            username = peopleStore.currentUser?.username ?? username
            NotificationCenter.default.post(name: .libraryDidChange, object: nil)
        }
    }

    private var peopleStatusSymbol: String {
        switch peopleStore.state {
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
        case .idle:
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
            env.googleDriveLibraryPublisher.requestAutomaticUpdate(reason: "the updated library")
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
            return "Connects the private workspace directly to origin. Authentication uses the GitHub App connection stored in your Keychain."
        case .sharedLibrary:
            return "Connects the separate shared workspace to its own origin. Authentication uses the GitHub App connection stored in your Keychain."
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
                statusRow("GitHub App configured", isReady: coordinator.repositoryStatus.githubAppConfigured)
                statusRow("GitHub App connected", isReady: coordinator.repositoryStatus.githubAuthenticated)
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
                Text("Create a private repository on GitHub first, then install the Shared Library GitHub App with access only to that repository. Connect accepts only an existing repository that the app can access.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
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
    @StateObject private var recorder = ShortcutRecorderController()

    var body: some View {
        Form {
            Section("Global hotkeys") {
                shortcutRow("Shared Library", name: .toggleLibrary)
                shortcutRow("Capture clipboard", name: .captureClipboard)
            }
            Text("Capture clipboard saves the current clipboard into library/.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .onDisappear {
            recorder.cancelRecording()
        }
    }

    private func shortcutRow(
        _ title: String,
        name: KeyboardShortcuts.Name
    ) -> some View {
        LabeledContent(title) {
            HStack(spacing: 8) {
                Button {
                    recorder.beginRecording(name)
                } label: {
                    Text(recorder.buttonTitle(for: name))
                        .frame(minWidth: 112)
                }
                .buttonStyle(.bordered)

                Button("Reset") {
                    recorder.reset(name)
                }
                .buttonStyle(.borderless)
            }
        }
    }
}

private final class ShortcutRecorderController: ObservableObject {
    @Published private(set) var recordingName: KeyboardShortcuts.Name?

    private var eventMonitor: Any?

    func buttonTitle(for name: KeyboardShortcuts.Name) -> String {
        if recordingName == name {
            return "Press shortcut…"
        }
        return KeyboardShortcuts.getShortcut(for: name).map(String.init(describing:))
            ?? "Not set"
    }

    func beginRecording(_ name: KeyboardShortcuts.Name) {
        cancelRecording()
        recordingName = name
        KeyboardShortcuts.isEnabled = false
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handle(event) ?? event
        }
    }

    func cancelRecording() {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }
        if recordingName != nil {
            recordingName = nil
            KeyboardShortcuts.isEnabled = true
        }
    }

    func reset(_ name: KeyboardShortcuts.Name) {
        cancelRecording()
        KeyboardShortcuts.reset(name)
        objectWillChange.send()
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        guard let recordingName else { return event }

        if event.keyCode == 53 {
            cancelRecording()
            return nil
        }

        if event.keyCode == 51 || event.keyCode == 117 {
            KeyboardShortcuts.setShortcut(nil, for: recordingName)
            cancelRecording()
            return nil
        }

        let modifiers = event.modifierFlags.intersection([
            .command,
            .option,
            .control,
            .shift
        ])
        guard !modifiers.isEmpty,
              let shortcut = KeyboardShortcuts.Shortcut(event: event) else {
            NSSound.beep()
            return nil
        }

        let otherName: KeyboardShortcuts.Name = recordingName == .toggleLibrary
            ? .captureClipboard
            : .toggleLibrary
        guard KeyboardShortcuts.getShortcut(for: otherName) != shortcut else {
            NSSound.beep()
            return nil
        }

        KeyboardShortcuts.setShortcut(shortcut, for: recordingName)
        cancelRecording()
        return nil
    }
}
