import AVFoundation
import BrieflyCore
import CloudKit
import Observation
import PDFKit
import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
import Carbon.HIToolbox
#elseif os(iOS)
import UIKit
#endif

enum LibrarySection: String, CaseIterable, Identifiable {
    case items
    case channels
    case briefs

    var id: Self { self }

    var title: String {
        switch self {
        case .items: "Item"
        case .channels: "Channel"
        case .briefs: "Voice brief"
        }
    }

    var icon: String {
        switch self {
        case .items: "doc"
        case .channels: "dot.radiowaves.left.and.right"
        case .briefs: "headphones"
        }
    }

    var searchPrompt: String {
        switch self {
        case .items: "Search items"
        case .channels: "Search channels"
        case .briefs: "Search voice briefs"
        }
    }
}

@MainActor
@Observable
final class LibraryModel {
    private static let managedAICommand =
        "briefly://openrouter/deepseek/deepseek-v4-flash"
    private static let defaultProcessingCommand: String = {
        #if os(iOS)
        managedAICommand
        #else
        defaultWorkspaceProcessingCommand
        #endif
    }()
    private static let processingCommandKey = "BrieflyProcessingCommand"
    private static let processingPromptKey = "BrieflyProcessingPrompt"
    private static let voiceBriefPromptKey = "BrieflyVoiceBriefPrompt"
    private static let aboutYouKey = "BrieflyAboutYou"
    private static let agentCommandKey = "BrieflyAgentCommand"
    private static let workspaceBookmarkKey = "BrieflyWorkspaceBookmark"
    private let backend = BrieflyBackend.shared
    private var cloud: CloudDocumentSync?
    private var started = false
    private var workspace: WorkspaceLibrary?
    private var securityScopedWorkspace: URL?
    private var pendingProcessingIDs = [String]()
    private var pendingSync: Task<Void, Never>?

    var projection = LibraryProjection.demo
    var activeSection = LibrarySection.briefs
    var selectedID = ""
    var selectedIDs = Set<String>()
    var selectedVoiceBriefID = ""
    var selectedChannelSource = ""
    var expandedVoiceBriefIDs = Set<String>()
    var expandedChannelSources = Set<String>()
    var selectedVariant = LibraryVariant.concise
    var selectedText = ""
    var highlightsText = ""
    var showingHighlights = false
    var query = ""
    var selectedTopic = "All"
    var isLoadingText = false
    var isIngesting = false
    var isSyncing = false
    var syncCompleted = 0
    var syncTotal = 0
    var isProcessing = false
    var isCheckingChannel = false
    var isRunningVoiceBrief = false
    var isCheckingAccount = false
    var isTestingAI = false
    var status = "Showing the sample library"
    var errorMessage: String?
    var workspacePath: String?
    var workspaceChannels = [LibraryChannel]()
    var topicsText = ""
    var account = BrieflyAccountStatus.signedOut
    var processingCommand =
        UserDefaults.standard.string(forKey: LibraryModel.processingCommandKey) ??
        LibraryModel.defaultProcessingCommand
    var processingPrompt =
        UserDefaults.standard.string(forKey: LibraryModel.processingPromptKey) ??
        defaultWorkspaceProcessingPrompt
    var voiceBriefPrompt =
        UserDefaults.standard.string(forKey: LibraryModel.voiceBriefPromptKey) ??
        defaultVoiceBriefPrompt
    var aboutYou =
        UserDefaults.standard.string(forKey: LibraryModel.aboutYouKey) ?? ""
    var agentCommand =
        UserDefaults.standard.string(forKey: LibraryModel.agentCommandKey) ??
        "/usr/bin/open -a ChatGPT {{workspace}}"

    var canEdit: Bool {
        workspace != nil
    }

    var usesManagedAI: Bool {
        processingCommand == Self.managedAICommand
    }

    var isWorking: Bool {
        isIngesting || isCheckingChannel || isProcessing || isRunningVoiceBrief ||
            isSyncing || isTestingAI
    }

    var menuBarActivity: String? {
        if isRunningVoiceBrief { return "Creating brief" }
        if isProcessing { return "Processing" }
        if isIngesting || isCheckingChannel { return "Ingesting" }
        if isSyncing { return "Syncing" }
        if isTestingAI { return "Testing" }
        return nil
    }

    var menuBarIcon: String {
        if isRunningVoiceBrief { return "waveform" }
        if isProcessing || isTestingAI { return "sparkles" }
        if isIngesting || isCheckingChannel { return "square.and.arrow.down" }
        if isSyncing { return "arrow.triangle.2.circlepath" }
        return "doc.text"
    }

    var selectedEntry: LibraryEntry? {
        projection.entries.first { $0.id == selectedID }
    }

    var highlightCount: Int {
        highlightsText.components(separatedBy: .newlines)
            .count { $0.hasPrefix("## ") }
    }

    var selectedVoiceBrief: LibraryVoiceBrief? {
        projection.voiceBriefDefinitions.first { $0.id == selectedVoiceBriefID }
    }

    var selectedChannel: LibraryChannel? {
        channels.first { $0.source == selectedChannelSource }
    }

    var filteredEntries: [LibraryEntry] {
        projection.entries.filter {
            $0.isMainLibraryEntry &&
                (selectedTopic == "All" || $0.topicNames.contains(selectedTopic)) &&
                $0.matches(query)
        }
    }

    var filteredVoiceBriefs: [LibraryVoiceBrief] {
        projection.voiceBriefDefinitions.filter { brief in
            brief.matches(query) ||
                projection.episodes(for: brief.id).contains { $0.matches(query) }
        }
    }

    var channels: [LibraryChannel] {
        if workspace != nil { return workspaceChannels }
        return projection.channelSources.map {
            LibraryChannel(source: $0, title: channelTitle($0))
        }
    }

    var filteredChannels: [LibraryChannel] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return channels }
        return channels.filter {
            $0.matches(needle) ||
                channelEntries(for: $0.source).contains { $0.matches(needle) }
        }
    }

    func channelEntries(for source: String) -> [LibraryEntry] {
        guard let channel = channels.first(where: { $0.source == source }) else {
            return projection.entries(forChannel: source)
        }
        let entryIDs = Set(channel.entryIDs)
        if entryIDs.isEmpty { return projection.entries(forChannel: source) }
        return projection.entries
            .filter { entryIDs.contains($0.id) }
            .sorted { ($0.createdAt ?? "") > ($1.createdAt ?? "") }
    }

    func start() async {
        guard !started else { return }
        started = true
        let usesDemo = ProcessInfo.processInfo.arguments.contains("--demo")
        if
            !usesDemo,
            let bookmark = UserDefaults.standard.data(
                forKey: Self.workspaceBookmarkKey
            ),
            let url = resolveWorkspaceBookmark(bookmark)
        {
            await openWorkspace(url)
            if workspace != nil {
                await refreshAccount()
                await runDueVoiceBriefs()
                return
            }
        }
        #if os(macOS)
        if
            !usesDemo,
            let path = UserDefaults.standard.string(forKey: "BrieflyWorkspacePath")
        {
            await openWorkspace(URL(fileURLWithPath: path))
            if workspace != nil {
                await refreshAccount()
                await runDueVoiceBriefs()
                return
            }
        }
        #endif
        if !usesDemo {
            let local = FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appending(path: "Briefly", directoryHint: .isDirectory)
            await openWorkspace(local)
        }
        await selectInitialContent()
        await refreshAccount()
        await runDueVoiceBriefs()
    }

    func openWorkspace(_ url: URL) async {
        let workspaceURL = url.standardizedFileURL
        if workspaceURL.startAccessingSecurityScopedResource() {
            securityScopedWorkspace?.stopAccessingSecurityScopedResource()
            securityScopedWorkspace = workspaceURL
        }
        do {
            let next = WorkspaceLibrary(root: workspaceURL)
            projection = try await next.loadProjection()
            workspaceChannels = try await next.loadChannels()
            highlightsText = try await next.loadHighlights()
            topicsText = try await next.topicDefinitions()
                .map { "\($0.id): \($0.title)" }
                .joined(separator: "\n")
            workspace = next
            cloud = try CloudDocumentSync(
                store: await next.documentDatabase(),
                containerIdentifier: "iCloud.fyi.readbriefly"
            )
            workspacePath = workspaceURL.path
            status = "Opened \(workspaceURL.lastPathComponent)"
            UserDefaults.standard.set(workspaceURL.path, forKey: "BrieflyWorkspacePath")
            if let bookmark = try? workspaceBookmark(for: workspaceURL) {
                UserDefaults.standard.set(bookmark, forKey: Self.workspaceBookmarkKey)
            }
            await selectInitialContent()
            #if os(iOS)
            await sync()
            #endif
        } catch {
            workspace = nil
            workspaceChannels = []
            workspacePath = nil
            errorMessage = error.localizedDescription
        }
    }

    #if os(macOS)
    func chooseWorkspace() {
        let panel = NSOpenPanel()
        panel.title = "Choose Briefly Workspace"
        panel.message = "Choose the folder that contains your Briefly database."
        panel.prompt = "Choose"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = workspacePath.map(URL.init(fileURLWithPath:))
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor [weak self] in
                await self?.openWorkspace(url)
            }
        }
    }
    #endif

    private func workspaceBookmark(for url: URL) throws -> Data {
        #if os(macOS)
        try url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        #else
        try url.bookmarkData(
            options: .minimalBookmark,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        #endif
    }

    private func resolveWorkspaceBookmark(_ data: Data) -> URL? {
        var stale = false
        #if os(macOS)
        let options = URL.BookmarkResolutionOptions.withSecurityScope
        #else
        let options: URL.BookmarkResolutionOptions = []
        #endif
        guard
            let url = try? URL(
                resolvingBookmarkData: data,
                options: options,
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            )
        else {
            return nil
        }
        if stale, let bookmark = try? workspaceBookmark(for: url) {
            UserDefaults.standard.set(bookmark, forKey: Self.workspaceBookmarkKey)
        }
        return url
    }

    func refreshWorkspace(selecting entryID: String? = nil) async {
        guard let workspace else { return }
        do {
            projection = try await workspace.loadProjection()
            workspaceChannels = try await workspace.loadChannels()
            highlightsText = try await workspace.loadHighlights()
            topicsText = try await workspace.topicDefinitions()
                .map { "\($0.id): \($0.title)" }
                .joined(separator: "\n")
            status = "Refreshed the local database"
            await restoreSelection(preferredEntryID: entryID)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func capture(_ text: String) async {
        guard let workspace else {
            errorMessage = "Open a Briefly library before capturing."
            return
        }
        isIngesting = true
        defer { isIngesting = false }
        do {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let url = URL(string: trimmed).flatMap {
                ["http", "https"].contains($0.scheme?.lowercased() ?? "") &&
                    $0.host != nil &&
                    !trimmed.contains(where: \.isWhitespace)
                    ? $0
                    : nil
            }
            let id: String
            if let url {
                status = "Extracting the signed-in page…"
                do {
                    id = try await ingestURL(url, in: workspace)
                } catch {
                    id = try await workspace.capture(trimmed)
                }
            } else {
                id = try await workspace.capture(trimmed)
            }
            await refreshWorkspace(selecting: id)
            activeSection = .items
            status = "Captured. Preparing summaries…"
            isIngesting = false
            await enqueueProcessing(id)
            requestSync()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func setBrowserIngesting(_ ingesting: Bool) {
        isIngesting = ingesting
        if ingesting {
            status = "Extracting the signed-in page…"
        }
    }

    func captureWebPage(url: URL, page: SignedInChannelPage) async {
        guard let workspace else {
            errorMessage = "Open a Briefly library before saving web pages."
            return
        }
        isIngesting = true
        defer { isIngesting = false }
        do {
            let id = try await workspace.captureWebPage(
                title: page.title,
                content: page.text,
                sourceURL: url,
                asVoiceBriefSource: activeSection == .channels,
                faviconData: page.faviconData,
                faviconFileExtension: page.faviconFileExtension
            )
            await refreshWorkspace(selecting: id)
            status = "Saved the signed-in page. Preparing summaries…"
            isIngesting = false
            await enqueueProcessing(id)
            requestSync()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func capturePDF(_ url: URL) async {
        guard let workspace else {
            errorMessage = "Choose a local Briefly workspace before importing a PDF."
            return
        }
        isIngesting = true
        defer { isIngesting = false }
        let hasAccess = url.startAccessingSecurityScopedResource()
        defer {
            if hasAccess { url.stopAccessingSecurityScopedResource() }
        }
        guard
            let document = PDFDocument(url: url),
            let text = document.string
        else {
            errorMessage = "Briefly could not read that PDF."
            return
        }
        let title = document.documentAttributes?[
            PDFDocumentAttribute.titleAttribute
        ] as? String ?? url.deletingPathExtension().lastPathComponent
        do {
            let entryID = try await workspace.captureDocument(
                title: title,
                content: text
            )
            await refreshWorkspace(selecting: entryID)
            status = "PDF captured. Preparing summaries…"
            isIngesting = false
            await enqueueProcessing(entryID)
            requestSync()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func saveText(
        _ text: String,
        entryID: String,
        variant: LibraryVariant
    ) async {
        guard let workspace, !entryID.isEmpty else { return }
        do {
            try await workspace.writeText(
                entryID: entryID,
                variant: variant,
                text: text
            )
            projection = try await workspace.loadProjection()
            if selectedID == entryID, selectedVariant == variant {
                selectedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            status = "Document saved"
            requestSync()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func addHighlight(_ text: String) async {
        guard let workspace, !selectedID.isEmpty else { return }
        do {
            try await workspace.addHighlight(
                entryID: selectedID,
                variant: selectedVariant,
                text: text
            )
            highlightsText = try await workspace.loadHighlights()
            status = "Added to Highlights"
            requestSync()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func removeHighlight(_ text: String) async {
        guard let workspace else { return }
        do {
            guard try await workspace.removeHighlight(text) else { return }
            highlightsText = try await workspace.loadHighlights()
            status = "Removed from Highlights"
            requestSync()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func showHighlights() {
        activeSection = .items
        selectedID = ""
        selectedIDs = []
        selectedText = ""
        showingHighlights = true
    }

    func showTopic(_ topic: String) async {
        selectedTopic = topic
        showingHighlights = false
        if !filteredEntries.contains(where: { $0.id == selectedID }) {
            await select(filteredEntries.first?.id ?? "")
        }
    }

    func trashSelected() async {
        guard let workspace else { return }
        let ids = selectedEntryIDs(fallback: selectedID)
        guard !ids.isEmpty else { return }
        do {
            for id in ids {
                try await workspace.moveToTrash(entryID: id)
            }
            selectedID = ""
            selectedIDs = []
            await refreshWorkspace()
            status = ids.count == 1
                ? "The document and its summaries were moved to Trash"
                : "\(ids.count) documents and their summaries were moved to Trash"
            requestSync()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @discardableResult
    func saveVoiceBrief(_ draft: LibraryVoiceBriefDraft) async -> String? {
        guard let workspace else {
            errorMessage = "Open a Briefly library before editing voice briefs."
            return nil
        }
        do {
            let id = try await workspace.saveVoiceBrief(draft)
            projection = try await workspace.loadProjection()
            workspaceChannels = try await workspace.loadChannels()
            activeSection = .briefs
            selectedID = ""
            selectedIDs = []
            selectedVoiceBriefID = id
            expandedVoiceBriefIDs.insert(id)
            status = "Voice brief saved"
            requestSync()
            return id
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func trashSelectedVoiceBrief() async {
        guard
            let workspace,
            !selectedVoiceBriefID.isEmpty,
            selectedVoiceBriefID != "new"
        else {
            return
        }
        do {
            try await workspace.moveVoiceBriefToTrash(id: selectedVoiceBriefID)
            projection = try await workspace.loadProjection()
            workspaceChannels = try await workspace.loadChannels()
            selectedVoiceBriefID = projection.voiceBriefDefinitions.first?.id ?? ""
            selectedID = ""
            selectedIDs = []
            status = "Voice brief moved to Trash"
            requestSync()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func selectedVoiceBriefFileURL() async -> URL? {
        guard
            let workspace,
            !selectedVoiceBriefID.isEmpty,
            selectedVoiceBriefID != "new"
        else {
            return nil
        }
        do {
            return try await workspace.voiceBriefFileURL(id: selectedVoiceBriefID)
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func addChannel(_ source: String) async {
        guard let workspace else {
            errorMessage = "Open a Briefly library before adding channels."
            return
        }
        do {
            try await workspace.addChannel(source)
            workspaceChannels = try await workspace.loadChannels()
            guard let added = workspaceChannels.first(where: {
                $0.source == source.trimmingCharacters(in: .whitespacesAndNewlines)
            }) else {
                throw WorkspaceError.missingChannel
            }
            selectedChannelSource = added.source
            expandedChannelSources.insert(added.source)
            status = "Channel added"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func updateSelectedChannel(retrievalCount: Int) async {
        guard let workspace, let channel = selectedChannel else { return }
        do {
            try await workspace.updateChannel(
                channel.source,
                retrievalCount: retrievalCount
            )
            workspaceChannels = try await workspace.loadChannels()
            status = "Channel settings saved"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func checkSelectedChannel(loadMore: Bool = false) async {
        guard
            let workspace,
            let channel = selectedChannel,
            !isCheckingChannel
        else {
            return
        }
        isCheckingChannel = true
        status = loadMore ? "Loading more from \(channel.title)…" : "Checking \(channel.title)…"
        defer { isCheckingChannel = false }
        do {
            let result: LibraryChannelRefresh
            result = try await retrieveChannel(
                workspace,
                source: channel.source,
                loadMore: loadMore
            )
            projection = try await workspace.loadProjection()
            workspaceChannels = try await workspace.loadChannels()
            selectedChannelSource = result.channel.source
            expandedChannelSources.insert(result.channel.source)
            status = result.newEntryIDs.isEmpty
                ? "Channel checked. No new items."
                : "Gathered \(result.newEntryIDs.count) new " +
                    (result.newEntryIDs.count == 1 ? "item" : "items")
            for entryID in result.newEntryIDs {
                await enqueueProcessing(entryID)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func removeSelectedChannel() async {
        guard let workspace, let channel = selectedChannel else { return }
        do {
            try await workspace.removeChannel(channel.source)
            projection = try await workspace.loadProjection()
            workspaceChannels = try await workspace.loadChannels()
            expandedChannelSources.remove(channel.source)
            selectedChannelSource = workspaceChannels.first?.source ?? ""
            selectedID = ""
            selectedIDs = []
            status = "Channel removed"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func checkSelectedVoiceBriefChannels() async {
        guard
            let workspace,
            let brief = selectedVoiceBrief,
            !isRunningVoiceBrief
        else {
            return
        }
        isRunningVoiceBrief = true
        defer { isRunningVoiceBrief = false }
        do {
            status = "Checking \(brief.sources.count) " +
                (brief.sources.count == 1 ? "channel…" : "channels…")
            var newEntryIDs = [String]()
            for source in brief.sources {
                let result = try await retrieveChannel(workspace, source: source)
                newEntryIDs += result.newEntryIDs
            }
            projection = try await workspace.loadProjection()
            workspaceChannels = try await workspace.loadChannels()
            for entryID in newEntryIDs {
                await enqueueProcessing(entryID)
            }
            status = newEntryIDs.isEmpty
                ? "Channels checked. No new items."
                : "Prepared \(newEntryIDs.count) new " +
                    (newEntryIDs.count == 1 ? "item" : "items")
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func runSelectedVoiceBrief() async {
        guard let brief = selectedVoiceBrief else { return }
        await generateVoiceBrief(brief, selectEpisode: true, reportErrors: true)
    }

    func runDueVoiceBriefs() async {
        guard let workspace, !isRunningVoiceBrief else { return }
        do {
            let due = try await workspace.dueVoiceBriefIDs()
            for id in due {
                guard let brief = projection.voiceBriefDefinitions.first(where: {
                    $0.id == id
                }) else {
                    continue
                }
                try await workspace.markVoiceBriefAttempt(id: id)
                await generateVoiceBrief(
                    brief,
                    selectEpisode: false,
                    reportErrors: false
                )
            }
        } catch {
            status = "Scheduled voice briefs will retry later"
        }
    }

    private func generateVoiceBrief(
        _ brief: LibraryVoiceBrief,
        selectEpisode: Bool,
        reportErrors: Bool
    ) async {
        guard let workspace, !isRunningVoiceBrief else { return }
        isRunningVoiceBrief = true
        defer { isRunningVoiceBrief = false }
        let audioURL = FileManager.default.temporaryDirectory.appending(
            path: "\(UUID().uuidString).wav"
        )
        defer { try? FileManager.default.removeItem(at: audioURL) }
        do {
            status = "Checking channels for \(brief.title)…"
            var newEntryIDs = [String]()
            for source in brief.sources {
                newEntryIDs += try await retrieveChannel(
                    workspace,
                    source: source
                ).newEntryIDs
            }
            projection = try await workspace.loadProjection()
            workspaceChannels = try await workspace.loadChannels()
            for entryID in newEntryIDs {
                await enqueueProcessing(entryID)
            }
            status = "Writing \(brief.title)…"
            let episode: LibraryVoiceBriefEpisodeResult
            if usesManagedAI {
                episode = try await workspace.runVoiceBrief(
                    id: brief.id,
                    command: processingCommand,
                    promptTemplate: voiceBriefPrompt,
                    personalContext: aboutYou
                ) {
                    try await BrieflyBackend.shared.runManagedAI(
                        prompt: $0,
                        format: "text"
                    )
                }
            } else {
                episode = try await workspace.runVoiceBrief(
                    id: brief.id,
                    command: processingCommand,
                    promptTemplate: voiceBriefPrompt,
                    personalContext: aboutYou
                )
            }
            status = "Creating spoken audio…"
            try await synthesizeVoiceBriefAudio(
                spokenVoiceBriefText(episode.script),
                to: audioURL
            )
            try await workspace.attachAudio(entryID: episode.entryID, file: audioURL)
            projection = try await workspace.loadProjection()
            workspaceChannels = try await workspace.loadChannels()
            expandedVoiceBriefIDs.insert(brief.id)
            if selectEpisode {
                selectedVoiceBriefID = brief.id
                await select(episode.entryID)
            }
            status = "Voice brief ready"
            requestSync()
        } catch {
            if reportErrors {
                errorMessage = error.localizedDescription
            } else {
                status = "\(brief.title): \(error.localizedDescription)"
            }
        }
    }

    func processSelected() async {
        guard !selectedID.isEmpty else { return }
        await enqueueProcessing(selectedID)
    }

    func openAgent() {
        guard let workspacePath else {
            errorMessage = "Open a Briefly library before opening an agent."
            return
        }
        #if os(macOS)
        let normalized = agentCommand.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        if normalized.hasPrefix("claude://") {
            let encoded = workspacePath.addingPercentEncoding(
                withAllowedCharacters: .urlQueryAllowed
            ) ?? workspacePath
            guard let url = URL(
                string: normalized.replacingOccurrences(
                    of: "{{workspace}}",
                    with: encoded
                )
            ) else {
                errorMessage = "The agent URL is invalid."
                return
            }
            NSWorkspace.shared.open(url)
            status = "Opened the agent at the library workspace"
            return
        }
        if normalized == "/usr/bin/open -a ChatGPT {{workspace}}" {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = ["-a", "ChatGPT", workspacePath]
            do {
                try process.run()
                status = "Opened ChatGPT at the library workspace"
            } catch {
                errorMessage = error.localizedDescription
            }
            return
        }
        let quotedWorkspace =
            "'\(workspacePath.replacingOccurrences(of: "'", with: "'\"'\"'"))'"
        let command = (normalized.contains("{{workspace}}")
            ? normalized
            : "cd {{workspace}} && \(normalized)")
            .replacingOccurrences(of: "{{workspace}}", with: quotedWorkspace)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        let script = """
        tell application "Terminal"
          activate
          do script "\(appleScriptEscaped(command))"
        end tell
        """
        process.arguments = ["-e", script]
        do {
            try process.run()
            status = "Opened the agent at the library workspace"
        } catch {
            errorMessage = error.localizedDescription
        }
        #else
        UIApplication.shared.open(URL(string: "https://chatgpt.com")!)
        #endif
    }

    func saveProcessingSettings() {
        let command = processingCommand.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let prompt = processingPrompt.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !command.isEmpty, command.count <= 4_000 else {
            errorMessage = "The AI command must contain 1–4,000 characters."
            return
        }
        guard
            !prompt.isEmpty,
            prompt.count <= 50_000,
            prompt.contains("{{topics}}"),
            prompt.contains("{{source}}")
        else {
            errorMessage =
                "The processing prompt must contain {{topics}} and {{source}}."
            return
        }
        processingCommand = command
        processingPrompt = prompt
        UserDefaults.standard.set(command, forKey: Self.processingCommandKey)
        UserDefaults.standard.set(prompt, forKey: Self.processingPromptKey)
        status = "AI processing settings saved"
    }

    func saveAgentSettings() {
        let command = agentCommand.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !command.isEmpty, command.count <= 4_000 else {
            errorMessage = "The agent command must contain 1–4,000 characters."
            return
        }
        agentCommand = command
        UserDefaults.standard.set(command, forKey: Self.agentCommandKey)
        status = "Agent settings saved"
    }

    func testProcessingCommand() async {
        guard !isTestingAI else { return }
        isTestingAI = true
        defer { isTestingAI = false }
        do {
            let prompt = "Reply with exactly: Briefly is ready."
            let output: String
            if usesManagedAI {
                output = try await backend.runManagedAI(prompt: prompt, format: "text")
            } else {
                #if os(macOS)
                output = try await runWorkspaceProcessingCommand(
                    processingCommand,
                    prompt: prompt,
                    timeout: 60
                )
                #else
                throw WorkspaceError.processingUnavailable
                #endif
            }
            guard output.localizedCaseInsensitiveContains("Briefly is ready") else {
                throw NativeLibraryError.unexpectedAIResponse
            }
            status = "Processing command works"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func useManagedAI(_ enabled: Bool) {
        processingCommand = enabled
            ? Self.managedAICommand
            : defaultWorkspaceProcessingCommand
    }

    func savePersonalizationSettings() {
        let context = aboutYou.trimmingCharacters(in: .whitespacesAndNewlines)
        let prompt = voiceBriefPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard context.count <= 10_000 else {
            errorMessage = "Personal context must be 10,000 characters or fewer."
            return
        }
        guard
            !prompt.isEmpty,
            prompt.count <= 50_000,
            prompt.contains("{{voice_brief_title}}"),
            prompt.contains("{{requested_length}}"),
            prompt.contains("{{source_packets}}")
        else {
            errorMessage =
                "The voice brief prompt must contain its title, length, and source placeholders."
            return
        }
        aboutYou = context
        voiceBriefPrompt = prompt
        UserDefaults.standard.set(context, forKey: Self.aboutYouKey)
        UserDefaults.standard.set(prompt, forKey: Self.voiceBriefPromptKey)
        status = "Personalization settings saved"
    }

    func saveTopics() async {
        guard let workspace else { return }
        do {
            let definitions = try topicsText
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .map { line -> LibraryTopicDefinition in
                    guard let separator = line.firstIndex(of: ":") else {
                        throw BrieflyBackendError.message(
                            "Write each topic as “id: Title”."
                        )
                    }
                    return LibraryTopicDefinition(
                        id: String(line[..<separator])
                            .trimmingCharacters(in: .whitespaces),
                        title: String(line[line.index(after: separator)...])
                            .trimmingCharacters(in: .whitespaces)
                    )
                }
            let saved = try await workspace.replaceTopicDefinitions(definitions)
            topicsText = saved.map { "\($0.id): \($0.title)" }
                .joined(separator: "\n")
            projection = try await workspace.loadProjection()
            status = "Topics saved"
            requestSync()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func refreshAccount(reportErrors: Bool = false) async {
        guard !isCheckingAccount else { return }
        isCheckingAccount = true
        defer { isCheckingAccount = false }
        do {
            account = try await backend.accountStatus()
        } catch {
            account = .signedOut
            if reportErrors { errorMessage = error.localizedDescription }
        }
    }

    func signOut() async {
        do {
            try await backend.signOut()
            account = .signedOut
            status = "Signed out of Briefly"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func shareStatus(for entry: LibraryEntry) async throws -> BrieflyShareLinkStatus {
        guard let captureID = entry.captureID else {
            throw BrieflyBackendError.message("This document cannot be published.")
        }
        return try await backend.shareStatus(captureID: captureID)
    }

    func publishShare(for entry: LibraryEntry) async throws -> BrieflyShareLinkStatus {
        guard let captureID = entry.captureID else {
            throw BrieflyBackendError.message("This document cannot be published.")
        }
        let filename: String
        if let workspace {
            filename = try await workspace.fileURL(entryID: entry.id).lastPathComponent
        } else {
            filename = "\(captureID).md"
        }
        var texts = [BrieflyShareSource.Text]()
        for reference in entry.texts where reference.variant != .source {
            let markdown = (reference.text ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !markdown.isEmpty {
                texts.append(.init(variant: reference.variant.rawValue, markdown: markdown))
            }
        }
        guard !texts.isEmpty else {
            throw BrieflyBackendError.message(
                "Create at least one summary before publishing this document."
            )
        }
        let source = BrieflyShareSource(
            filename: filename,
            title: entry.title,
            excerpt: entry.excerpt,
            topicIDs: entry.topicIDs,
            topicNames: entry.topicNames,
            tags: entry.tags,
            sourceURL: entry.sourceURL,
            createdAt: entry.createdAt,
            updatedAt: entry.updatedAt,
            texts: texts
        )
        var result = try await backend.publishShare(
            captureID: captureID,
            source: source
        )
        for _ in 0..<30 where result.status == "preparing" {
            try await Task.sleep(for: .seconds(1))
            result = try await backend.shareStatus(captureID: captureID)
        }
        if result.status == "failed" {
            throw BrieflyBackendError.message(
                result.error ?? "The shareable reader could not be prepared."
            )
        }
        return result
    }

    func revokeShare(_ token: String) async throws {
        try await backend.revokeShare(token: token)
    }

    func selectedFileURL() async -> URL? {
        guard let workspace, !selectedID.isEmpty else { return nil }
        do {
            return try await workspace.fileURL(entryID: selectedID)
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func copyFilePaths(for entryID: String) async {
        guard let workspace else { return }
        do {
            var paths = [String]()
            for id in selectedEntryIDs(fallback: entryID) {
                paths.append(try await workspace.fileURL(entryID: id).path)
            }
            #if os(macOS)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(paths.joined(separator: "\n"), forType: .string)
            #else
            UIPasteboard.general.string = paths.joined(separator: "\n")
            #endif
            status = paths.count == 1 ? "Path copied" : "\(paths.count) paths copied"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func selectedFileURLs(for entryID: String) async -> [URL] {
        guard let workspace else { return [] }
        do {
            var urls = [URL]()
            for id in selectedEntryIDs(fallback: entryID) {
                urls.append(try await workspace.fileURL(entryID: id))
            }
            return urls
        } catch {
            errorMessage = error.localizedDescription
            return []
        }
    }

    func audioURL(for entryID: String) async -> URL? {
        do {
            if let workspace {
                return try await workspace.audioURL(entryID: entryID)
            }
            return nil
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func faviconURL(for entryID: String) async -> URL? {
        if let workspace {
            return try? await workspace.faviconURL(entryID: entryID)
        }
        return nil
    }

    func show(_ section: LibrarySection) async {
        activeSection = section
        showingHighlights = false
        query = ""
        selectedID = ""
        selectedIDs = []
        switch section {
        case .items:
            await select(filteredEntries.first?.id ?? "")
        case .channels:
            #if os(iOS)
            selectedChannelSource = ""
            #else
            selectedChannelSource = channels.first?.source ?? ""
            #endif
        case .briefs:
            #if os(iOS)
            selectedVoiceBriefID = ""
            #else
            selectedVoiceBriefID = projection.voiceBriefDefinitions.first?.id ?? ""
            if let id = selectedVoiceBriefID.isEmpty ? nil : selectedVoiceBriefID {
                expandedVoiceBriefIDs.insert(id)
                await select(projection.episodes(for: id).first?.id ?? "")
            }
            #endif
        }
    }

    func select(_ id: String, extending: Bool = false) async {
        showingHighlights = false
        if extending {
            if selectedIDs.remove(id) != nil {
                if selectedID == id {
                    selectedID = selectedEntryIDs(fallback: "").last ?? ""
                }
            } else {
                selectedIDs.insert(id)
                selectedID = id
            }
        } else {
            selectedID = id
            selectedIDs = id.isEmpty ? [] : [id]
        }
        guard let entry = selectedEntry else {
            selectedText = ""
            return
        }
        if let voiceBriefID = entry.voiceBriefID, !selectedVoiceBriefID.isEmpty {
            selectedVoiceBriefID = voiceBriefID
            expandedVoiceBriefIDs.insert(voiceBriefID)
        }
        selectedVariant = entry.preferredVariant
        await loadSelectedText()
    }

    private func selectedEntryIDs(fallback: String) -> [String] {
        let ids = !fallback.isEmpty && !selectedIDs.contains(fallback)
            ? Set([fallback])
            : selectedIDs
        return projection.entries.compactMap { ids.contains($0.id) ? $0.id : nil }
    }

    func selectionCount(for entryID: String) -> Int {
        selectedIDs.contains(entryID) ? selectedIDs.count : 1
    }

    func selectVoiceBrief(_ id: String) {
        showingHighlights = false
        selectedID = ""
        selectedIDs = []
        selectedVoiceBriefID = id
        if expandedVoiceBriefIDs.contains(id) {
            expandedVoiceBriefIDs.remove(id)
        } else {
            expandedVoiceBriefIDs.insert(id)
        }
    }

    func selectChannel(_ source: String) {
        showingHighlights = false
        selectedID = ""
        selectedIDs = []
        selectedChannelSource = source
        if expandedChannelSources.contains(source) {
            expandedChannelSources.remove(source)
        } else {
            expandedChannelSources.insert(source)
        }
    }

    func selectVariant(_ variant: LibraryVariant) async {
        selectedVariant = variant
        await loadSelectedText()
    }

    func sync() async {
        guard !isSyncing else { return }
        isSyncing = true
        syncCompleted = 0
        syncTotal = 0
        defer {
            isSyncing = false
            syncCompleted = 0
            syncTotal = 0
        }
        do {
            guard let workspace, let cloud else {
                throw NativeLibraryError.emptyICloudLibrary
            }
            guard try await cloud.accountStatus() == .available else {
                throw NativeLibraryError.iCloudUnavailable
            }
            status = "Synchronizing records…"
            try await cloud.synchronize()
            projection = try await workspace.loadProjection()
            workspaceChannels = try await workspace.loadChannels()
            highlightsText = try await workspace.loadHighlights()
            status = "Everything is up to date"
            await restoreSelection()
        } catch {
            errorMessage = error.localizedDescription
            status = "Using the last complete offline library"
        }
    }

    func clearError() {
        errorMessage = nil
    }

    private func enqueueProcessing(_ entryID: String) async {
        if !pendingProcessingIDs.contains(entryID) {
            pendingProcessingIDs.append(entryID)
        }
        guard !isProcessing else { return }
        isProcessing = true
        defer { isProcessing = false }
        while !pendingProcessingIDs.isEmpty {
            let nextID = pendingProcessingIDs.removeFirst()
            await process(nextID)
        }
    }

    private func requestSync() {
        guard account.syncProvider == "icloud" else { return }
        pendingSync?.cancel()
        pendingSync = Task {
            try? await Task.sleep(for: .milliseconds(900))
            guard !Task.isCancelled else { return }
            await sync()
        }
    }

    private func retrieveChannel(
        _ workspace: WorkspaceLibrary,
        source: String,
        loadMore: Bool = false
    ) async throws -> LibraryChannelRefresh {
        let ingest: @Sendable (LibraryChannelCandidate) async throws -> String = {
            candidate in
            guard let url = URL(string: candidate.url) else {
                throw WorkspaceError.invalidChannel
            }
            return try await self.ingestURL(
                url,
                in: workspace,
                candidate: candidate,
                asVoiceBriefSource: true
            )
        }
        let host = URL(string: source)?.host?.lowercased() ?? ""
        if host == "x.com" || host.hasSuffix(".x.com") || host.contains("twitter.com") {
            guard let url = URL(string: source) else {
                throw WorkspaceError.invalidChannel
            }
            let page = try await ChannelBrowserSession.shared.extractPage(from: url)
            if !page.items.isEmpty {
                return try await workspace.captureSignedInChannelItems(
                    source: source,
                    title: page.title,
                    items: page.items.map {
                        LibraryChannelCandidate(
                            id: $0.id,
                            title: $0.title,
                            url: $0.url,
                            publishedAt: $0.publishedAt,
                            content: $0.content
                        )
                    },
                    ingest: ingest
                )
            }
            return try await workspace.captureSignedInChannelPage(
                source: source,
                title: page.title,
                content: page.text,
                ingest: ingest
            )
        }
        if loadMore {
            return try await workspace.loadMoreChannel(source, ingest: ingest)
        }
        return try await workspace.checkChannel(source, ingest: ingest)
    }

    private func ingestURL(
        _ url: URL,
        in workspace: WorkspaceLibrary,
        candidate: LibraryChannelCandidate? = nil,
        asVoiceBriefSource: Bool = false
    ) async throws -> String {
        do {
            let page = try await ChannelBrowserSession.shared.extractPage(from: url)
            return try await workspace.captureWebPage(
                title: page.title,
                content: page.text,
                sourceURL: url,
                asVoiceBriefSource: asVoiceBriefSource,
                faviconData: page.faviconData,
                faviconFileExtension: page.faviconFileExtension
            )
        } catch {
            guard
                let candidate,
                !candidate.content.trimmingCharacters(
                    in: .whitespacesAndNewlines
                ).isEmpty
            else {
                throw error
            }
            return try await workspace.captureWebPage(
                title: candidate.title,
                content: candidate.content,
                sourceURL: url,
                asVoiceBriefSource: asVoiceBriefSource
            )
        }
    }

    private func process(_ entryID: String) async {
        guard let workspace else { return }
        do {
            status = "Preparing summaries…"
            let prompt = try await workspace.processingPrompt(
                entryID: entryID,
                template: processingPrompt
            )
            let output: String
            if usesManagedAI {
                output = try await backend.runManagedAI(
                    prompt: prompt,
                    format: "json"
                )
            } else {
                #if os(macOS)
                output = try await runWorkspaceProcessingCommand(
                    processingCommand,
                    prompt: prompt
                )
                #else
                throw WorkspaceError.processingUnavailable
                #endif
            }
            let suggestion = try WorkspaceProcessingSuggestion.decode(output)
            let processedID = try await workspace.applyProcessingSuggestion(
                entryID: entryID,
                suggestion: suggestion
            )
            await refreshWorkspace(selecting: processedID)
            status = "Summaries ready"
            requestSync()
        } catch {
            errorMessage = error.localizedDescription
            status = "The capture is saved without summaries"
        }
    }

    private func selectInitialContent() async {
        showingHighlights = false
        expandedVoiceBriefIDs = Set(projection.voiceBriefDefinitions.map(\.id))
        expandedChannelSources = Set(channels.map(\.source))
        let briefWithEpisode = projection.voiceBriefDefinitions.lazy.compactMap { brief in
            self.projection.episodes(for: brief.id).first.map { (brief, $0) }
        }.first
        if let (brief, episode) = briefWithEpisode {
            activeSection = .briefs
            #if os(iOS)
            selectedVoiceBriefID = ""
            selectedID = ""
            selectedIDs = []
            selectedText = ""
            #else
            selectedVoiceBriefID = brief.id
            await select(episode.id)
            #endif
        } else {
            activeSection = .items
            await select(projection.entries.first(where: \.isMainLibraryEntry)?.id ?? "")
        }
    }

    private func restoreSelection(preferredEntryID: String? = nil) async {
        if showingHighlights {
            selectedID = ""
            selectedIDs = []
            selectedText = ""
            return
        }
        let entryID = preferredEntryID ?? selectedID
        if projection.entries.contains(where: { $0.id == entryID }) {
            await select(entryID)
            return
        }

        selectedID = ""
        selectedIDs = []
        switch activeSection {
        case .items:
            await select(filteredEntries.first?.id ?? "")
        case .channels:
            if selectedChannelSource != "new" &&
                !channels.contains(where: { $0.source == selectedChannelSource })
            {
                selectedChannelSource = channels.first?.source ?? ""
            }
        case .briefs:
            if selectedVoiceBriefID != "new" &&
                !projection.voiceBriefDefinitions.contains(where: {
                    $0.id == selectedVoiceBriefID
                })
            {
                selectedVoiceBriefID = projection.voiceBriefDefinitions.first?.id ?? ""
            }
        }
    }

    private func loadSelectedText() async {
        guard
            let entry = selectedEntry,
            let reference = entry.text(for: selectedVariant)
        else {
            selectedText = ""
            return
        }
        isLoadingText = true
        defer { isLoadingText = false }
        selectedText = reference.text ?? ""
    }

    private func loadHighlights() async {
        if let workspace {
            highlightsText = (try? await workspace.loadHighlights()) ?? ""
            return
        }
        highlightsText = ""
    }
}

@MainActor
private func synthesizeVoiceBriefAudio(_ text: String, to url: URL) async throws {
    guard !text.isEmpty else { throw NativeLibraryError.emptySpeech }
    let synthesizer = AVSpeechSynthesizer()
    let utterance = AVSpeechUtterance(string: text)
    try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<Void, Error>) in
        var file: AVAudioFile?
        var finished = false
        synthesizer.write(utterance) { [synthesizer] buffer in
            guard !finished else { return }
            _ = synthesizer
            guard let pcm = buffer as? AVAudioPCMBuffer else {
                finished = true
                continuation.resume(throwing: NativeLibraryError.audioGenerationFailed)
                return
            }
            if pcm.frameLength == 0 {
                finished = true
                if file == nil {
                    continuation.resume(throwing: NativeLibraryError.audioGenerationFailed)
                } else {
                    continuation.resume()
                }
                return
            }
            do {
                if file == nil {
                    file = try AVAudioFile(
                        forWriting: url,
                        settings: pcm.format.settings
                    )
                }
                try file?.write(from: pcm)
            } catch {
                finished = true
                synthesizer.stopSpeaking(at: .immediate)
                continuation.resume(throwing: error)
            }
        }
    }
}

@Observable
private final class NativeAudioPlayer: NSObject, AVAudioPlayerDelegate {
    private var player: AVAudioPlayer?
    private var currentURL: URL?
    private var positionKey: String?
    private var timer: Timer?
    var isPlaying = false
    var currentTime = 0.0
    var duration = 0.0
    var rate = UserDefaults.standard.double(forKey: "BrieflyAudioRate").nonzero ?? 1
    var volume = UserDefaults.standard.object(forKey: "BrieflyAudioVolume") == nil
        ? 1
        : UserDefaults.standard.double(forKey: "BrieflyAudioVolume")

    func toggle(_ url: URL, entryID: String) throws {
        if currentURL == url, let player {
            if player.isPlaying {
                player.pause()
                isPlaying = false
                savePosition()
            } else {
                player.play()
                isPlaying = true
                startTimer()
            }
            return
        }
        stop()
        let player = try AVAudioPlayer(contentsOf: url)
        player.delegate = self
        player.enableRate = true
        player.rate = Float(rate)
        player.volume = Float(volume)
        player.prepareToPlay()
        let key = "BrieflyAudioPosition.\(entryID)"
        let saved = UserDefaults.standard.double(forKey: key)
        if saved > 0, saved < player.duration - 3 {
            player.currentTime = saved
        }
        player.play()
        self.player = player
        currentURL = url
        positionKey = key
        isPlaying = true
        currentTime = player.currentTime
        duration = player.duration
        startTimer()
    }

    func seek(_ time: Double) {
        guard let player else { return }
        player.currentTime = min(max(0, time), player.duration)
        currentTime = player.currentTime
        savePosition()
    }

    func setRate(_ value: Double) {
        rate = value
        player?.rate = Float(value)
        UserDefaults.standard.set(value, forKey: "BrieflyAudioRate")
    }

    func setVolume(_ value: Double) {
        volume = value
        player?.volume = Float(value)
        UserDefaults.standard.set(value, forKey: "BrieflyAudioVolume")
    }

    func stop() {
        savePosition()
        timer?.invalidate()
        timer = nil
        player?.stop()
        player = nil
        currentURL = nil
        positionKey = nil
        isPlaying = false
        currentTime = 0
        duration = 0
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        timer?.invalidate()
        timer = nil
        isPlaying = false
        currentTime = 0
        if let positionKey {
            UserDefaults.standard.removeObject(forKey: positionKey)
        }
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) {
            [weak self] _ in
            guard let self, let player = self.player else { return }
            self.currentTime = player.currentTime
            self.duration = player.duration
            self.isPlaying = player.isPlaying
        }
    }

    private func savePosition() {
        guard let player, let positionKey else { return }
        UserDefaults.standard.set(player.currentTime, forKey: positionKey)
    }
}

private extension Double {
    var nonzero: Double? { self == 0 ? nil : self }
}

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("BrieflyAppearance") private var appearance = "system"
    @Bindable var model: LibraryModel
    @State private var showsChannelBrowser = false
    @State private var showsSettings = false
    @State private var showsWorkspaceImporter = false
    @State private var showsPDFImporter = false
    @State private var sidebarVisible = true
    @State private var windowControlsVisible = true
    @State private var audioPlayer = NativeAudioPlayer()
    #if os(iOS)
    @State private var preferredCompactColumn = NavigationSplitViewColumn.sidebar
    #endif

    var body: some View {
        Group {
            #if os(macOS)
            HStack(spacing: 6) {
                if sidebarVisible {
                    LibrarySidebar(
                        model: model,
                        showsSettings: $showsSettings,
                        showsWorkspaceImporter: $showsWorkspaceImporter,
                        sidebarVisible: $sidebarVisible,
                        reservesWindowControls: windowControlsVisible
                    )
                    .frame(width: 326)
                    .transition(.move(edge: .leading).combined(with: .opacity))
                }

                LibraryDetail(
                    model: model,
                    showsChannelBrowser: $showsChannelBrowser,
                    audioPlayer: audioPlayer
                )
                .overlay(alignment: .topLeading) {
                    if !sidebarVisible {
                        Button {
                            withAnimation(.snappy(duration: 0.18)) {
                                sidebarVisible = true
                            }
                        } label: {
                            Image(systemName: "sidebar.left")
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .frame(width: 64, height: 45)
                        .padding(.leading, windowControlsVisible ? 72 : 0)
                        .keyboardShortcut("s", modifiers: [.command, .control])
                        .accessibilityLabel("Show sidebar")
                        .help("Show sidebar")
                    }
                }
            }
            .padding(6)
            .background(appBackground)
            .ignoresSafeArea(.container, edges: .top)
            .background(
                WindowControlPositioner(
                    x: 10,
                    y: -12,
                    controlsVisible: $windowControlsVisible
                )
            )
            #else
            NavigationSplitView(preferredCompactColumn: $preferredCompactColumn) {
                LibrarySidebar(
                    model: model,
                    showsSettings: $showsSettings,
                    showsWorkspaceImporter: $showsWorkspaceImporter,
                    sidebarVisible: .constant(true),
                    onOpenDetail: { preferredCompactColumn = .detail }
                )
                .navigationSplitViewColumnWidth(min: 285, ideal: 326)
            } detail: {
                LibraryDetail(
                    model: model,
                    showsChannelBrowser: $showsChannelBrowser,
                    audioPlayer: audioPlayer
                )
            }
            #endif
        }
        .task { await model.start() }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled else { return }
                await model.runDueVoiceBriefs()
            }
        }
        .onChange(of: scenePhase) {
            if scenePhase == .active {
                Task { await model.runDueVoiceBriefs() }
            }
        }
        .sheet(isPresented: $showsChannelBrowser) {
            if model.canEdit {
                ChannelLoginView(
                    initialAddress: model.selectedChannelSource,
                    onCapture: { url, page in
                        await model.captureWebPage(url: url, page: page)
                    },
                    onActivity: model.setBrowserIngesting
                )
            } else {
                ChannelLoginView(initialAddress: model.selectedChannelSource)
            }
        }
        .sheet(isPresented: $showsSettings) {
            SettingsView(
                model: model
            )
        }
        .fileImporter(
            isPresented: $showsWorkspaceImporter,
            allowedContentTypes: [.folder]
        ) { result in
            switch result {
            case .success(let url):
                Task { await model.openWorkspace(url) }
            case .failure(let error):
                model.errorMessage = error.localizedDescription
            }
        }
        .fileImporter(
            isPresented: $showsPDFImporter,
            allowedContentTypes: [.pdf]
        ) { result in
            switch result {
            case .success(let url):
                Task { await model.capturePDF(url) }
            case .failure(let error):
                model.errorMessage = error.localizedDescription
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard urls.count == 1 else {
                model.errorMessage = "Drop one document or link at a time."
                return false
            }
            if urls[0].pathExtension.lowercased() == "pdf" {
                Task { await model.capturePDF(urls[0]) }
                return true
            }
            if ["http", "https"].contains(urls[0].scheme?.lowercased() ?? "") {
                Task { await model.capture(urls[0].absoluteString) }
                return true
            }
            model.errorMessage = "Drop a PDF or web link."
            return false
        }
        .alert(
            "Briefly",
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.clearError() } }
            )
        ) {
            Button("OK") { model.clearError() }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .overlay(alignment: .bottomTrailing) {
            if model.isProcessing {
                HStack(spacing: 9) {
                    ProgressView()
                        .controlSize(.small)
                    Text(model.status)
                        .font(.callout)
                }
                .padding(.horizontal, 14)
                .frame(height: 40)
                .background(.regularMaterial, in: Capsule())
                .padding(18)
                .accessibilityElement(children: .combine)
            }
        }
        #if os(iOS)
        .overlay(alignment: .bottom) {
            MobileLibraryNavigation(
                model: model,
                preferredCompactColumn: $preferredCompactColumn,
                showsPDFImporter: $showsPDFImporter,
                audioPlayer: audioPlayer
            )
        }
        #endif
        #if os(macOS)
        .onReceive(
            NotificationCenter.default.publisher(for: .brieflyCaptureClipboard)
        ) { _ in
            let text = NSPasteboard.general.string(forType: .string) ?? ""
            Task { await model.capture(text) }
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .brieflyChooseWorkspace)
        ) { _ in
            model.chooseWorkspace()
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .brieflyImportPDF)
        ) { _ in
            showsPDFImporter = true
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .brieflyRefreshLibrary)
        ) { _ in
            Task<Void, Never> { await model.refreshWorkspace() }
        }
        #endif
        .preferredColorScheme(
            appearance == "light" ? .light :
                appearance == "dark" ? .dark : nil
        )
    }
}

#if os(iOS)
private struct MobileLibraryNavigation: View {
    @Bindable var model: LibraryModel
    @Binding var preferredCompactColumn: NavigationSplitViewColumn
    @Binding var showsPDFImporter: Bool
    @Bindable var audioPlayer: NativeAudioPlayer
    @State private var showsSearch = false
    @State private var homeSelected = false
    @FocusState private var searchFocused: Bool
    @Namespace private var tabSelection

    var body: some View {
        Group {
            if #available(iOS 26.0, *) {
                GlassEffectContainer(spacing: 12) {
                    controls
                }
            } else {
                controls
            }
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 6)
        .animation(.snappy(duration: 0.2), value: showsSearch)
        .onChange(of: showsSearch) {
            searchFocused = showsSearch
        }
        .zIndex(10)
    }

    private var controls: some View {
        VStack(alignment: .trailing, spacing: 10) {
            if showsSearch {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField(model.activeSection.searchPrompt, text: $model.query)
                        .textFieldStyle(.plain)
                        .focused($searchFocused)
                        .submitLabel(.search)
                    if !model.query.isEmpty {
                        Button {
                            model.query = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Clear search")
                    }
                }
                .padding(.horizontal, 16)
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .mobileGlass(in: Capsule())
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            HStack(alignment: .bottom, spacing: 12) {
                VStack(spacing: 12) {
                    if
                        !homeSelected,
                        preferredCompactColumn == .sidebar
                    {
                        FilterStrip(model: model) {
                            preferredCompactColumn = .detail
                        }
                        .frame(height: 58)
                    } else if isItemDetail, let entry = model.selectedEntry {
                        ReadingDepthStrip(model: model, entry: entry)
                            .frame(height: 58)
                    } else {
                        Color.clear.frame(height: 58)
                    }

                    HStack(spacing: 0) {
                        Button {
                            withAnimation(.snappy(duration: 0.24)) {
                                homeSelected = true
                                preferredCompactColumn = .sidebar
                            }
                        } label: {
                            tabLabel(
                                icon: "house",
                                title: "Home",
                                selected: homeSelected
                            )
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Home")
                        .accessibilityAddTraits(homeSelected ? .isSelected : [])

                        ForEach(LibrarySection.allCases) { section in
                            Button {
                                showsSearch = false
                                withAnimation(.snappy(duration: 0.24)) {
                                    homeSelected = false
                                    preferredCompactColumn = .sidebar
                                }
                                Task { await model.show(section) }
                            } label: {
                                tabLabel(
                                    icon: section.icon,
                                    title: section.title,
                                    selected: !homeSelected &&
                                        model.activeSection == section
                                )
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(section.title)
                            .accessibilityAddTraits(
                                !homeSelected && model.activeSection == section
                                    ? .isSelected
                                    : []
                            )
                        }
                    }
                    .padding(4)
                    .frame(maxWidth: .infinity)
                    .frame(height: 64)
                    .mobileGlass(in: Capsule())
                    .animation(.snappy(duration: 0.24), value: model.activeSection)
                }
                .frame(maxWidth: .infinity)

                VStack(spacing: 12) {
                    Button(action: primaryAction) {
                        Image(
                            systemName: isVoiceBriefDetail
                                ? audioPlayer.isPlaying ? "pause.fill" : "play.fill"
                                : "plus"
                        )
                            .font(.system(size: 23, weight: .medium))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white)
                    .frame(width: 58, height: 58)
                    .mobileGlass(in: Circle(), tint: .accentColor)
                    .accessibilityLabel(primaryActionLabel)

                    Button {
                        if showsSearch {
                            model.query = ""
                            showsSearch = false
                        } else {
                            preferredCompactColumn = .sidebar
                            showsSearch = true
                        }
                    } label: {
                        Image(systemName: showsSearch ? "xmark" : "magnifyingglass")
                            .font(.system(size: 21, weight: .medium))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .frame(width: 58, height: 58)
                    .mobileGlass(in: Circle())
                    .accessibilityLabel(showsSearch ? "Close search" : "Search")
                }
            }
        }
    }

    private func tabLabel(
        icon: String,
        title: String,
        selected: Bool
    ) -> some View {
        VStack(spacing: 2) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .medium))
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .foregroundStyle(selected ? Color.accentColor : Color.primary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .background {
            if selected {
                Capsule()
                    .fill(Color.primary.opacity(0.1))
                    .matchedGeometryEffect(id: "selected-tab", in: tabSelection)
            }
        }
    }

    private var createLabel: String {
        switch model.activeSection {
        case .items: "Import PDF"
        case .channels: "New channel"
        case .briefs: "New voice brief"
        }
    }

    private var isVoiceBriefDetail: Bool {
        preferredCompactColumn == .detail &&
            model.activeSection == .briefs &&
            model.selectedEntry?.voiceBriefID != nil
    }

    private var isItemDetail: Bool {
        preferredCompactColumn == .detail &&
            model.activeSection == .items &&
            !model.showingHighlights &&
            model.selectedEntry != nil
    }

    private var primaryActionLabel: String {
        if isVoiceBriefDetail {
            return audioPlayer.isPlaying ? "Pause voice brief" : "Play voice brief"
        }
        return createLabel
    }

    private func primaryAction() {
        if isVoiceBriefDetail, let entry = model.selectedEntry {
            Task {
                guard let url = await model.audioURL(for: entry.id) else {
                    model.errorMessage = "This audio file is not available locally."
                    return
                }
                do {
                    try audioPlayer.toggle(url, entryID: entry.id)
                } catch {
                    model.errorMessage = error.localizedDescription
                }
            }
        } else {
            create()
        }
    }

    private func create() {
        showsSearch = false
        model.query = ""
        model.selectedID = ""
        model.selectedIDs = []
        switch model.activeSection {
        case .items:
            showsPDFImporter = true
        case .channels:
            model.selectedChannelSource = "new"
            preferredCompactColumn = .detail
        case .briefs:
            model.selectedVoiceBriefID = "new"
            preferredCompactColumn = .detail
        }
    }
}

private struct MobileGlass<S: Shape>: ViewModifier {
    let shape: S
    let tint: Color?

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            let glass = tint.map { Glass.regular.tint($0) } ?? .regular
            content.glassEffect(glass.interactive(), in: shape)
        } else if let tint {
            content.background(tint, in: shape)
        } else {
            content.background(.regularMaterial, in: shape)
        }
    }
}

private extension View {
    func mobileGlass<S: Shape>(
        in shape: S,
        tint: Color? = nil
    ) -> some View {
        modifier(MobileGlass(shape: shape, tint: tint))
    }
}
#endif

#if os(macOS)
private struct WindowControlPositioner: NSViewRepresentable {
    let x: CGFloat
    let y: CGFloat
    @Binding var controlsVisible: Bool

    func makeNSView(context: Context) -> PositioningView {
        PositioningView(x: x, y: y) { visible in
            if controlsVisible != visible {
                controlsVisible = visible
            }
        }
    }

    func updateNSView(_ nsView: PositioningView, context: Context) {
        nsView.onControlsVisible = { visible in
            if controlsVisible != visible {
                controlsVisible = visible
            }
        }
        nsView.positionControls()
    }

    final class PositioningView: NSView {
        let x: CGFloat
        let y: CGFloat
        weak var positionedWindow: NSWindow?
        var onControlsVisible: (Bool) -> Void
        private var originalOrigins = [NSWindow.ButtonType: NSPoint]()
        private var observers = [NSObjectProtocol]()

        init(
            x: CGFloat,
            y: CGFloat,
            onControlsVisible: @escaping (Bool) -> Void
        ) {
            self.x = x
            self.y = y
            self.onControlsVisible = onControlsVisible
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, positionedWindow !== window else { return }
            removeObservers()
            positionedWindow = window
            originalOrigins = [:]
            let center = NotificationCenter.default
            observers = [
                center.addObserver(
                    forName: NSWindow.didEnterFullScreenNotification,
                    object: window,
                    queue: .main
                ) { [weak self] _ in
                    self?.onControlsVisible(false)
                },
                center.addObserver(
                    forName: NSWindow.didExitFullScreenNotification,
                    object: window,
                    queue: .main
                ) { [weak self] _ in
                    guard let self else { return }
                    self.positionControls()
                    self.onControlsVisible(true)
                }
            ]
            DispatchQueue.main.async {
                self.positionControls()
                self.onControlsVisible(!window.styleMask.contains(.fullScreen))
            }
        }

        func positionControls() {
            guard let window, !window.styleMask.contains(.fullScreen) else { return }
            for kind in [
                NSWindow.ButtonType.closeButton,
                .miniaturizeButton,
                .zoomButton
            ] {
                guard let button = window.standardWindowButton(kind) else { continue }
                let origin = originalOrigins[kind] ?? button.frame.origin
                originalOrigins[kind] = origin
                button.setFrameOrigin(NSPoint(x: origin.x + x, y: origin.y + y))
            }
        }

        private func removeObservers() {
            for observer in observers {
                NotificationCenter.default.removeObserver(observer)
            }
            observers = []
        }

        deinit {
            removeObservers()
        }
    }
}
#endif

private struct LibrarySidebar: View {
    @Bindable var model: LibraryModel
    @Binding var showsSettings: Bool
    @Binding var showsWorkspaceImporter: Bool
    @Binding var sidebarVisible: Bool
    var reservesWindowControls = false
    var onOpenDetail: () -> Void = {}

    var body: some View {
        VStack(spacing: 0) {
            #if os(macOS)
            HStack(spacing: 0) {
                if reservesWindowControls {
                    Color.clear
                        .frame(width: 72)
                        .frame(maxHeight: .infinity)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }

                ForEach(LibrarySection.allCases) { section in
                    Button {
                        Task { await model.show(section) }
                    } label: {
                        Image(systemName: section.icon)
                            .font(
                                .system(
                                    size: 15,
                                    weight: model.activeSection == section
                                        ? .semibold
                                        : .regular
                                )
                            )
                            .foregroundStyle(
                                model.activeSection == section
                                    ? Color.primary
                                    : Color.secondary
                            )
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(section.title)
                    .accessibilityAddTraits(
                        model.activeSection == section ? .isSelected : []
                    )
                    .help(section.title)
                }

                Button {
                    withAnimation(.snappy(duration: 0.18)) {
                        sidebarVisible = false
                    }
                } label: {
                    Image(systemName: "sidebar.left")
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut("s", modifiers: [.command, .control])
                .accessibilityLabel("Hide sidebar")
                .help("Hide sidebar")
            }
            .frame(height: 45)
            #endif

            #if os(macOS)
            HStack(spacing: 9) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField(model.activeSection.searchPrompt, text: $model.query)
                    .textFieldStyle(.plain)
                if !model.query.isEmpty {
                    Button {
                        model.query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 44)
            #endif

            #if os(macOS)
            if model.activeSection == .items {
                FilterStrip(model: model, onOpenDetail: onOpenDetail)
            }
            #endif

            ScrollView {
                #if os(iOS)
                LazyVStack(spacing: 8) {
                    MobileEntryRows(model: model, onOpenDetail: onOpenDetail)
                }
                .padding(.horizontal, 8)
                #else
                LazyVStack(spacing: 2) {
                    switch model.activeSection {
                    case .items:
                        ItemRows(model: model, onOpenDetail: onOpenDetail)
                    case .channels:
                        ChannelRows(model: model, onOpenDetail: onOpenDetail)
                    case .briefs:
                        VoiceBriefRows(model: model, onOpenDetail: onOpenDetail)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 10)
                #endif
            }
            #if os(iOS)
            .defaultScrollAnchor(.bottom)
            .padding(.bottom, 150)
            #endif

            #if os(macOS)
            HStack(spacing: 0) {
                Button {
                    if model.canEdit {
                        model.openAgent()
                    } else {
                        model.chooseWorkspace()
                    }
                } label: {
                    Label(
                        model.canEdit ? "AI" : "Choose Workspace",
                        systemImage: model.canEdit ? "sparkles" : "folder"
                    )
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Button {
                    showsSettings = true
                } label: {
                    Image(systemName: "gearshape")
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Settings")
            }
            .font(.system(size: 13, weight: .semibold))
            #endif
        }
        #if os(macOS)
        .background(sidebarBackground)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(.primary.opacity(0.08))
        }
        #else
        .background(sidebarBackground.ignoresSafeArea())
        #endif
    }
}

private struct FilterStrip: View {
    @Bindable var model: LibraryModel
    let onOpenDetail: () -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                switch model.activeSection {
                case .items:
                    TopicButton(
                        title: "All",
                        selected: model.selectedTopic == "All" &&
                            !model.showingHighlights
                    ) {
                        Task { await model.showTopic("All") }
                    }
                    TopicButton(
                        title: model.highlightCount == 0
                            ? "Highlights"
                            : "Highlights \(model.highlightCount)",
                        selected: model.showingHighlights
                    ) {
                        model.showHighlights()
                        onOpenDetail()
                    }
                    ForEach(model.projection.documentTopics, id: \.self) { topic in
                        TopicButton(
                            title: topic,
                            selected: model.selectedTopic == topic &&
                                !model.showingHighlights
                        ) {
                            Task { await model.showTopic(topic) }
                        }
                    }
                case .channels:
                    TopicButton(
                        title: "All",
                        selected: model.selectedChannelSource.isEmpty
                    ) {
                        model.selectedChannelSource = ""
                        model.selectedID = ""
                        model.selectedIDs = []
                    }
                    ForEach(model.channels) { channel in
                        TopicButton(
                            title: channel.title,
                            selected: model.selectedChannelSource == channel.source
                        ) {
                            model.selectedChannelSource = channel.source
                            model.selectedID = ""
                            model.selectedIDs = []
                        }
                    }
                case .briefs:
                    TopicButton(
                        title: "All",
                        selected: model.selectedVoiceBriefID.isEmpty
                    ) {
                        model.selectedVoiceBriefID = ""
                        model.selectedID = ""
                        model.selectedIDs = []
                    }
                    ForEach(model.projection.voiceBriefDefinitions, id: \.id) { brief in
                        TopicButton(
                            title: brief.title,
                            selected: model.selectedVoiceBriefID == brief.id
                        ) {
                            model.selectedVoiceBriefID = brief.id
                            model.selectedID = ""
                            model.selectedIDs = []
                        }
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }
}

private struct TopicButton: View {
    let title: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 10)
                .frame(height: 32)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .background(selected ? Color.accentColor : Color.primary.opacity(0.055))
        .foregroundStyle(selected ? Color.white : Color.primary)
        .clipShape(Capsule())
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

#if os(iOS)
private struct ReadingDepthStrip: View {
    @Bindable var model: LibraryModel
    let entry: LibraryEntry

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(entry.texts.map(\.variant), id: \.self) { variant in
                    Button {
                        Task { await model.selectVariant(variant) }
                    } label: {
                        ReadingDepthIcon(variant: variant)
                            .frame(width: 44, height: 32)
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .background(
                        model.selectedVariant == variant
                            ? Color.accentColor
                            : Color.primary.opacity(0.055)
                    )
                    .foregroundStyle(
                        model.selectedVariant == variant ? Color.white : Color.primary
                    )
                    .clipShape(Capsule())
                    .accessibilityLabel(
                        variant == .source ? "Original" : variant.title
                    )
                    .accessibilityAddTraits(
                        model.selectedVariant == variant ? .isSelected : []
                    )
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }
}
#endif

#if os(iOS)
private struct MobileEntryRows: View {
    @Bindable var model: LibraryModel
    let onOpenDetail: () -> Void

    private var entries: [LibraryEntry] {
        let candidates = switch model.activeSection {
        case .items:
            model.filteredEntries
        case .channels:
            (model.selectedChannelSource.isEmpty
                ? model.channels.map(\.source)
                : [model.selectedChannelSource]
            ).flatMap { model.channelEntries(for: $0) }
        case .briefs:
            (model.selectedVoiceBriefID.isEmpty
                ? model.projection.voiceBriefDefinitions.map(\.id)
                : [model.selectedVoiceBriefID]
            ).flatMap { model.projection.episodes(for: $0) }
        }
        return candidates
            .filter { $0.matches(model.query) }
            .sorted {
                ($0.createdAt ?? $0.updatedAt ?? "") <
                    ($1.createdAt ?? $1.updatedAt ?? "")
            }
    }

    private var emptyTitle: String {
        switch model.activeSection {
        case .items:
            model.query.isEmpty
                ? model.selectedTopic == "All"
                    ? "No documents yet"
                    : "No documents in \(model.selectedTopic)"
                : "No matching documents"
        case .channels:
            model.query.isEmpty ? "No channel items" : "No matching channel items"
        case .briefs:
            model.query.isEmpty ? "No voice briefs" : "No matching voice briefs"
        }
    }

    var body: some View {
        if entries.isEmpty {
            SidebarEmpty(icon: "doc.text", title: emptyTitle)
        } else {
            ForEach(entries) { entry in
                SidebarRow(
                    icon: "doc.text",
                    title: entry.title,
                    selected: model.selectedIDs.contains(entry.id),
                    showsIcon: false,
                    glass: true
                ) {
                    Task {
                        await model.select(entry.id)
                        onOpenDetail()
                    }
                }
                .containerRelativeFrame(
                    .vertical,
                    count: min(entries.count, 10),
                    span: 1,
                    spacing: 8
                )
                .modifier(EntryContextMenu(model: model, entry: entry))
            }
        }
    }
}
#endif

private struct ItemRows: View {
    @Bindable var model: LibraryModel
    let onOpenDetail: () -> Void

    var body: some View {
        if model.filteredEntries.isEmpty {
            SidebarEmpty(
                icon: "doc.text",
                title: model.query.isEmpty
                    ? model.selectedTopic == "All"
                        ? "No documents yet"
                        : "No documents in \(model.selectedTopic)"
                    : "No matching documents"
            )
        } else {
            ForEach(model.filteredEntries) { entry in
                SidebarRow(
                    icon: entry.origin == .shared ? "person.2" : "doc.text",
                    title: entry.title,
                    selected: model.selectedIDs.contains(entry.id),
                    imageURL: localFaviconURL(for: entry, workspacePath: model.workspacePath)
                ) {
                    Task {
                        await model.select(entry.id, extending: extendsSidebarSelection())
                        onOpenDetail()
                    }
                }
                .modifier(EntryContextMenu(model: model, entry: entry))
            }
        }
    }
}

private struct VoiceBriefRows: View {
    @Bindable var model: LibraryModel
    let onOpenDetail: () -> Void

    var body: some View {
        #if os(macOS)
        Button {
            model.selectedID = ""
            model.selectedIDs = []
            model.selectedVoiceBriefID = "new"
            onOpenDetail()
        } label: {
            Label("New voice brief", systemImage: "plus")
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 11)
                .frame(height: 39)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.accentColor)
        .background {
            RoundedRectangle(cornerRadius: 9)
                .fill(
                    model.selectedVoiceBriefID == "new"
                        ? Color.accentColor.opacity(0.1)
                        : Color.clear
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 9)
                .stroke(
                    Color.primary.opacity(0.17),
                    style: StrokeStyle(lineWidth: 1, dash: [4, 3])
                )
                }
        }
        .padding(.bottom, 6)
        #endif

        if model.filteredVoiceBriefs.isEmpty {
            SidebarEmpty(icon: "headphones", title: "No voice briefs")
        } else {
            ForEach(model.filteredVoiceBriefs, id: \.id) { brief in
                SidebarRow(
                    icon: model.expandedVoiceBriefIDs.contains(brief.id)
                        ? "folder.fill"
                        : "folder",
                    title: brief.title,
                    selected: model.selectedVoiceBriefID == brief.id &&
                        model.selectedID.isEmpty
                ) {
                    model.selectVoiceBrief(brief.id)
                    onOpenDetail()
                }

                if model.expandedVoiceBriefIDs.contains(brief.id) {
                    ForEach(model.projection.episodes(for: brief.id)) { episode in
                        SidebarRow(
                            icon: "doc.text",
                            title: episode.title,
                            selected: model.selectedIDs.contains(episode.id),
                            inset: true
                        ) {
                            Task {
                                await model.select(
                                    episode.id,
                                    extending: extendsSidebarSelection()
                                )
                                onOpenDetail()
                            }
                        }
                        .modifier(EntryContextMenu(model: model, entry: episode))
                    }
                }
            }
        }
    }
}

private struct ChannelDomainGroup: Identifiable {
    let domain: String
    let channels: [LibraryChannel]

    var id: String { domain }
}

private func channelDomainGroups(
    _ channels: [LibraryChannel]
) -> [ChannelDomainGroup] {
    Dictionary(grouping: channels, by: { channelDomain($0.source) })
        .map { domain, channels in
            ChannelDomainGroup(
                domain: domain,
                channels: channels.sorted {
                    $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
                }
            )
        }
        .sorted {
            $0.domain.localizedCaseInsensitiveCompare($1.domain) == .orderedAscending
        }
}

private func channelDomain(_ source: String) -> String {
    if source.lowercased().hasPrefix("arxiv:") { return "arxiv.org" }
    let host = URL(string: source)?.host?.lowercased()
        .replacingOccurrences(of: #"^www\."#, with: "", options: .regularExpression) ??
        "other"
    if host == "x.com" || host == "twitter.com" { return "x.com" }
    if host == "youtu.be" || host == "youtube.com" || host.hasSuffix(".youtube.com") {
        return "youtube.com"
    }
    if host == "reddit.com" || host.hasSuffix(".reddit.com") { return "reddit.com" }
    return host
}

private struct ChannelRows: View {
    @Bindable var model: LibraryModel
    let onOpenDetail: () -> Void

    var body: some View {
        #if os(macOS)
        Button {
            model.selectedID = ""
            model.selectedIDs = []
            model.selectedChannelSource = "new"
            onOpenDetail()
        } label: {
            Label("New channel", systemImage: "plus")
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 11)
                .frame(height: 39)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.accentColor)
        .background {
            RoundedRectangle(cornerRadius: 9)
                .fill(
                    model.selectedChannelSource == "new"
                        ? Color.accentColor.opacity(0.1)
                        : Color.clear
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 9)
                .stroke(
                    Color.primary.opacity(0.17),
                    style: StrokeStyle(lineWidth: 1, dash: [4, 3])
                )
                }
        }
        .padding(.bottom, 6)
        #endif

        if model.filteredChannels.isEmpty {
            SidebarEmpty(icon: "dot.radiowaves.left.and.right", title: "No channels")
        } else {
            ForEach(channelDomainGroups(model.filteredChannels)) { group in
                Label(group.domain, systemImage: "globe")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.top, 8)
                    .padding(.bottom, 3)

                ForEach(group.channels) { channel in
                    SidebarRow(
                        icon: model.expandedChannelSources.contains(channel.source)
                            ? "folder.fill"
                            : "folder",
                        title: channel.title,
                        selected: model.selectedChannelSource == channel.source &&
                            model.selectedID.isEmpty
                    ) {
                        model.selectChannel(channel.source)
                        onOpenDetail()
                    }

                    if model.expandedChannelSources.contains(channel.source) {
                        ForEach(model.channelEntries(for: channel.source)) { entry in
                            SidebarRow(
                                icon: "doc.text",
                                title: entry.title,
                                selected: model.selectedIDs.contains(entry.id),
                                inset: true,
                                imageURL: localFaviconURL(
                                    for: entry,
                                    workspacePath: model.workspacePath
                                )
                            ) {
                                Task {
                                    await model.select(
                                        entry.id,
                                        extending: extendsSidebarSelection()
                                    )
                                    onOpenDetail()
                                }
                            }
                            .modifier(EntryContextMenu(model: model, entry: entry))
                        }
                    }
                }
            }
        }
    }
}

private struct SidebarRow: View {
    let icon: String
    let title: String
    let selected: Bool
    var inset = false
    var imageURL: URL?
    var showsIcon = true
    var glass = false
    let action: () -> Void

    @ViewBuilder
    var body: some View {
        #if os(iOS)
        if glass {
            row.mobileGlass(
                in: RoundedRectangle(cornerRadius: 18, style: .continuous),
                tint: selected ? Color.accentColor.opacity(0.18) : nil
            )
        } else {
            row
        }
        #else
        row
        #endif
    }

    private var row: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                if showsIcon {
                    if let imageURL {
                        FaviconImage(url: imageURL, fallback: icon)
                    } else {
                        Image(systemName: icon)
                            .font(.system(size: 15))
                            .foregroundStyle(.secondary)
                            .frame(width: 17)
                    }
                }
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.leading, inset ? 27 : 11)
            .padding(.trailing, 11)
            .frame(minHeight: 37, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .background {
            if !glass {
                RoundedRectangle(cornerRadius: 9)
                    .fill(selected ? Color.primary.opacity(0.08) : Color.clear)
            }
        }
        .clipShape(
            RoundedRectangle(
                cornerRadius: glass ? 18 : 9,
                style: .continuous
            )
        )
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct EntryContextMenu: ViewModifier {
    @Bindable var model: LibraryModel
    let entry: LibraryEntry
    @State private var confirmsTrash = false

    func body(content: Content) -> some View {
        content.contextMenu {
            if model.canEdit {
                Button {
                    Task { await model.copyFilePaths(for: entry.id) }
                } label: {
                    Label(
                        model.selectionCount(for: entry.id) > 1 ? "Copy Paths" : "Copy Path",
                        systemImage: "doc.on.doc"
                    )
                }
            }
            if let source = entry.sourceURL, let url = URL(string: source) {
                Link(destination: url) {
                    Label("Open original", systemImage: "arrow.up.right")
                }
            }
            if model.canEdit {
                Button {
                    Task {
                        await model.select(entry.id)
                        await model.processSelected()
                    }
                } label: {
                    Label("Regenerate summaries", systemImage: "sparkles")
                }
                .disabled(model.isProcessing)
                #if os(macOS)
                Button {
                    Task {
                        if !model.selectedIDs.contains(entry.id) {
                            await model.select(entry.id)
                        }
                        let urls = await model.selectedFileURLs(for: entry.id)
                        if !urls.isEmpty {
                            NSWorkspace.shared.activateFileViewerSelecting(urls)
                        }
                    }
                } label: {
                    Label("Reveal in Finder", systemImage: "folder")
                }
                #endif
                Divider()
                Button(role: .destructive) {
                    Task {
                        if !model.selectedIDs.contains(entry.id) {
                            await model.select(entry.id)
                        }
                        confirmsTrash = true
                    }
                } label: {
                    Label(
                        model.selectionCount(for: entry.id) > 1
                            ? "Move Items to Trash"
                            : "Move to Trash",
                        systemImage: "trash"
                    )
                }
            }
        }
        .confirmationDialog(
            model.selectedIDs.count > 1
                ? "Move \(model.selectedIDs.count) items to Trash?"
                : "Move this item to Trash?",
            isPresented: $confirmsTrash
        ) {
            Button("Move to Trash", role: .destructive) {
                Task { await model.trashSelected() }
            }
        }
    }
}

private func extendsSidebarSelection() -> Bool {
    #if os(macOS)
    NSEvent.modifierFlags.contains(.command)
    #else
    false
    #endif
}

private struct FaviconImage: View {
    let url: URL
    let fallback: String

    var body: some View {
        #if os(macOS)
        if let image = NSImage(contentsOf: url) {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .frame(width: 16, height: 16)
                .clipShape(RoundedRectangle(cornerRadius: 3))
        } else {
            fallbackImage
        }
        #else
        if let image = UIImage(contentsOfFile: url.path) {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(width: 16, height: 16)
                .clipShape(RoundedRectangle(cornerRadius: 3))
        } else {
            fallbackImage
        }
        #endif
    }

    private var fallbackImage: some View {
        Image(systemName: fallback)
            .font(.system(size: 15))
            .foregroundStyle(.secondary)
            .frame(width: 17)
    }
}

private struct SidebarEmpty: View {
    let icon: String
    let title: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.title3)
            Text(title)
                .font(.callout)
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity)
        .padding(.top, 45)
    }
}

private struct LibraryDetail: View {
    @Bindable var model: LibraryModel
    @Binding var showsChannelBrowser: Bool
    @Bindable var audioPlayer: NativeAudioPlayer

    var body: some View {
        Group {
            if model.showingHighlights {
                HighlightsDocument(model: model)
            } else if let entry = model.selectedEntry {
                LibraryDocument(model: model, entry: entry, audioPlayer: audioPlayer)
            } else if model.activeSection == .briefs {
                VoiceBriefConfiguration(model: model)
            } else if model.activeSection == .channels {
                ChannelConfiguration(
                    model: model,
                    showsChannelBrowser: $showsChannelBrowser
                )
            } else if model.activeSection == .items && model.filteredEntries.isEmpty {
                ContentUnavailableView(
                    model.query.isEmpty
                        ? model.selectedTopic == "All"
                            ? "No documents yet"
                            : "No documents in \(model.selectedTopic)"
                        : "No matching documents",
                    systemImage: model.query.isEmpty
                        ? "doc.text"
                        : "doc.text.magnifyingglass",
                    description: Text(
                        model.query.isEmpty
                            ? model.selectedTopic == "All"
                                ? "Add a document to start your library."
                                : "Choose another topic or add a document."
                            : "Try another search."
                    )
                )
            } else {
                ContentUnavailableView(
                    "No document selected",
                    systemImage: "doc.text",
                    description: Text("Choose a document from the library.")
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        #if os(macOS)
        .background(readerBackground)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        #else
        .background(readerBackground.ignoresSafeArea())
        #endif
    }
}

private struct HighlightsDocument: View {
    @Bindable var model: LibraryModel

    var body: some View {
        GeometryReader { geometry in
            if model.highlightsText.isEmpty {
                ZStack {
                    ContentUnavailableView(
                        "No highlights yet",
                        systemImage: "highlighter",
                        description: Text(
                            "Select a passage in any document, then choose Highlight."
                        )
                    )
                }
            } else {
                ScrollView {
                    MarkdownArticle(model.highlightsText)
                        .frame(maxWidth: 844, alignment: .leading)
                        .padding(.horizontal, 32)
                        .padding(.top, 56)
                        .padding(.bottom, 80)
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: geometry.size.height, alignment: .top)
                }
            }
        }
    }
}

private struct ReadingDepthIcon: View {
    let variant: LibraryVariant

    private var lineWidths: [CGFloat] {
        switch variant {
        case .brief: [18]
        case .concise: [18, 12]
        case .detailed: [18, 18, 12]
        case .comprehensive: [16, 16, 16, 10]
        case .source: []
        }
    }

    var body: some View {
        if variant == .source {
            Image(systemName: "doc.text")
                .font(.system(size: 17, weight: .medium))
        } else {
            VStack(alignment: .leading, spacing: 2.5) {
                ForEach(Array(lineWidths.enumerated()), id: \.offset) { _, width in
                    Capsule()
                        .frame(width: width, height: 2)
                }
            }
            .frame(width: 18, height: 21, alignment: .center)
        }
    }
}

private enum MarkdownRunStyle {
    case hidden
    case bold
    case italic
    case code
    case link
    case quote
    case heading(Int)
}

private func markdownRuns(in text: String) -> [(NSRange, MarkdownRunStyle)] {
    let fullRange = NSRange(location: 0, length: text.utf16.count)
    var runs = [(NSRange, MarkdownRunStyle)]()

    func matches(_ pattern: String) -> [NSTextCheckingResult] {
        (try? NSRegularExpression(pattern: pattern))?.matches(
            in: text,
            range: fullRange
        ) ?? []
    }

    func addWrapped(_ match: NSTextCheckingResult, content: NSRange) {
        guard content.location != NSNotFound else { return }
        let prefix = NSRange(
            location: match.range.location,
            length: content.location - match.range.location
        )
        let suffix = NSRange(
            location: NSMaxRange(content),
            length: NSMaxRange(match.range) - NSMaxRange(content)
        )
        if prefix.length > 0 { runs.append((prefix, .hidden)) }
        if suffix.length > 0 { runs.append((suffix, .hidden)) }
    }

    for match in matches(#"\*\*([^*\n]+)\*\*|__([^_\n]+)__"#) {
        let content = match.range(at: 1).location == NSNotFound
            ? match.range(at: 2)
            : match.range(at: 1)
        runs.append((content, .bold))
        addWrapped(match, content: content)
    }
    for match in matches(#"(?<!\*)\*([^*\n]+)\*(?!\*)|(?<!_)_([^_\n]+)_(?!_)"#) {
        let content = match.range(at: 1).location == NSNotFound
            ? match.range(at: 2)
            : match.range(at: 1)
        runs.append((content, .italic))
        addWrapped(match, content: content)
    }
    for match in matches(#"`([^`\n]+)`"#) {
        let content = match.range(at: 1)
        runs.append((content, .code))
        addWrapped(match, content: content)
    }
    for match in matches(#"\[([^\]\n]+)\]\(([^)\n]+)\)"#) {
        let label = match.range(at: 1)
        runs.append((label, .link))
        addWrapped(match, content: label)
    }
    for match in matches(#"(?m)^>[ \t]+([^\n]*)$"#) {
        let content = match.range(at: 1)
        runs.append((content, .quote))
        let prefix = NSRange(
            location: match.range.location,
            length: content.location - match.range.location
        )
        runs.append((prefix, .hidden))
    }
    for match in matches(#"(?m)^(#{1,3})[ \t]+([^\n]+)$"#) {
        let marker = match.range(at: 1)
        let content = match.range(at: 2)
        runs.append((content, .heading(marker.length)))
        let prefix = NSRange(
            location: match.range.location,
            length: content.location - match.range.location
        )
        runs.append((prefix, .hidden))
    }
    return runs
}

private func highlightedPassages(in markdown: String) -> [String] {
    var passages = [String]()
    var quote = [String]()
    for line in markdown.components(separatedBy: .newlines) + [""] {
        if line.hasPrefix("> ") {
            quote.append(String(line.dropFirst(2)))
        } else if !quote.isEmpty {
            passages.append(quote.joined(separator: "\n"))
            quote.removeAll(keepingCapacity: true)
        }
    }
    return passages
}

private func highlightedPassage(
    in source: NSString,
    passages: [String],
    intersecting selection: NSRange
) -> String? {
    for passage in passages where !passage.isEmpty {
        var searchRange = NSRange(location: 0, length: source.length)
        while searchRange.length > 0 {
            let found = source.range(of: passage, options: [], range: searchRange)
            guard found.location != NSNotFound else { break }
            if NSIntersectionRange(found, selection).length > 0 { return passage }
            let next = NSMaxRange(found)
            searchRange = NSRange(location: next, length: source.length - next)
        }
    }
    return nil
}

private struct DocumentEditor: View {
    @Bindable var model: LibraryModel
    let entryID: String
    let variant: LibraryVariant
    let sourceText: String
    let highlightedPassages: [String]
    let isEditing: Bool
    @State private var draft: String
    @State private var pendingSave: Task<Void, Never>?

    init(
        model: LibraryModel,
        entryID: String,
        variant: LibraryVariant,
        sourceText: String,
        highlightedPassages: [String],
        isEditing: Bool
    ) {
        self.model = model
        self.entryID = entryID
        self.variant = variant
        self.sourceText = sourceText
        self.highlightedPassages = highlightedPassages
        self.isEditing = isEditing
        _draft = State(initialValue: sourceText)
    }

    var body: some View {
        EditableDocumentTextView(
            text: $draft,
            isEditable: model.canEdit && isEditing,
            highlightedPassages: highlightedPassages,
            onHighlight: model.canEdit ? { text in
                Task { await model.addHighlight(text) }
            } : nil,
            onRemoveHighlight: model.canEdit ? { text in
                Task { await model.removeHighlight(text) }
            } : nil
        )
        .onChange(of: sourceText) { oldValue, newValue in
            if draft == oldValue { draft = newValue }
        }
        .onChange(of: draft) {
            guard model.canEdit, isEditing, draft != sourceText else { return }
            pendingSave?.cancel()
            let text = draft
            pendingSave = Task {
                try? await Task.sleep(for: .milliseconds(450))
                guard !Task.isCancelled else { return }
                await model.saveText(text, entryID: entryID, variant: variant)
            }
        }
    }
}

#if os(macOS)
private struct EditableDocumentTextView: NSViewRepresentable {
    @Binding var text: String
    let isEditable: Bool
    let highlightedPassages: [String]
    let onHighlight: ((String) -> Void)?
    let onRemoveHighlight: ((String) -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        let textView = MarkdownTextView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        textView.delegate = context.coordinator
        textView.isRichText = true
        textView.importsGraphics = false
        textView.allowsImageEditing = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: scrollView.contentSize.height)
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.containerSize = NSSize(
            width: scrollView.contentSize.width,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainerInset = NSSize(width: 32, height: 90)
        textView.highlightAction = onHighlight
        textView.removeHighlightAction = onRemoveHighlight
        textView.highlightedPassages = highlightedPassages
        textView.isSelectable = true
        textView.isEditable = isEditable
        textView.setMarkdown(text)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? MarkdownTextView else {
            return
        }
        textView.isSelectable = true
        textView.isEditable = isEditable
        textView.highlightAction = onHighlight
        textView.removeHighlightAction = onRemoveHighlight
        textView.highlightedPassages = highlightedPassages
        if textView.string != text { textView.setMarkdown(text) }
        else { textView.renderMarkdown() }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: EditableDocumentTextView

        init(_ parent: EditableDocumentTextView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? MarkdownTextView else {
                return
            }
            parent.text = textView.string
            textView.renderMarkdown()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? MarkdownTextView else {
                return
            }
            textView.showHighlightButton(for: textView.selectedRange())
        }
    }
}

private final class HighlightButton: NSButton {
    override var acceptsFirstResponder: Bool { false }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .arrow)
    }
}

private final class MarkdownTextView: NSTextView {
    var highlightAction: ((String) -> Void)?
    var removeHighlightAction: ((String) -> Void)?
    var highlightedPassages = [String]()
    private var highlightButton: NSButton?
    private var highlightedText = ""
    private var removesHighlight = false
    private var isRendering = false

    func setMarkdown(_ text: String) {
        string = text
        renderMarkdown()
    }

    func renderMarkdown() {
        guard !isRendering, let storage = textStorage else { return }
        isRendering = true
        defer { isRendering = false }
        let range = NSRange(location: 0, length: string.utf16.count)
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = 32
        paragraph.maximumLineHeight = 32
        let body = NSFont(name: "NewYork-Regular", size: 19) ??
            .systemFont(ofSize: 19)
        let bold = NSFont(name: "NewYork-Bold", size: 19) ??
            .boldSystemFont(ofSize: 19)
        let italic = NSFontManager.shared.convert(body, toHaveTrait: .italicFontMask)
        let hidden = NSFont.systemFont(ofSize: 0.1)

        storage.beginEditing()
        storage.setAttributes(
            [
                .font: body,
                .foregroundColor: NSColor.textColor,
                .paragraphStyle: paragraph
            ],
            range: range
        )
        for (range, style) in markdownRuns(in: string) {
            let attributes: [NSAttributedString.Key: Any]
            switch style {
            case .hidden:
                attributes = [.font: hidden, .foregroundColor: NSColor.clear]
            case .bold:
                attributes = [.font: bold]
            case .italic:
                attributes = [.font: italic]
            case .code:
                attributes = [
                    .font: NSFont.monospacedSystemFont(ofSize: 17, weight: .regular),
                    .backgroundColor: NSColor.quaternaryLabelColor
                ]
            case .link:
                attributes = [
                    .foregroundColor: NSColor.controlAccentColor,
                    .underlineStyle: NSUnderlineStyle.single.rawValue
                ]
            case .quote:
                attributes = [
                    .font: italic,
                    .foregroundColor: NSColor.secondaryLabelColor
                ]
            case let .heading(level):
                let size = level == 1 ? 28.0 : level == 2 ? 23.0 : 19.0
                attributes = [
                    .font: NSFont(name: "NewYork-Bold", size: size) ??
                        .boldSystemFont(ofSize: size)
                ]
            }
            storage.addAttributes(attributes, range: range)
        }
        let source = string as NSString
        for passage in highlightedPassages where !passage.isEmpty {
            var searchRange = NSRange(location: 0, length: source.length)
            while searchRange.length > 0 {
                let found = source.range(of: passage, options: [], range: searchRange)
                guard found.location != NSNotFound else { break }
                storage.addAttribute(
                    .backgroundColor,
                    value: NSColor.systemYellow.withAlphaComponent(0.34),
                    range: found
                )
                let next = NSMaxRange(found)
                searchRange = NSRange(location: next, length: source.length - next)
            }
        }
        storage.endEditing()
        typingAttributes = [
            .font: body,
            .foregroundColor: NSColor.textColor,
            .paragraphStyle: paragraph
        ]
        needsDisplay = true
    }

    func showHighlightButton(for range: NSRange) {
        guard
            range.length > 0,
            highlightAction != nil,
            let textRange = Range(range, in: string)
        else {
            highlightButton?.removeFromSuperview()
            highlightButton = nil
            return
        }
        let text = String(string[textRange])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            highlightButton?.removeFromSuperview()
            highlightButton = nil
            return
        }
        let existingHighlight = highlightedPassage(
            in: string as NSString,
            passages: highlightedPassages,
            intersecting: range
        )
        removesHighlight = existingHighlight != nil
        highlightedText = existingHighlight ?? text

        let button = highlightButton ?? HighlightButton(
            title: "",
            target: self,
            action: #selector(toggleHighlight)
        )
        button.title = ""
        button.image = NSImage(
            systemSymbolName: removesHighlight ? "eraser" : "highlighter",
            accessibilityDescription: nil
        )
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.isBordered = false
        button.setButtonType(.momentaryPushIn)
        button.focusRingType = .none
        button.contentTintColor = removesHighlight
            ? NSColor(calibratedRed: 0.78, green: 0.12, blue: 0.12, alpha: 1)
            : NSColor(calibratedRed: 0.58, green: 0.36, blue: 0.02, alpha: 1)
        button.wantsLayer = true
        button.layer?.backgroundColor = NSColor.white.cgColor
        button.layer?.borderColor = NSColor(
            calibratedWhite: 0.78,
            alpha: 1
        ).cgColor
        button.layer?.borderWidth = 1
        button.layer?.cornerRadius = 9
        button.layer?.shadowColor = NSColor.black.cgColor
        button.layer?.shadowOpacity = 0.16
        button.layer?.shadowRadius = 5
        button.layer?.shadowOffset = CGSize(width: 0, height: -2)
        button.setAccessibilityLabel(
            removesHighlight
                ? "Remove selection from Highlights"
                : "Add selection to Highlights"
        )
        button.toolTip = removesHighlight
            ? "Remove selection from Highlights"
            : "Add selection to Highlights"
        if highlightButton == nil {
            addSubview(button, positioned: .above, relativeTo: nil)
            highlightButton = button
        }

        guard let layoutManager, let textContainer else { return }
        let glyphs = layoutManager.glyphRange(
            forCharacterRange: range,
            actualCharacterRange: nil
        )
        var selectionRect = layoutManager.boundingRect(
            forGlyphRange: glyphs,
            in: textContainer
        )
        selectionRect.origin.x += textContainerOrigin.x
        selectionRect.origin.y += textContainerOrigin.y
        let size = NSSize(width: 34, height: 34)
        let x = min(
            max(selectionRect.midX - size.width / 2, visibleRect.minX + 6),
            visibleRect.maxX - size.width - 6
        )
        let above = selectionRect.minY - size.height - 10
        let y = above >= visibleRect.minY + 4
            ? above
            : min(selectionRect.maxY + 10, visibleRect.maxY - size.height - 4)
        button.frame = NSRect(origin: NSPoint(x: x, y: y), size: size)
    }

    @objc private func toggleHighlight() {
        if removesHighlight {
            removeHighlightAction?(highlightedText)
        } else {
            highlightAction?(highlightedText)
        }
        highlightButton?.removeFromSuperview()
        highlightButton = nil
    }
}
#elseif os(iOS)
private struct EditableDocumentTextView: UIViewRepresentable {
    @Binding var text: String
    let isEditable: Bool
    let highlightedPassages: [String]
    let onHighlight: ((String) -> Void)?
    let onRemoveHighlight: ((String) -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> MarkdownTextView {
        let textView = MarkdownTextView()
        textView.delegate = context.coordinator
        textView.isEditable = isEditable
        textView.isSelectable = true
        textView.backgroundColor = .clear
        textView.alwaysBounceVertical = true
        textView.textContainerInset = UIEdgeInsets(
            top: 90,
            left: 32,
            bottom: 125,
            right: 32
        )
        textView.textContainer.lineFragmentPadding = 0
        textView.highlightedPassages = highlightedPassages
        textView.setMarkdown(text)
        return textView
    }

    func updateUIView(_ textView: MarkdownTextView, context: Context) {
        context.coordinator.parent = self
        textView.isEditable = isEditable
        textView.isSelectable = true
        textView.highlightedPassages = highlightedPassages
        if textView.text != text { textView.setMarkdown(text) }
        else { textView.renderMarkdown() }
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: EditableDocumentTextView

        init(_ parent: EditableDocumentTextView) {
            self.parent = parent
        }

        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text
            (textView as? MarkdownTextView)?.renderMarkdown()
        }

        func textView(
            _ textView: UITextView,
            editMenuForTextIn range: NSRange,
            suggestedActions: [UIMenuElement]
        ) -> UIMenu? {
            guard
                range.length > 0,
                parent.onHighlight != nil
            else { return UIMenu(children: suggestedActions) }
            let text = (textView.text as NSString).substring(with: range)
            let existingHighlight = highlightedPassage(
                in: textView.text as NSString,
                passages: parent.highlightedPassages,
                intersecting: range
            )
            let action = UIAction(
                title: existingHighlight == nil ? "Highlight" : "Remove Highlight",
                image: UIImage(
                    systemName: existingHighlight == nil ? "highlighter" : "eraser"
                )
            ) { _ in
                if let existingHighlight {
                    self.parent.onRemoveHighlight?(existingHighlight)
                } else {
                    self.parent.onHighlight?(text)
                }
            }
            return UIMenu(children: [action] + suggestedActions)
        }
    }
}

private final class MarkdownTextView: UITextView {
    var highlightedPassages = [String]()
    private var isRendering = false

    func setMarkdown(_ markdown: String) {
        text = markdown
        renderMarkdown()
    }

    func renderMarkdown() {
        guard !isRendering else { return }
        isRendering = true
        defer { isRendering = false }
        let range = NSRange(location: 0, length: text.utf16.count)
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = 32
        paragraph.maximumLineHeight = 32
        let body = UIFont(name: "NewYork-Regular", size: 19) ??
            .systemFont(ofSize: 19)
        let bold = UIFont(name: "NewYork-Bold", size: 19) ??
            .boldSystemFont(ofSize: 19)
        let italic = UIFont.italicSystemFont(ofSize: 19)
        let hidden = UIFont.systemFont(ofSize: 0.1)

        textStorage.beginEditing()
        textStorage.setAttributes(
            [
                .font: body,
                .foregroundColor: UIColor.label,
                .paragraphStyle: paragraph
            ],
            range: range
        )
        for (range, style) in markdownRuns(in: text) {
            let attributes: [NSAttributedString.Key: Any]
            switch style {
            case .hidden:
                attributes = [.font: hidden, .foregroundColor: UIColor.clear]
            case .bold:
                attributes = [.font: bold]
            case .italic:
                attributes = [.font: italic]
            case .code:
                attributes = [
                    .font: UIFont.monospacedSystemFont(ofSize: 17, weight: .regular),
                    .backgroundColor: UIColor.quaternarySystemFill
                ]
            case .link:
                attributes = [
                    .foregroundColor: UIColor.tintColor,
                    .underlineStyle: NSUnderlineStyle.single.rawValue
                ]
            case .quote:
                attributes = [
                    .font: italic,
                    .foregroundColor: UIColor.secondaryLabel
                ]
            case let .heading(level):
                let size = level == 1 ? 28.0 : level == 2 ? 23.0 : 19.0
                attributes = [
                    .font: UIFont(name: "NewYork-Bold", size: size) ??
                        .boldSystemFont(ofSize: size)
                ]
            }
            textStorage.addAttributes(attributes, range: range)
        }
        let source = text as NSString
        for passage in highlightedPassages where !passage.isEmpty {
            var searchRange = NSRange(location: 0, length: source.length)
            while searchRange.length > 0 {
                let found = source.range(of: passage, options: [], range: searchRange)
                guard found.location != NSNotFound else { break }
                textStorage.addAttribute(
                    .backgroundColor,
                    value: UIColor.systemYellow.withAlphaComponent(0.34),
                    range: found
                )
                let next = NSMaxRange(found)
                searchRange = NSRange(location: next, length: source.length - next)
            }
        }
        textStorage.endEditing()
        typingAttributes = [
            .font: body,
            .foregroundColor: UIColor.label,
            .paragraphStyle: paragraph
        ]
        setNeedsDisplay()
    }

}
#endif

private struct LibraryDocument: View {
    @Bindable var model: LibraryModel
    let entry: LibraryEntry
    @Bindable var audioPlayer: NativeAudioPlayer
    @State private var isEditing = false
    @State private var audioExpanded = false
    @State private var showsSharing = false

    var body: some View {
        ZStack(alignment: .bottom) {
            if model.isLoadingText {
                ProgressView("Loading document…")
            } else if model.selectedText.isEmpty && !model.canEdit {
                ContentUnavailableView(
                    "Document unavailable",
                    systemImage: "icloud.slash",
                    description: Text(
                        "Sync the library to download this document."
                    )
                )
            } else {
                DocumentEditor(
                    model: model,
                    entryID: entry.id,
                    variant: model.selectedVariant,
                    sourceText: model.selectedText,
                    highlightedPassages: highlightedPassages(
                        in: model.highlightsText
                    ),
                    isEditing: isEditing
                )
                .id("\(entry.id):\(model.selectedVariant.rawValue)")
            }

            if audioExpanded {
                VStack(spacing: 10) {
                    HStack(spacing: 10) {
                        Image(systemName: "waveform")
                        Text(
                            audioPlayer.isPlaying
                                ? "Playing voice brief"
                                : "Audio paused"
                        )
                        .font(.caption)
                        Spacer()
                        Button {
                            Task {
                                guard let url = await model.audioURL(for: entry.id) else {
                                    model.errorMessage =
                                        "This audio file is not available locally."
                                    return
                                }
                                do {
                                    try audioPlayer.toggle(url, entryID: entry.id)
                                } catch {
                                    model.errorMessage = error.localizedDescription
                                }
                            }
                        } label: {
                            Image(
                                systemName: audioPlayer.isPlaying
                                    ? "pause.fill"
                                    : "play.fill"
                            )
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(
                            audioPlayer.isPlaying ? "Pause audio" : "Play audio"
                        )
                        Button {
                            audioPlayer.stop()
                            audioExpanded = false
                        } label: {
                            Image(systemName: "xmark")
                        }
                        .buttonStyle(.plain)
                    }
                    Slider(
                        value: Binding(
                            get: { audioPlayer.currentTime },
                            set: audioPlayer.seek
                        ),
                        in: 0...max(1, audioPlayer.duration)
                    )
                    .accessibilityLabel("Playback position")
                    HStack {
                        Text(
                            "\(audioTime(audioPlayer.currentTime)) / " +
                                audioTime(audioPlayer.duration)
                        )
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        Spacer()
                        Picker(
                            "Speed",
                            selection: Binding(
                                get: { audioPlayer.rate },
                                set: audioPlayer.setRate
                            )
                        ) {
                            ForEach([0.75, 1, 1.25, 1.5, 2], id: \.self) {
                                Text("\($0.formatted())×").tag($0)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 72)
                        Image(systemName: "speaker.wave.2")
                            .foregroundStyle(.secondary)
                        Slider(
                            value: Binding(
                                get: { audioPlayer.volume },
                                set: audioPlayer.setVolume
                            ),
                            in: 0...1
                        )
                        .frame(width: 86)
                        .accessibilityLabel("Volume")
                    }
                }
                .padding(12)
                .frame(maxWidth: 470)
                .background(.regularMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 13))
                .overlay {
                    RoundedRectangle(cornerRadius: 13)
                        .stroke(.primary.opacity(0.1))
                }
                .padding(.bottom, 52)
            }

            HStack(alignment: .bottom) {
                if entry.texts.count > 1 && !usesMobileItemControls {
                    HStack(spacing: 0) {
                        ForEach(entry.texts.map(\.variant), id: \.self) { variant in
                            Button {
                                Task { await model.selectVariant(variant) }
                            } label: {
                                ReadingDepthIcon(variant: variant)
                                    .frame(width: 44, height: 44)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(
                                model.selectedVariant == variant
                                    ? Color.accentColor
                                    : Color.primary
                            )
                            .background(
                                model.selectedVariant == variant
                                    ? Color.accentColor.opacity(0.12)
                                    : Color.clear
                            )
                            .accessibilityLabel(
                                variant == .source ? "Original" : variant.title
                            )
                            .help(variant == .source ? "Original" : variant.title)
                        }
                    }
                    .background(readerBackground)
                    .clipShape(
                        .rect(
                            topLeadingRadius: 0,
                            bottomLeadingRadius: 0,
                            bottomTrailingRadius: 0,
                            topTrailingRadius: 14
                        )
                    )
                    .overlay(alignment: .top) {
                        Rectangle()
                            .fill(.primary.opacity(0.08))
                            .frame(height: 1)
                    }
                }

                Spacer()

                HStack(spacing: 0) {
                    if model.canEdit {
                        Button {
                            isEditing.toggle()
                        } label: {
                            Image(systemName: isEditing ? "checkmark" : "pencil")
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(isEditing ? Color.accentColor : Color.primary)
                        .background(
                            isEditing ? Color.accentColor.opacity(0.12) : Color.clear
                        )
                        .accessibilityLabel(
                            isEditing ? "Finish editing" : "Edit document"
                        )
                        .help(isEditing ? "Finish editing" : "Edit document")

                        #if os(macOS)
                        Button {
                            Task {
                                if let url = await model.selectedFileURL() {
                                    NSWorkspace.shared.activateFileViewerSelecting([url])
                                }
                            }
                        } label: {
                            Image(systemName: "folder")
                                .frame(width: 44, height: 44)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Reveal in Finder")
                        #endif
                    }

                    if hasAudio && !usesMobileVoiceBriefControls {
                        Button {
                            Task {
                                guard let url = await model.audioURL(for: entry.id) else {
                                    model.errorMessage =
                                        "This audio file is not available locally."
                                    return
                                }
                                do {
                                try audioPlayer.toggle(url, entryID: entry.id)
                                    audioExpanded = true
                                } catch {
                                    model.errorMessage = error.localizedDescription
                                }
                            }
                        } label: {
                            Image(
                                systemName: audioPlayer.isPlaying
                                    ? "pause.circle.fill"
                                    : "headphones"
                            )
                                .frame(width: 44, height: 44)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Audio")
                    }

                    if let source = entry.sourceURL, let url = URL(string: source) {
                        Link(destination: url) {
                            Image(systemName: "arrow.up.right")
                                .frame(width: 44, height: 44)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Open original source")
                    }

                    if entry.origin != .shared &&
                        !usesMobileVoiceBriefControls &&
                        !usesMobileItemControls
                    {
                        Button {
                            showsSharing = true
                        } label: {
                            Image(systemName: "square.and.arrow.up")
                                .frame(width: 44, height: 44)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Share document")
                    }
                }
                .background(readerBackground)
                .clipShape(
                    .rect(
                        topLeadingRadius: 14,
                        bottomLeadingRadius: 0,
                        bottomTrailingRadius: 0,
                        topTrailingRadius: 0
                    )
                )
                .overlay(alignment: .top) {
                    Rectangle()
                        .fill(.primary.opacity(0.08))
                        .frame(height: 1)
                }
            }
        }
        .onChange(of: entry.id) {
            isEditing = false
            audioPlayer.stop()
            audioExpanded = false
        }
        .contextMenu {
            if model.canEdit {
                Button("Regenerate summaries") {
                    Task { await model.processSelected() }
                }
                .disabled(model.isProcessing)
                #if os(macOS)
                Button("Reveal in Finder") {
                    Task {
                        if let url = await model.selectedFileURL() {
                            NSWorkspace.shared.activateFileViewerSelecting([url])
                        }
                    }
                }
                #endif
                Divider()
                Button("Move to Trash", role: .destructive) {
                    Task { await model.trashSelected() }
                }
            }
        }
        .sheet(isPresented: $showsSharing) {
            ShareDocumentView(model: model, entry: entry)
        }
        #if os(iOS)
        .toolbar {
            if (usesMobileVoiceBriefControls || usesMobileItemControls) &&
                entry.origin != .shared
            {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showsSharing = true
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .accessibilityLabel(
                        usesMobileVoiceBriefControls
                            ? "Share voice brief"
                            : "Share document"
                    )
                }
            }
        }
        #endif
    }

    private var hasAudio: Bool {
        entry.hasAudio == true || entry.audio != nil || entry.mediaURL != nil
    }

    private var usesMobileVoiceBriefControls: Bool {
        #if os(iOS)
        entry.voiceBriefID != nil
        #else
        false
        #endif
    }

    private var usesMobileItemControls: Bool {
        #if os(iOS)
        model.activeSection == .items
        #else
        false
        #endif
    }
}

private struct ShareDocumentView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: LibraryModel
    let entry: LibraryEntry
    @State private var link: BrieflyShareLinkStatus?
    @State private var isBusy = false
    @State private var errorMessage = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(
                        "Publish the available summaries for “\(entry.title)”. " +
                            "The private captured source text is never included."
                    )
                    .foregroundStyle(.secondary)
                }
                if !model.account.authenticated {
                    Section {
                        Label(
                            "Sign in to your Briefly account in Settings before publishing.",
                            systemImage: "person.crop.circle.badge.exclamationmark"
                        )
                    }
                } else if let urlString = link?.url, let url = URL(string: urlString) {
                    Section("Shareable reader") {
                        Text(url.absoluteString)
                            .font(.system(.callout, design: .monospaced))
                            .textSelection(.enabled)
                        HStack {
                            Button {
                                copyShareURL(url)
                            } label: {
                                Label("Copy link", systemImage: "doc.on.doc")
                            }
                            ShareLink(item: url) {
                                Label("Share…", systemImage: "square.and.arrow.up")
                            }
                            Spacer()
                            Button("Stop sharing", role: .destructive) {
                                Task { await revoke() }
                            }
                        }
                    }
                } else if link?.shared == true {
                    Section {
                        Label(
                            "The shareable reader is being prepared.",
                            systemImage: "clock"
                        )
                    }
                } else {
                    Section {
                        Button {
                            Task { await publish() }
                        } label: {
                            Label("Create share link", systemImage: "link.badge.plus")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isBusy)
                    }
                }
                if !errorMessage.isEmpty {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Share link")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task { await load() }
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 310)
        #endif
    }

    private func load() async {
        guard model.account.authenticated else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            link = try await model.shareStatus(for: entry)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func publish() async {
        isBusy = true
        errorMessage = ""
        defer { isBusy = false }
        do {
            link = try await model.publishShare(for: entry)
            if let value = link?.url, let url = URL(string: value) {
                copyShareURL(url)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func revoke() async {
        guard let token = link?.token else { return }
        isBusy = true
        errorMessage = ""
        defer { isBusy = false }
        do {
            try await model.revokeShare(token)
            link = BrieflyShareLinkStatus(
                shared: false,
                token: nil,
                url: nil,
                status: nil,
                error: nil
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func copyShareURL(_ url: URL) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
        #else
        UIPasteboard.general.url = url
        #endif
    }
}

private struct MarkdownArticle: View {
    let lines: [String]

    init(_ text: String) {
        lines = text.replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                MarkdownLine(line: line)
            }
        }
        .textSelection(.enabled)
    }
}

private struct MarkdownLine: View {
    let line: String

    var body: some View {
        if line.isEmpty {
            Color.clear.frame(height: 16)
        } else if line.hasPrefix("# ") {
            markdownText(String(line.dropFirst(2)))
                .font(.system(size: 28, weight: .bold, design: .serif))
                .lineSpacing(4)
                .padding(.bottom, 2)
        } else if line.hasPrefix("## ") {
            markdownText(String(line.dropFirst(3)))
                .font(.system(size: 23, weight: .bold, design: .serif))
                .padding(.top, 8)
        } else if line.hasPrefix("### ") {
            markdownText(String(line.dropFirst(4)))
                .font(.system(size: 19, weight: .bold, design: .serif))
                .padding(.top, 6)
        } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("•")
                markdownText(String(line.dropFirst(2)))
            }
            .articleBodyStyle()
        } else if line.hasPrefix("> ") {
            markdownText(String(line.dropFirst(2)))
                .articleBodyStyle()
                .italic()
                .foregroundStyle(.secondary)
                .padding(.leading, 14)
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(.secondary.opacity(0.35))
                        .frame(width: 3)
                }
        } else {
            markdownText(line)
                .articleBodyStyle()
        }
    }

    private func markdownText(_ value: String) -> Text {
        guard let attributed = try? AttributedString(
            markdown: value,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) else {
            return Text(value)
        }
        return Text(attributed)
    }
}

private extension View {
    func articleBodyStyle() -> some View {
        font(.system(size: 19, weight: .regular, design: .serif))
            .lineSpacing(7)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct VoiceBriefConfiguration: View {
    @Bindable var model: LibraryModel
    @State private var title = ""
    @State private var prompt = ""
    @State private var schedule = "manual"
    @State private var length = ""
    @State private var sources = ""
    @State private var prioritizeForMe = false
    @State private var confirmsTrash = false

    private var selectedSources: Set<String> {
        Set(
            sources.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        )
    }

    private var canSave: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        ScrollView {
            if model.canEdit &&
                (model.selectedVoiceBrief != nil || model.selectedVoiceBriefID == "new")
            {
                VStack(alignment: .leading, spacing: 28) {
                    TextField("Voice brief title", text: $title)
                        .textFieldStyle(.plain)
                        .font(.system(size: 42, weight: .bold, design: .serif))

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Editorial direction")
                            .font(.headline)
                        Text("Tell Briefly what to prioritize, connect, or leave out.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        TextEditor(text: $prompt)
                            .font(.body)
                            .frame(minHeight: 130)
                            .padding(8)
                            .background(.background)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .overlay {
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(.primary.opacity(0.14))
                            }
                    }

                    Toggle(isOn: $prioritizeForMe) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Prioritize for me")
                                .font(.headline)
                            Text("Use personal context to decide which updates deserve attention.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.switch)

                    VStack(alignment: .leading, spacing: 14) {
                        HStack(alignment: .bottom) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Channels")
                                    .font(.headline)
                                Text("Choose from your configured Channel library.")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text("\(selectedSources.count) selected")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        if model.channels.isEmpty {
                            Label(
                                "Add channels in the Channel tab, then choose them here.",
                                systemImage: "dot.radiowaves.left.and.right"
                            )
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 86)
                            .background(.primary.opacity(0.025))
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .overlay {
                                RoundedRectangle(cornerRadius: 10)
                                    .stroke(
                                        .primary.opacity(0.14),
                                        style: StrokeStyle(dash: [4])
                                    )
                            }
                        } else {
                            VStack(spacing: 0) {
                                ForEach(model.channels) { channel in
                                    Button {
                                        toggleSource(channel.source)
                                    } label: {
                                        HStack(spacing: 11) {
                                            Image(
                                                systemName: selectedSources.contains(channel.source)
                                                    ? "checkmark.circle.fill"
                                                    : "circle"
                                            )
                                            .foregroundStyle(
                                                selectedSources.contains(channel.source)
                                                    ? Color.accentColor
                                                    : Color.secondary
                                            )
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(channel.title)
                                                    .font(.system(size: 13, weight: .semibold))
                                                Text(channel.source)
                                                    .font(.caption)
                                                    .foregroundStyle(.secondary)
                                                    .lineLimit(1)
                                            }
                                            Spacer(minLength: 12)
                                            Text("\(channel.items.count)")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                        .padding(.horizontal, 12)
                                        .frame(minHeight: 52)
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .background(
                                        selectedSources.contains(channel.source)
                                            ? Color.accentColor.opacity(0.1)
                                            : Color.clear
                                    )

                                    if channel.id != model.channels.last?.id {
                                        Divider()
                                    }
                                }
                            }
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .overlay {
                                RoundedRectangle(cornerRadius: 10)
                                    .stroke(.primary.opacity(0.14))
                            }
                        }
                    }

                    HStack(spacing: 18) {
                        LabeledField(
                            label: "Schedule",
                            placeholder: "manual",
                            value: $schedule
                        )
                        LabeledField(
                            label: "Length",
                            placeholder: "about 5 minutes",
                            value: $length
                        )
                    }

                    HStack {
                        if model.selectedVoiceBrief != nil {
                            Button("Move voice brief to Trash", role: .destructive) {
                                confirmsTrash = true
                            }
                        }
                        Spacer()
                    }
                }
                .padding(.horizontal, 34)
                .padding(.vertical, 58)
                .frame(maxWidth: 900, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
            } else if let brief = model.selectedVoiceBrief {
                ConfigurationCard(
                    eyebrow: "VOICE BRIEF",
                    title: brief.title,
                    description: "A scheduled private synthesis of the sources below."
                ) {
                    LabeledContent("Schedule", value: brief.schedule)
                    LabeledContent("Length", value: brief.length)
                    LabeledContent("Sources", value: brief.sources.joined(separator: "\n"))
                }
            } else {
                ContentUnavailableView(
                    "No voice briefs",
                    systemImage: "headphones",
                    description: Text("Create a voice brief to gather and synthesize channels.")
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .safeAreaInset(edge: .top, spacing: 0) {
            if model.canEdit &&
                (model.selectedVoiceBrief != nil || model.selectedVoiceBriefID == "new")
            {
                HStack(spacing: 10) {
                    Spacer(minLength: 0)
                    Text(model.status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    if model.selectedVoiceBrief != nil {
                        #if os(macOS)
                        Button {
                            Task {
                                if let url = await model.selectedVoiceBriefFileURL() {
                                    NSWorkspace.shared.activateFileViewerSelecting([url])
                                }
                            }
                        } label: {
                            Label("File", systemImage: "doc")
                        }
                        #endif

                        Button {
                            Task { await model.checkSelectedVoiceBriefChannels() }
                        } label: {
                            Label("Check", systemImage: "arrow.clockwise")
                        }

                        Button {
                            Task { await model.runSelectedVoiceBrief() }
                        } label: {
                            if model.isRunningVoiceBrief {
                                ProgressView().controlSize(.small)
                            } else {
                                Label("Generate", systemImage: "sparkles")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(
                            model.isRunningVoiceBrief ||
                                model.selectedVoiceBrief?.sources.isEmpty != false
                        )
                    }

                    Button {
                        Task { await save() }
                    } label: {
                        Label("Save", systemImage: "checkmark")
                    }
                    .disabled(!canSave)
                }
                .padding(.horizontal, 18)
                .frame(height: 56)
                .background(readerBackground)
                .overlay(alignment: .bottom) { Divider() }
            }
        }
        .task(id: model.selectedVoiceBriefID) {
            loadDraft()
        }
        .confirmationDialog(
            "Move this voice brief to Trash?",
            isPresented: $confirmsTrash
        ) {
            Button("Move to Trash", role: .destructive) {
                Task { await model.trashSelectedVoiceBrief() }
            }
        }
    }

    private func save() async {
        await model.saveVoiceBrief(
            LibraryVoiceBriefDraft(
                id: model.selectedVoiceBrief?.id,
                title: title,
                schedule: schedule,
                length: length,
                sources: Array(selectedSources),
                prompt: prompt,
                prioritizeForMe: prioritizeForMe
            )
        )
    }

    private func toggleSource(_ source: String) {
        var selected = selectedSources
        if selected.remove(source) == nil {
            selected.insert(source)
        }
        sources = model.channels.compactMap {
            selected.contains($0.source) ? $0.source : nil
        }.joined(separator: "\n")
    }

    private func loadDraft() {
        if let brief = model.selectedVoiceBrief {
            title = brief.title
            prompt = brief.prompt ?? "Connect the most important updates into one concise, conversational briefing."
            schedule = brief.schedule
            length = brief.length
            sources = brief.sources.joined(separator: "\n")
            prioritizeForMe = brief.prioritizeForMe == true
        } else {
            title = "New voice brief"
            prompt = "Connect the most important updates into one concise, conversational briefing."
            schedule = "manual"
            length = ""
            sources = ""
            prioritizeForMe = false
        }
    }
}

private struct LabeledField: View {
    let label: String
    let placeholder: String
    @Binding var value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(label)
                .font(.headline)
            TextField(placeholder, text: $value)
                .textFieldStyle(.roundedBorder)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct ChannelConfiguration: View {
    @Bindable var model: LibraryModel
    @Binding var showsChannelBrowser: Bool
    @State private var source = ""
    @State private var retrievalCount = 5
    @State private var confirmsRemoval = false

    var body: some View {
        ScrollView {
            if model.selectedChannelSource == "new" {
                ConfigurationCard(
                    eyebrow: "CHANNEL",
                    title: "Add channel",
                    description: "Add a publication, feed, podcast, profile, or web page."
                ) {
                    TextField("https://example.com/feed", text: $source)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                        .onSubmit {
                            Task { await model.addChannel(source) }
                        }
                    HStack {
                        Button {
                            showsChannelBrowser = true
                        } label: {
                            Label("Open signed-in browser", systemImage: "globe")
                        }
                        Spacer()
                        Button {
                            Task { await model.addChannel(source) }
                        } label: {
                            Label("Add channel", systemImage: "plus")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(
                            source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        )
                    }
                }
            } else if let channel = model.selectedChannel {
                ConfigurationCard(
                    eyebrow: "CHANNEL",
                    title: channel.title,
                    description: channel.source
                ) {
                    LabeledContent(
                        "Captured items",
                        value: model.channelEntries(for: channel.source).count.formatted()
                    )
                    LabeledContent(
                        "Type",
                        value: channel.kind?.rawValue.capitalized ?? "Not checked"
                    )
                    LabeledContent(
                        "Last checked",
                        value: channel.lastCheckedAt ?? "Never"
                    )
                    if !channel.briefTitles.isEmpty {
                        LabeledContent(
                            "Voice briefs",
                            value: channel.briefTitles.joined(separator: ", ")
                        )
                    }
                    if let error = channel.error {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.callout)
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    }
                    Stepper(
                        "Items per check: \(retrievalCount)",
                        value: $retrievalCount,
                        in: 1...100
                    )
                    .onChange(of: retrievalCount) {
                        Task {
                            await model.updateSelectedChannel(
                                retrievalCount: retrievalCount
                            )
                        }
                    }
                    HStack {
                        Button {
                            Task { await model.checkSelectedChannel() }
                        } label: {
                            if model.isCheckingChannel {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Label("Check now", systemImage: "arrow.clockwise")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.isCheckingChannel)
                        Button {
                            Task {
                                await model.checkSelectedChannel(loadMore: true)
                            }
                        } label: {
                            Label("Load more", systemImage: "arrow.down")
                        }
                        .disabled(model.isCheckingChannel || !channel.canLoadMore)
                    }
                    HStack {
                        if let url = URL(string: channel.source) {
                            Link(destination: url) {
                                Label("Open channel", systemImage: "arrow.up.right")
                            }
                        }
                        Button {
                            showsChannelBrowser = true
                        } label: {
                            Label("Sign in", systemImage: "person.crop.circle")
                        }
                    }
                    Divider()
                    Button("Remove channel", role: .destructive) {
                        confirmsRemoval = true
                    }
                }
            } else {
                ContentUnavailableView(
                    "No channels",
                    systemImage: "dot.radiowaves.left.and.right",
                    description: Text("Add a channel to gather new material.")
                )
            }
        }
        .task(id: model.selectedChannelSource) {
            source = model.selectedChannelSource == "new"
                ? ""
                : model.selectedChannelSource
            retrievalCount = model.selectedChannel?.retrievalCount ?? 5
        }
        .confirmationDialog(
            "Remove this channel? Existing voice briefs keep their source reference.",
            isPresented: $confirmsRemoval
        ) {
            Button("Remove Channel", role: .destructive) {
                Task { await model.removeSelectedChannel() }
            }
        }
    }
}

private struct ConfigurationCard<Content: View>: View {
    let eyebrow: String
    let title: String
    let description: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text(eyebrow)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.system(.largeTitle, design: .serif, weight: .bold))
            Text(description)
                .font(.title3)
                .foregroundStyle(.secondary)
            Divider()
            content
        }
        .frame(maxWidth: 720, alignment: .leading)
        .padding(.horizontal, 34)
        .padding(.vertical, 58)
        .frame(maxWidth: .infinity)
    }
}

#if os(macOS)
private struct ShortcutRecorder: NSViewRepresentable {
    @Binding var shortcut: CaptureShortcut

    func makeNSView(context: Context) -> RecorderButton {
        let button = RecorderButton()
        button.onShortcut = { shortcut = $0 }
        button.displayedShortcut = shortcut
        return button
    }

    func updateNSView(_ button: RecorderButton, context: Context) {
        button.onShortcut = { shortcut = $0 }
        button.displayedShortcut = shortcut
    }

    final class RecorderButton: NSButton {
        var onShortcut: (CaptureShortcut) -> Void = { _ in }
        var displayedShortcut = CaptureShortcut.defaultValue {
            didSet {
                if !recording { title = displayedShortcut.label }
            }
        }
        private var recording = false

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            bezelStyle = .rounded
            setButtonType(.momentaryPushIn)
            title = displayedShortcut.label
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError()
        }

        override var acceptsFirstResponder: Bool { true }

        override func mouseDown(with event: NSEvent) {
            recording = true
            title = "Press shortcut…"
            window?.makeFirstResponder(self)
        }

        override func keyDown(with event: NSEvent) {
            if
                event.keyCode == UInt16(kVK_Escape),
                event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty
            {
                _ = window?.makeFirstResponder(nil)
                return
            }
            guard let value = CaptureShortcut(event: event) else {
                NSSound.beep()
                return
            }
            onShortcut(value)
            _ = window?.makeFirstResponder(nil)
        }

        override func resignFirstResponder() -> Bool {
            recording = false
            title = displayedShortcut.label
            return super.resignFirstResponder()
        }
    }
}
#endif

private enum BrieflySettingsSection: String, CaseIterable, Identifiable {
    case general
    case library
    case capture
    case account
    case personalization
    case topics
    case ai
    case agent

    var id: Self { self }

    var title: String {
        switch self {
        case .general: "General"
        case .library: "Library & Sync"
        case .capture: "Capture"
        case .account: "Account"
        case .personalization: "Personalization"
        case .topics: "Topics"
        case .ai: "AI Processing"
        case .agent: "Open Agent"
        }
    }

    var icon: String {
        switch self {
        case .general: "gearshape"
        case .library: "folder"
        case .capture: "keyboard"
        case .account: "person.crop.circle"
        case .personalization: "person.text.rectangle"
        case .topics: "number"
        case .ai: "sparkles"
        case .agent: "terminal"
        }
    }
}

private struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("BrieflyAppearance") private var appearance = "system"
    #if os(macOS)
    @State private var captureShortcut = CaptureShortcut.load()
    @State private var shortcutRegistered = UserDefaults.standard.bool(
        forKey: "BrieflyCaptureShortcutRegistered"
    )
    #endif
    @Bindable var model: LibraryModel
    @State private var showsChannelBrowser = false
    @State private var showsAccountBrowser = false
    @State private var accountBrowserURL = BrieflyBackend.shared.accountURL
    @State private var showsWorkspaceImporter = false
    @State private var showsPDFImporter = false
    @State private var selectedSection: BrieflySettingsSection? = .general

    private var availableSections: [BrieflySettingsSection] {
        #if os(macOS)
        BrieflySettingsSection.allCases
        #else
        BrieflySettingsSection.allCases.filter { $0 != .agent }
        #endif
    }

    var body: some View {
        NavigationSplitView {
            List(availableSections, selection: $selectedSection) { section in
                Label(section.title, systemImage: section.icon)
                    .tag(section)
            }
            .navigationTitle("Briefly Settings")
            #if os(macOS)
            .navigationSplitViewColumnWidth(min: 190, ideal: 210)
            #endif
        } detail: {
            NavigationStack {
                Form {
                    switch selectedSection ?? .general {
                    case .general:
                Section("Appearance") {
                    Picker("Mode", selection: $appearance) {
                        Text("System").tag("system")
                        Text("Light").tag("light")
                        Text("Dark").tag("dark")
                    }
                    .pickerStyle(.segmented)
                }

                    case .library:
                Section("Library") {
                    LabeledContent(
                        "Workspace",
                        value: model.workspacePath ?? "Cloud library"
                    )
                    LabeledContent("Status", value: model.status)
                    if model.isSyncing {
                        if model.syncTotal > 0 {
                            ProgressView(
                                value: Double(model.syncCompleted),
                                total: Double(model.syncTotal)
                            )
                        } else {
                            ProgressView()
                        }
                    }
                    Button {
                        #if os(macOS)
                        model.chooseWorkspace()
                        #else
                        showsWorkspaceImporter = true
                        #endif
                    } label: {
                        Label("Choose Briefly library", systemImage: "folder")
                    }
                    if model.canEdit {
                        Button {
                            Task { await model.refreshWorkspace() }
                        } label: {
                            Label("Refresh workspace", systemImage: "arrow.clockwise")
                        }
                    }
                    Button {
                        Task { await model.sync() }
                    } label: {
                        Label("Sync with iCloud", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .disabled(model.isSyncing)
                }

                    case .capture:
                #if os(macOS)
                Section("Capture shortcut") {
                    HStack {
                        ShortcutRecorder(shortcut: $captureShortcut)
                            .frame(width: 150, height: 30)
                        Button("Reset") {
                            captureShortcut = .defaultValue
                        }
                        .disabled(captureShortcut == .defaultValue)
                    }
                    Text(
                        shortcutRegistered
                            ? "Active system-wide. Click the field and press a replacement shortcut."
                            : "This shortcut is unavailable; choose another combination."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                #endif

                Section("Capture tools") {
                    #if os(macOS)
                    if model.canEdit {
                        Button {
                            let text = NSPasteboard.general.string(forType: .string) ?? ""
                            Task { await model.capture(text) }
                        } label: {
                            Label("Capture clipboard", systemImage: "clipboard")
                        }
                    }
                    #endif
                    if model.canEdit {
                        Button {
                            showsPDFImporter = true
                        } label: {
                            Label("Import PDF", systemImage: "doc.richtext")
                        }
                    }
                    Button {
                        showsChannelBrowser = true
                    } label: {
                        Label("Signed-in browser", systemImage: "globe")
                    }
                }

                    case .account:
                Section("Briefly account") {
                    LabeledContent(
                        "Status",
                        value: model.account.authenticated
                            ? model.account.email ?? "Signed in"
                            : "Signed out"
                    )
                    if let provider = model.account.syncProvider {
                        LabeledContent("Library sync", value: provider.capitalized)
                    }
                    if model.account.authenticated {
                        LabeledContent(
                            "Membership",
                            value: model.account.entitled == true
                                ? "Active"
                                : "Needs activation"
                        )
                    }
                    if model.account.google?.configured == true {
                        LabeledContent(
                            "Google Drive",
                            value: model.account.google?.connected == true
                                ? "Connected"
                                : "Not connected"
                        )
                    }
                    if model.account.icloud?.configured == true {
                        LabeledContent(
                            "iCloud",
                            value: model.account.icloud?.connected == true
                                ? "Connected"
                                : "Not connected"
                        )
                    }
                    HStack {
                        if model.account.authenticated {
                            Button("Manage account") {
                                accountBrowserURL = BrieflyBackend.shared.accountURL
                                showsAccountBrowser = true
                            }
                            Button("Sign out", role: .destructive) {
                                Task { await model.signOut() }
                            }
                        } else {
                            Button("Sign in with Apple") {
                                accountBrowserURL = BrieflyBackend.shared.signInURL(
                                    provider: "apple"
                                )
                                showsAccountBrowser = true
                            }
                            Button("Sign in with Google") {
                                accountBrowserURL = BrieflyBackend.shared.signInURL(
                                    provider: "google"
                                )
                                showsAccountBrowser = true
                            }
                        }
                        Spacer()
                        Button {
                            Task { await model.refreshAccount(reportErrors: true) }
                        } label: {
                            if model.isCheckingAccount {
                                ProgressView()
                            } else {
                                Label("Refresh", systemImage: "arrow.clockwise")
                            }
                        }
                        .disabled(model.isCheckingAccount)
                    }
                }

                    case .personalization:
                Section("Personalization") {
                    TextField(
                        "About you",
                        text: $model.aboutYou,
                        axis: .vertical
                    )
                    .lineLimit(3...8)
                    Text("Used only when “Prioritize for me” is enabled.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextEditor(text: $model.voiceBriefPrompt)
                        .font(.system(.caption, design: .monospaced))
                        .frame(minHeight: 150)
                    HStack {
                        Button("Restore default voice prompt") {
                            model.voiceBriefPrompt = defaultVoiceBriefPrompt
                        }
                        Spacer()
                        Button("Save") {
                            model.savePersonalizationSettings()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }

                    case .topics:
                if model.canEdit {
                    Section("Topics") {
                        Text("One reusable topic per line, written as “id: Title”.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextEditor(text: $model.topicsText)
                            .font(.system(.body, design: .monospaced))
                            .frame(minHeight: 110)
                        HStack {
                            Spacer()
                            Button("Save topics") {
                                Task { await model.saveTopics() }
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                } else {
                    ContentUnavailableView(
                        "Topics need a workspace",
                        systemImage: "folder",
                        description: Text("Open a Briefly library to edit topics.")
                    )
                }

                    case .ai:
                Section("AI processing") {
                    #if os(macOS)
                    Toggle(
                        "Use Briefly AI",
                        isOn: Binding(
                            get: { model.usesManagedAI },
                            set: model.useManagedAI
                        )
                    )
                    if !model.usesManagedAI {
                        Menu("Choose processing preset") {
                            Button("Codex") {
                                model.processingCommand =
                                    defaultWorkspaceProcessingCommand
                            }
                            Button("Claude") {
                                model.processingCommand =
                                    #"claude -p --tools "" --strict-mcp-config --no-session-persistence"#
                            }
                            Button("Pi") {
                                model.processingCommand =
                                    "pi -p --no-tools --no-session --no-context-files --no-extensions --no-skills"
                            }
                            Button("OpenCode") {
                                model.processingCommand =
                                    #"opencode run --pure "$(cat)""#
                            }
                        }
                        TextField(
                            "Command",
                            text: $model.processingCommand,
                            axis: .vertical
                        )
                        .lineLimit(2...5)
                    }
                    #else
                    Label("Briefly AI", systemImage: "sparkles")
                    #endif
                    TextEditor(text: $model.processingPrompt)
                        .font(.system(.caption, design: .monospaced))
                        .frame(minHeight: 150)
                    HStack {
                        Button("Restore default prompt") {
                            model.processingPrompt = defaultWorkspaceProcessingPrompt
                        }
                        #if os(macOS)
                        Button {
                            Task { await model.testProcessingCommand() }
                        } label: {
                            if model.isTestingAI {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Text("Test command")
                            }
                        }
                        .disabled(model.isTestingAI)
                        #endif
                        Spacer()
                        Button("Save") {
                            model.saveProcessingSettings()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }

                    case .agent:
                #if os(macOS)
                Section("Open agent") {
                    Menu("Choose agent preset") {
                        Button("ChatGPT app") {
                            model.agentCommand =
                                "/usr/bin/open -a ChatGPT {{workspace}}"
                        }
                        Button("Claude app") {
                            model.agentCommand =
                                "claude://code/new?folder={{workspace}}"
                        }
                        Button("Codex") {
                            model.agentCommand = "cd {{workspace}} && codex"
                        }
                        Button("Claude Code") {
                            model.agentCommand = "cd {{workspace}} && claude"
                        }
                        Button("Pi") {
                            model.agentCommand = "cd {{workspace}} && pi"
                        }
                        Button("OpenCode") {
                            model.agentCommand = "cd {{workspace}} && opencode"
                        }
                    }
                    TextField(
                        "Command",
                        text: $model.agentCommand,
                        axis: .vertical
                    )
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(2...5)
                    Text("Use {{workspace}} where the Briefly library path belongs.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack {
                        Button("Open now") {
                            model.openAgent()
                        }
                        Spacer()
                        Button("Save") {
                            model.saveAgentSettings()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                #else
                EmptyView()
                #endif
                    }
                }
                .formStyle(.grouped)
                .navigationTitle((selectedSection ?? .general).title)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 900, minHeight: 650)
        .onChange(of: captureShortcut) {
            captureShortcut.save()
            NotificationCenter.default.post(
                name: .brieflyCaptureShortcutChanged,
                object: nil
            )
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: .brieflyCaptureShortcutRegistrationChanged
            )
        ) { notification in
            shortcutRegistered = notification.object as? Bool ?? false
        }
        #endif
        .fileImporter(
            isPresented: $showsWorkspaceImporter,
            allowedContentTypes: [.folder]
        ) { result in
            switch result {
            case .success(let url):
                Task {
                    await model.openWorkspace(url)
                    dismiss()
                }
            case .failure(let error):
                model.errorMessage = error.localizedDescription
            }
        }
        .fileImporter(
            isPresented: $showsPDFImporter,
            allowedContentTypes: [.pdf]
        ) { result in
            switch result {
            case .success(let url):
                Task {
                    await model.capturePDF(url)
                    dismiss()
                }
            case .failure(let error):
                model.errorMessage = error.localizedDescription
            }
        }
        .sheet(isPresented: $showsChannelBrowser) {
            ChannelLoginView()
        }
        .sheet(isPresented: $showsAccountBrowser) {
            ChannelLoginView(
                initialAddress: accountBrowserURL.absoluteString,
                navigationTitle: "Briefly account"
            )
            .onDisappear {
                Task { await model.refreshAccount(reportErrors: true) }
            }
        }
        .task { await model.refreshAccount() }
    }
}

private func channelTitle(_ source: String) -> String {
    guard let host = URL(string: source)?.host?.lowercased() else {
        return source
    }
    if host.contains("arxiv.org") { return "ArXiv" }
    if host.contains("ycombinator.com") { return "Hacker News" }
    if host.contains("reddit.com") { return "Reddit" }
    if host == "x.com" || host.hasSuffix(".x.com") || host.contains("twitter.com") {
        return "X"
    }
    return host
        .replacingOccurrences(of: "www.", with: "")
        .split(separator: ".")
        .first
        .map { String($0).capitalized } ?? source
}

private func localFaviconURL(
    for entry: LibraryEntry,
    workspacePath: String?
) -> URL? {
    if let workspacePath, let filename = entry.faviconFile {
        let url = URL(fileURLWithPath: workspacePath)
            .appending(path: "library", directoryHint: .isDirectory)
            .appending(path: "favicons", directoryHint: .isDirectory)
            .appending(path: filename)
        if FileManager.default.fileExists(atPath: url.path) { return url }
    }
    guard let favicon = entry.favicon else { return nil }
    let root = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appending(path: "Briefly", directoryHint: .isDirectory)
        .appending(path: "media", directoryHint: .isDirectory)
    let fileExtension = URL(fileURLWithPath: favicon.path).pathExtension
    let url = root.appending(path: "\(favicon.contentHash).\(fileExtension)")
    return FileManager.default.fileExists(atPath: url.path) ? url : nil
}

private func audioTime(_ value: Double) -> String {
    guard value.isFinite, value >= 0 else { return "0:00" }
    let seconds = Int(value)
    return "\(seconds / 60):\(String(format: "%02d", seconds % 60))"
}

private func appleScriptEscaped(_ value: String) -> String {
    value
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
        .replacingOccurrences(of: "\n", with: "\\n")
}

#if os(macOS)
private func adaptiveColor(
    light: (CGFloat, CGFloat, CGFloat),
    dark: (CGFloat, CGFloat, CGFloat)
) -> Color {
    Color(nsColor: NSColor(name: nil) { appearance in
        let components = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? dark
            : light
        return NSColor(
            srgbRed: components.0,
            green: components.1,
            blue: components.2,
            alpha: 1
        )
    })
}
#else
private func adaptiveColor(
    light: (CGFloat, CGFloat, CGFloat),
    dark: (CGFloat, CGFloat, CGFloat)
) -> Color {
    Color(uiColor: UIColor { traits in
        let components = traits.userInterfaceStyle == .dark ? dark : light
        return UIColor(
            red: components.0,
            green: components.1,
            blue: components.2,
            alpha: 1
        )
    })
}
#endif

private let appBackground = adaptiveColor(
    light: (0.957, 0.953, 0.941),
    dark: (0.055, 0.055, 0.060)
)

private let sidebarBackground = adaptiveColor(
    light: (0.975, 0.973, 0.965),
    dark: (0.095, 0.095, 0.105)
)

private let readerBackground = adaptiveColor(
    light: (0.986, 0.984, 0.976),
    dark: (0.075, 0.075, 0.083)
)

private enum NativeLibraryError: LocalizedError {
    case audioGenerationFailed
    case emptySpeech
    case iCloudUnavailable
    case emptyICloudLibrary
    case unexpectedAIResponse

    var errorDescription: String? {
        switch self {
        case .audioGenerationFailed:
            "The system voice could not create an audio file."
        case .emptySpeech:
            "The voice brief does not contain text to speak."
        case .iCloudUnavailable:
            "Sign in to iCloud and enable iCloud Drive for Briefly."
        case .emptyICloudLibrary:
            "iCloud is connected, but no Briefly library has been uploaded yet."
        case .unexpectedAIResponse:
            "The command ran, but returned an unexpected response."
        }
    }
}
