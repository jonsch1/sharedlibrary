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
    private static let processingDefaultCommand: String = {
        #if os(iOS)
        managedAICommand
        #else
        defaultProcessingCommand
        #endif
    }()
    private static let processingCommandKey = "BrieflyProcessingCommand"
    private static let processingPromptKey = "BrieflyProcessingPrompt"
    private static let voiceBriefPromptKey = "BrieflyVoiceBriefPrompt"
    private static let aboutYouKey = "BrieflyAboutYou"
    private let backend = BrieflyBackend.shared
    private var cloud: CloudDocumentSync?
    private var started = false
    private var library: SQLiteLibraryStore?
    private var pendingProcessingIDs = [String]()
    private var pendingSync: Task<Void, Never>?

    var isReady = false
    var projection = LibraryProjection.empty
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
    var status = "Loading library…"
    var errorMessage: String?
    var libraryChannels = [LibraryChannel]()
    var topicsText = ""
    var account = BrieflyAccountStatus.signedOut
    var processingCommand =
        UserDefaults.standard.string(forKey: LibraryModel.processingCommandKey) ??
        LibraryModel.processingDefaultCommand
    var processingPrompt =
        UserDefaults.standard.string(forKey: LibraryModel.processingPromptKey) ??
        defaultProcessingPrompt
    var voiceBriefPrompt =
        UserDefaults.standard.string(forKey: LibraryModel.voiceBriefPromptKey) ??
        defaultVoiceBriefPrompt
    var aboutYou =
        UserDefaults.standard.string(forKey: LibraryModel.aboutYouKey) ?? ""

    var canEdit: Bool {
        library != nil
    }

    private static var cloudKitAvailable: Bool {
        FileManager.default.fileExists(
            atPath: Bundle.main.bundleURL
                .appending(path: "_CodeSignature/CodeResources")
                .path
        )
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
        if library != nil { return libraryChannels }
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
        if usesDemo {
            projection = .demo
            status = "Showing the sample library"
        } else {
            let directory = FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appending(path: "Briefly", directoryHint: .isDirectory)
            let current = directory.appending(path: "library.sqlite3")
            let legacy = directory
                .appending(path: ".briefly", directoryHint: .isDirectory)
                .appending(path: "library.sqlite3")
            let databaseURL = FileManager.default.fileExists(atPath: current.path)
                ? current
                : FileManager.default.fileExists(atPath: legacy.path) ? legacy : current
            await openLibrary(databaseURL: databaseURL)
        }
        await selectInitialContent()
        await refreshAccount()
        await runDueVoiceBriefs()
    }

    func openLibrary(databaseURL: URL) async {
        do {
            let next = SQLiteLibraryStore(databaseURL: databaseURL)
            projection = try await next.loadProjection()
            libraryChannels = try await next.loadChannels()
            highlightsText = try await next.loadHighlights()
            topicsText = try await next.topicDefinitions()
                .map { "\($0.id): \($0.title)" }
                .joined(separator: "\n")
            library = next
            let database = try await next.documentDatabase()
            cloud = Self.cloudKitAvailable
                ? CloudDocumentSync(
                    store: database,
                    containerIdentifier: "iCloud.fyi.readbriefly"
                )
                : nil
            status = "Opened local SQLite library"
            await selectInitialContent()
            isReady = true
            await sync()
        } catch {
            library = nil
            libraryChannels = []
            isReady = true
            errorMessage = error.localizedDescription
        }
    }

    func refreshLibrary(selecting entryID: String? = nil) async {
        guard let library else { return }
        do {
            projection = try await library.loadProjection()
            libraryChannels = try await library.loadChannels()
            highlightsText = try await library.loadHighlights()
            topicsText = try await library.topicDefinitions()
                .map { "\($0.id): \($0.title)" }
                .joined(separator: "\n")
            status = "Refreshed the local database"
            await restoreSelection(preferredEntryID: entryID)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func capture(_ text: String) async {
        guard let library else {
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
                    id = try await ingestURL(url, in: library)
                } catch {
                    id = try await library.capture(trimmed)
                }
            } else {
                id = try await library.capture(trimmed)
            }
            await refreshLibrary(selecting: id)
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
        guard let library else {
            errorMessage = "Open a Briefly library before saving web pages."
            return
        }
        isIngesting = true
        defer { isIngesting = false }
        do {
            let id = try await library.captureWebPage(
                title: page.title,
                content: page.text,
                sourceURL: url,
                asVoiceBriefSource: activeSection == .channels,
                faviconData: page.faviconData,
                faviconFileExtension: page.faviconFileExtension
            )
            await refreshLibrary(selecting: id)
            status = "Saved the signed-in page. Preparing summaries…"
            isIngesting = false
            await enqueueProcessing(id)
            requestSync()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func capturePDF(_ url: URL) async {
        guard let library else {
            errorMessage = "Choose a local Briefly library before importing a PDF."
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
            let entryID = try await library.captureDocument(
                title: title,
                content: text
            )
            await refreshLibrary(selecting: entryID)
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
        guard let library, !entryID.isEmpty else { return }
        do {
            try await library.writeText(
                entryID: entryID,
                variant: variant,
                text: text
            )
            projection = try await library.loadProjection()
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
        guard let library, !selectedID.isEmpty else { return }
        do {
            try await library.addHighlight(
                entryID: selectedID,
                variant: selectedVariant,
                text: text
            )
            highlightsText = try await library.loadHighlights()
            status = "Added to Highlights"
            requestSync()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func removeHighlight(_ text: String) async {
        guard let library else { return }
        do {
            guard try await library.removeHighlight(text) else { return }
            highlightsText = try await library.loadHighlights()
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
        guard let library else { return }
        let ids = selectedEntryIDs(fallback: selectedID)
        guard !ids.isEmpty else { return }
        do {
            for id in ids {
                try await library.moveToTrash(entryID: id)
            }
            selectedID = ""
            selectedIDs = []
            await refreshLibrary()
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
        guard let library else {
            errorMessage = "Open a Briefly library before editing voice briefs."
            return nil
        }
        do {
            let id = try await library.saveVoiceBrief(draft)
            projection = try await library.loadProjection()
            libraryChannels = try await library.loadChannels()
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
            let library,
            !selectedVoiceBriefID.isEmpty,
            selectedVoiceBriefID != "new"
        else {
            return
        }
        do {
            try await library.moveVoiceBriefToTrash(id: selectedVoiceBriefID)
            projection = try await library.loadProjection()
            libraryChannels = try await library.loadChannels()
            selectedVoiceBriefID = projection.voiceBriefDefinitions.first?.id ?? ""
            selectedID = ""
            selectedIDs = []
            status = "Voice brief moved to Trash"
            requestSync()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func addChannel(_ source: String) async {
        guard let library else {
            errorMessage = "Open a Briefly library before adding channels."
            return
        }
        do {
            try await library.addChannel(source)
            libraryChannels = try await library.loadChannels()
            guard let added = libraryChannels.first(where: {
                $0.source == source.trimmingCharacters(in: .whitespacesAndNewlines)
            }) else {
                throw LibraryError.missingChannel
            }
            selectedChannelSource = added.source
            expandedChannelSources.insert(added.source)
            status = "Channel added"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func updateSelectedChannel(retrievalCount: Int) async {
        guard let library, let channel = selectedChannel else { return }
        do {
            try await library.updateChannel(
                channel.source,
                retrievalCount: retrievalCount
            )
            libraryChannels = try await library.loadChannels()
            status = "Channel settings saved"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func checkSelectedChannel(loadMore: Bool = false) async {
        guard
            let library,
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
                library,
                source: channel.source,
                loadMore: loadMore
            )
            projection = try await library.loadProjection()
            libraryChannels = try await library.loadChannels()
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
        guard let library, let channel = selectedChannel else { return }
        do {
            try await library.removeChannel(channel.source)
            projection = try await library.loadProjection()
            libraryChannels = try await library.loadChannels()
            expandedChannelSources.remove(channel.source)
            selectedChannelSource = libraryChannels.first?.source ?? ""
            selectedID = ""
            selectedIDs = []
            status = "Channel removed"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func checkSelectedVoiceBriefChannels() async {
        guard
            let library,
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
                let result = try await retrieveChannel(library, source: source)
                newEntryIDs += result.newEntryIDs
            }
            projection = try await library.loadProjection()
            libraryChannels = try await library.loadChannels()
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
        guard let library, !isRunningVoiceBrief else { return }
        do {
            let due = try await library.dueVoiceBriefIDs()
            for id in due {
                guard let brief = projection.voiceBriefDefinitions.first(where: {
                    $0.id == id
                }) else {
                    continue
                }
                try await library.markVoiceBriefAttempt(id: id)
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
        guard let library, !isRunningVoiceBrief else { return }
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
                    library,
                    source: source
                ).newEntryIDs
            }
            projection = try await library.loadProjection()
            libraryChannels = try await library.loadChannels()
            for entryID in newEntryIDs {
                await enqueueProcessing(entryID)
            }
            status = "Writing \(brief.title)…"
            let episode: LibraryVoiceBriefEpisodeResult
            if usesManagedAI {
                episode = try await library.runVoiceBrief(
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
                episode = try await library.runVoiceBrief(
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
            try await library.attachAudio(entryID: episode.entryID, file: audioURL)
            projection = try await library.loadProjection()
            libraryChannels = try await library.loadChannels()
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
                output = try await runProcessingCommand(
                    processingCommand,
                    prompt: prompt,
                    timeout: 60
                )
                #else
                throw LibraryError.processingUnavailable
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
            : defaultProcessingCommand
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
        guard let library else { return }
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
            let saved = try await library.replaceTopicDefinitions(definitions)
            topicsText = saved.map { "\($0.id): \($0.title)" }
                .joined(separator: "\n")
            projection = try await library.loadProjection()
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
        let filename = captureID
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

    func audioURL(for entryID: String) async -> URL? {
        do {
            if let library {
                return try await library.audioURL(entryID: entryID)
            }
            return nil
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func faviconURL(for entryID: String) async -> URL? {
        if let library {
            return try? await library.faviconURL(entryID: entryID)
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
            guard let library else { return }
            guard let cloud else {
                status = "Using the local SQLite library"
                return
            }
            guard try await cloud.accountStatus() == .available else {
                throw NativeLibraryError.iCloudUnavailable
            }
            status = "Synchronizing records…"
            try await cloud.synchronize()
            projection = try await library.loadProjection()
            libraryChannels = try await library.loadChannels()
            highlightsText = try await library.loadHighlights()
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
        _ library: SQLiteLibraryStore,
        source: String,
        loadMore: Bool = false
    ) async throws -> LibraryChannelRefresh {
        let ingest: @Sendable (LibraryChannelCandidate) async throws -> String = {
            candidate in
            guard let url = URL(string: candidate.url) else {
                throw LibraryError.invalidChannel
            }
            return try await self.ingestURL(
                url,
                in: library,
                candidate: candidate,
                asVoiceBriefSource: true
            )
        }
        let host = URL(string: source)?.host?.lowercased() ?? ""
        if host == "x.com" || host.hasSuffix(".x.com") || host.contains("twitter.com") {
            guard let url = URL(string: source) else {
                throw LibraryError.invalidChannel
            }
            let page = try await ChannelBrowserSession.shared.extractPage(from: url)
            if !page.items.isEmpty {
                return try await library.captureSignedInChannelItems(
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
            return try await library.captureSignedInChannelPage(
                source: source,
                title: page.title,
                content: page.text,
                ingest: ingest
            )
        }
        if loadMore {
            return try await library.loadMoreChannel(source, ingest: ingest)
        }
        return try await library.checkChannel(source, ingest: ingest)
    }

    private func ingestURL(
        _ url: URL,
        in library: SQLiteLibraryStore,
        candidate: LibraryChannelCandidate? = nil,
        asVoiceBriefSource: Bool = false
    ) async throws -> String {
        do {
            let page = try await ChannelBrowserSession.shared.extractPage(from: url)
            return try await library.captureWebPage(
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
            return try await library.captureWebPage(
                title: candidate.title,
                content: candidate.content,
                sourceURL: url,
                asVoiceBriefSource: asVoiceBriefSource
            )
        }
    }

    private func process(_ entryID: String) async {
        guard let library else { return }
        do {
            status = "Preparing summaries…"
            let prompt = try await library.processingPrompt(
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
                output = try await runProcessingCommand(
                    processingCommand,
                    prompt: prompt
                )
                #else
                throw LibraryError.processingUnavailable
                #endif
            }
            let suggestion = try ProcessingSuggestion.decode(output)
            let processedID = try await library.applyProcessingSuggestion(
                entryID: entryID,
                suggestion: suggestion
            )
            await refreshLibrary(selecting: processedID)
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
        if let library {
            highlightsText = (try? await library.loadHighlights()) ?? ""
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
    private var sleepTimer: Timer?
    private(set) var currentEntryID: String?
    var isPlaying = false
    var currentTime = 0.0
    var duration = 0.0
    var sleepTimerMinutes: Int?
    var rate = UserDefaults.standard.double(forKey: "BrieflyAudioRate").nonzero ?? 1
    var volume = UserDefaults.standard.object(forKey: "BrieflyAudioVolume") == nil
        ? 1
        : UserDefaults.standard.double(forKey: "BrieflyAudioVolume")

    func toggle(_ url: URL, entryID: String) throws {
        if currentURL == url, let player {
            if player.isPlaying {
                pause()
            } else {
                resume()
            }
            return
        }
        stop()
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .spokenAudio)
        try session.setActive(true)
        #endif
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
        guard player.play() else {
            throw NativeLibraryError.audioPlaybackFailed
        }
        self.player = player
        currentURL = url
        currentEntryID = entryID
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

    func skip(by seconds: Double) {
        seek(currentTime + seconds)
    }

    func pause() {
        guard let player else { return }
        player.pause()
        isPlaying = false
        savePosition()
    }

    func resume() {
        guard let player else { return }
        guard player.play() else {
            isPlaying = false
            return
        }
        isPlaying = true
        startTimer()
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

    func setSleepTimer(minutes: Int?) {
        sleepTimer?.invalidate()
        sleepTimer = nil
        sleepTimerMinutes = minutes
        guard let minutes else { return }
        sleepTimer = Timer.scheduledTimer(
            withTimeInterval: Double(minutes * 60),
            repeats: false
        ) { [weak self] _ in
            self?.pause()
            self?.sleepTimer = nil
            self?.sleepTimerMinutes = nil
        }
    }

    func stop() {
        savePosition()
        timer?.invalidate()
        timer = nil
        setSleepTimer(minutes: nil)
        player?.stop()
        player = nil
        currentURL = nil
        currentEntryID = nil
        positionKey = nil
        isPlaying = false
        currentTime = 0
        duration = 0
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        timer?.invalidate()
        timer = nil
        setSleepTimer(minutes: nil)
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
    @State private var showsPDFImporter = false
    @State private var sidebarVisible = true
    @State private var windowControlsVisible = true
    @State private var audioPlayer = NativeAudioPlayer()
    #if os(iOS)
    @State private var preferredCompactColumn = NavigationSplitViewColumn.sidebar
    @State private var audioEntry: LibraryEntry?
    @State private var homeSelected = true
    #endif

    var body: some View {
        Group {
            if model.isReady {
                #if os(macOS)
                HStack(spacing: 6) {
                if sidebarVisible {
                    LibrarySidebar(
                        model: model,
                        showsSettings: $showsSettings,
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
                    Group {
                        if homeSelected {
                            MobileHome(
                                model: model,
                                showsSettings: $showsSettings,
                                onOpenDetail: { preferredCompactColumn = .detail }
                            )
                        } else {
                            LibrarySidebar(
                                model: model,
                                showsSettings: $showsSettings,
                                sidebarVisible: .constant(true),
                                onOpenDetail: { preferredCompactColumn = .detail }
                            )
                        }
                    }
                    .navigationSplitViewColumnWidth(min: 285, ideal: 326)
                } detail: {
                    LibraryDetail(
                        model: model,
                        showsChannelBrowser: $showsChannelBrowser,
                        audioPlayer: audioPlayer
                    )
                }
                #endif
            } else {
                ProgressView(model.status)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
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
                Task {
                    #if os(iOS)
                    if model.canEdit { await model.sync() }
                    #endif
                    await model.runDueVoiceBriefs()
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .CKAccountChanged)) { _ in
            Task {
                if model.canEdit { await model.sync() }
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
                homeSelected: $homeSelected,
                audioPlayer: audioPlayer,
                audioEntry: $audioEntry
            )
        }
        .sheet(item: $audioEntry) { entry in
            MobileAudioPlayer(
                text: model.selectedText.isEmpty
                    ? entry.text(for: model.selectedVariant)?.text ?? entry.excerpt
                    : model.selectedText,
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
            NotificationCenter.default.publisher(for: .brieflyImportPDF)
        ) { _ in
            showsPDFImporter = true
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .brieflyRefreshLibrary)
        ) { _ in
            Task<Void, Never> { await model.refreshLibrary() }
        }
        #endif
        .preferredColorScheme(
            appearance == "light" ? .light :
                appearance == "dark" ? .dark : nil
        )
    }
}

#if os(iOS)
private struct MobileHome: View {
    @Bindable var model: LibraryModel
    @Binding var showsSettings: Bool
    let onOpenDetail: () -> Void

    private var entries: [LibraryEntry] {
        model.projection.entries
            .filter { $0.entryType != "voice_brief_source" && $0.matches(model.query) }
            .sorted {
                ($0.createdAt ?? $0.updatedAt ?? "") >
                    ($1.createdAt ?? $1.updatedAt ?? "")
            }
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                HStack {
                    Button {
                        showsSettings = true
                    } label: {
                        Image(systemName: "line.3.horizontal")
                            .font(.system(size: 20, weight: .medium))
                            .frame(width: 44, height: 44)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .mobileGlass(in: Circle())
                    .accessibilityLabel("Settings")

                    Spacer()
                }

                HStack(spacing: 8) {
                    Image("BrieflyMark")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 32, height: 32)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    Text("BRIEFLY")
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                        .tracking(3)
                }
                .accessibilityElement(children: .combine)
            }
            .padding(.horizontal, 18)
            .frame(height: 64)

            if entries.isEmpty {
                ContentUnavailableView(
                    model.query.isEmpty ? "Nothing here yet" : "No recent matches",
                    systemImage: model.query.isEmpty ? "tray" : "magnifyingglass",
                    description: Text(
                        model.query.isEmpty
                            ? "New items and voice briefs will appear here."
                            : "Try another search."
                    )
                )
                .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(entries) { entry in
                            MobileEntryCard(
                                entry: entry,
                                kind: entry.voiceBriefID == nil ? .item : .brief
                            ) {
                                Task {
                                    model.activeSection = entry.voiceBriefID == nil
                                        ? .items
                                        : .briefs
                                    model.selectedVoiceBriefID = entry.voiceBriefID ?? ""
                                    await model.select(entry.id)
                                    onOpenDetail()
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                    .padding(.bottom, 150)
                }
                .scrollIndicators(.hidden)
            }
        }
        .background(sidebarBackground.ignoresSafeArea())
    }
}

private enum MobileEntryKind {
    case item
    case channel
    case brief

    var label: String {
        switch self {
        case .item: "Item"
        case .channel: "Channel"
        case .brief: "Voice brief"
        }
    }

    var color: Color {
        switch self {
        case .item: .purple
        case .channel: .orange
        case .brief: .blue
        }
    }
}

private struct MobileEntryCard: View {
    let entry: LibraryEntry
    let kind: MobileEntryKind
    var selected = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(kind.label.uppercased())
                        .font(.system(size: 10, weight: .bold))
                        .tracking(0.4)
                        .foregroundStyle(kind.color)
                    Spacer(minLength: 6)
                    if
                        let value = entry.createdAt ?? entry.updatedAt,
                        let date = try? Date(value, strategy: .iso8601)
                    {
                        Text(
                            date.formatted(
                                .relative(
                                    presentation: .named,
                                    unitsStyle: .abbreviated
                                )
                            )
                        )
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }

                Text(entry.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                    .lineLimit(2)

                if !entry.excerpt.isEmpty {
                    Text(entry.excerpt)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                        .lineLimit(1)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .mobileGlass(
            in: RoundedRectangle(cornerRadius: 16, style: .continuous),
            tint: selected ? kind.color.opacity(0.18) : nil
        )
    }
}

private struct MobileLibraryNavigation: View {
    @Bindable var model: LibraryModel
    @Binding var preferredCompactColumn: NavigationSplitViewColumn
    @Binding var showsPDFImporter: Bool
    @Binding var homeSelected: Bool
    @Bindable var audioPlayer: NativeAudioPlayer
    @Binding var audioEntry: LibraryEntry?
    @State private var showsSearch = false
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
                    TextField(
                        homeSelected ? "Search recent items" : model.activeSection.searchPrompt,
                        text: $model.query
                    )
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
                            showsSearch = false
                            model.query = ""
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
                    if !isItemDetail || selectedEntryHasAudio {
                        Button(action: primaryAction) {
                            Image(systemName: isPlayableDetail ? "play.fill" : "plus")
                                .font(.system(size: 23, weight: .medium))
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.white)
                        .frame(width: 58, height: 58)
                        .mobileGlass(in: Circle(), tint: .accentColor)
                        .accessibilityLabel(primaryActionLabel)
                    }

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
        if homeSelected { return "Import PDF" }
        switch model.activeSection {
        case .items: return "Import PDF"
        case .channels: return "New channel"
        case .briefs: return "New voice brief"
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

    private var selectedEntryHasAudio: Bool {
        guard let entry = model.selectedEntry else { return false }
        return entry.hasAudio == true || entry.audio != nil || entry.mediaURL != nil
    }

    private var isPlayableDetail: Bool {
        isVoiceBriefDetail || (isItemDetail && selectedEntryHasAudio)
    }

    private var primaryActionLabel: String {
        isPlayableDetail ? "Play audio" : createLabel
    }

    private func primaryAction() {
        if isPlayableDetail, let entry = model.selectedEntry {
            Task {
                guard let url = await model.audioURL(for: entry.id) else {
                    model.errorMessage = "This audio file is not available locally."
                    return
                }
                do {
                    if audioPlayer.currentEntryID != entry.id || !audioPlayer.isPlaying {
                        try audioPlayer.toggle(url, entryID: entry.id)
                    }
                    audioEntry = entry
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
        if homeSelected {
            showsPDFImporter = true
            return
        }
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

private struct MobileAudioPlayer: View {
    let text: String
    @Bindable var audioPlayer: NativeAudioPlayer

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                MarkdownArticle(text)
                    .padding(.horizontal, 24)
                    .padding(.top, 28)
                    .padding(.bottom, 20)
            }
            .scrollIndicators(.hidden)

            playbackControls
                .padding(.horizontal, 24)
                .padding(.top, 16)
                .padding(.bottom, 18)
        }
        .background(playerBackground.ignoresSafeArea())
        .presentationBackground(playerBackground)
        .presentationCornerRadius(32)
        .presentationDragIndicator(.visible)
        .presentationDetents([.large])
    }

    private var playbackControls: some View {
        VStack(spacing: 15) {
            VStack(spacing: 3) {
                Slider(
                    value: Binding(
                        get: { audioPlayer.currentTime },
                        set: audioPlayer.seek
                    ),
                    in: 0...max(1, audioPlayer.duration)
                )
                .tint(.primary)
                .accessibilityLabel("Playback position")

                HStack {
                    Text(audioTime(audioPlayer.currentTime))
                    Spacer()
                    Text("-\(audioTime(max(0, audioPlayer.duration - audioPlayer.currentTime)))")
                }
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
            }

            HStack(spacing: 0) {
                Menu {
                    ForEach([0.75, 1, 1.25, 1.5, 2], id: \.self) { speed in
                        Button {
                            audioPlayer.setRate(speed)
                        } label: {
                            HStack {
                                Text("\(speed.formatted())×")
                                if speed == audioPlayer.rate {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    Text("\(audioPlayer.rate.formatted())×")
                        .font(.callout.weight(.semibold))
                }
                .frame(maxWidth: .infinity)
                .accessibilityLabel("Playback speed")

                Button {
                    audioPlayer.skip(by: -15)
                } label: {
                    Image(systemName: "gobackward.15")
                        .font(.system(size: 27, weight: .medium))
                }
                .frame(maxWidth: .infinity)
                .accessibilityLabel("Skip back 15 seconds")

                Button {
                    audioPlayer.isPlaying
                        ? audioPlayer.pause()
                        : audioPlayer.resume()
                } label: {
                    Image(systemName: audioPlayer.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 42, weight: .medium))
                        .frame(width: 60, height: 60)
                }
                .frame(maxWidth: .infinity)
                .accessibilityLabel(audioPlayer.isPlaying ? "Pause audio" : "Play audio")

                Button {
                    audioPlayer.skip(by: 30)
                } label: {
                    Image(systemName: "goforward.30")
                        .font(.system(size: 27, weight: .medium))
                }
                .frame(maxWidth: .infinity)
                .accessibilityLabel("Skip forward 30 seconds")

                Menu {
                    Button {
                        audioPlayer.setSleepTimer(minutes: nil)
                    } label: {
                        HStack {
                            Text("Off")
                            if audioPlayer.sleepTimerMinutes == nil {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                    ForEach([5, 10, 15, 30, 45, 60], id: \.self) { minutes in
                        Button {
                            audioPlayer.setSleepTimer(minutes: minutes)
                        } label: {
                            HStack {
                                Text(minutes == 60 ? "1 hour" : "\(minutes) minutes")
                                if audioPlayer.sleepTimerMinutes == minutes {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    Image(
                        systemName: audioPlayer.sleepTimerMinutes == nil
                            ? "moon.zzz"
                            : "moon.zzz.fill"
                    )
                    .font(.system(size: 22, weight: .medium))
                }
                .frame(maxWidth: .infinity)
                .accessibilityLabel(
                    audioPlayer.sleepTimerMinutes.map {
                        "Sleep timer, \($0) minutes"
                    } ?? "Sleep timer"
                )
            }
            .frame(maxWidth: .infinity)
            .buttonStyle(.plain)

            HStack(spacing: 10) {
                Image(systemName: "speaker.fill")
                Slider(
                    value: Binding(
                        get: { audioPlayer.volume },
                        set: audioPlayer.setVolume
                    ),
                    in: 0...1
                )
                .tint(.primary)
                .accessibilityLabel("Volume")
                Image(systemName: "speaker.wave.3.fill")
            }
            .font(.caption)
        }
    }

    private var playerBackground: LinearGradient {
        LinearGradient(
            colors: [Color.accentColor.opacity(0.3), readerBackground],
            startPoint: .top,
            endPoint: .bottom
        )
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
                    showsSettings = true
                } label: {
                    Label("Settings", systemImage: "gearshape")
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
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
        .mobileGlass(in: Capsule())
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

    private var kind: MobileEntryKind {
        switch model.activeSection {
        case .items: .item
        case .channels: .channel
        case .briefs: .brief
        }
    }

    var body: some View {
        if entries.isEmpty {
            SidebarEmpty(icon: "doc.text", title: emptyTitle)
        } else {
            ForEach(entries) { entry in
                MobileEntryCard(
                    entry: entry,
                    kind: kind,
                    selected: model.selectedIDs.contains(entry.id)
                ) {
                    Task {
                        await model.select(entry.id)
                        onOpenDetail()
                    }
                }
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
                    imageURL: localFaviconURL(for: entry)
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
                                    for: entry
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
            bottom: 240,
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

    var id: Self { self }

    var title: String {
        switch self {
        case .general: "Appearance"
        case .library: "Library & Sync"
        case .capture: "Capture"
        case .account: "Account"
        case .personalization: "Personalization"
        case .topics: "Topics"
        case .ai: "AI Processing"
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
    @State private var showsPDFImporter = false
    #if os(iOS)
    @State private var selectedSection: BrieflySettingsSection?
    #else
    @State private var selectedSection: BrieflySettingsSection? = .general
    #endif

    private var availableSections: [BrieflySettingsSection] {
        BrieflySettingsSection.allCases
    }

    private func settingsRow(
        _ section: BrieflySettingsSection,
        value: String? = nil
    ) -> some View {
        HStack(spacing: 14) {
            Image(systemName: section.icon)
                .font(.system(size: 18, weight: .medium))
                .frame(width: 24)
            Text(section.title)
            Spacer()
            if let value {
                Text(value)
                    .foregroundStyle(.secondary)
            }
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .tag(section)
    }

    private func externalSettingsRow(
        _ title: String,
        icon: String,
        destination: String
    ) -> some View {
        Link(destination: URL(string: destination)!) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .medium))
                    .frame(width: 24)
                Text(title)
                Spacer()
                Image(systemName: "arrow.up.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .foregroundStyle(.primary)
        .accessibilityHint("Opens in your browser")
    }

    var body: some View {
        NavigationSplitView {
            #if os(iOS)
            List(selection: $selectedSection) {
                Section("General settings") {
                    settingsRow(
                        .account,
                        value: model.account.authenticated ? "Signed in" : "Signed out"
                    )
                    settingsRow(
                        .general,
                        value: appearance == "system" ? "Auto" : appearance.capitalized
                    )
                    settingsRow(.library)
                }

                Section("Briefly") {
                    settingsRow(.capture)
                    settingsRow(.personalization)
                }

                Section("Advanced") {
                    settingsRow(.topics)
                    settingsRow(.ai)
                }

                Section("Help") {
                    externalSettingsRow(
                        "Feedback",
                        icon: "bubble.left.and.bubble.right",
                        destination: "https://www.readbriefly.fyi/feedback"
                    )
                }

                Section("Legal") {
                    externalSettingsRow(
                        "Terms of Use",
                        icon: "doc.text",
                        destination: "https://www.readbriefly.fyi/terms"
                    )
                    externalSettingsRow(
                        "Privacy Policy",
                        icon: "hand.raised",
                        destination: "https://www.readbriefly.fyi/privacy"
                    )
                    externalSettingsRow(
                        "Imprint",
                        icon: "building.columns",
                        destination: "https://www.readbriefly.fyi/imprint"
                    )
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(readerBackground)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            #else
            List(availableSections, selection: $selectedSection) { section in
                Label(section.title, systemImage: section.icon)
                    .tag(section)
            }
            .navigationTitle("Briefly Settings")
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
                    LabeledContent("Storage", value: "Local SQLite database")
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
                    if model.canEdit {
                        Button {
                            Task { await model.refreshLibrary() }
                        } label: {
                            Label("Refresh library", systemImage: "arrow.clockwise")
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
                        "Topics need a library",
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
                                    defaultProcessingCommand
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
                            model.processingPrompt = defaultProcessingPrompt
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
    for entry: LibraryEntry
) -> URL? {
    guard let favicon = entry.favicon else { return nil }
    let url = URL(fileURLWithPath: favicon.path)
    return FileManager.default.fileExists(atPath: url.path) ? url : nil
}

private func audioTime(_ value: Double) -> String {
    guard value.isFinite, value >= 0 else { return "0:00" }
    let seconds = Int(value)
    return "\(seconds / 60):\(String(format: "%02d", seconds % 60))"
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
    case audioPlaybackFailed
    case emptySpeech
    case iCloudUnavailable
    case unexpectedAIResponse

    var errorDescription: String? {
        switch self {
        case .audioGenerationFailed:
            "The system voice could not create an audio file."
        case .audioPlaybackFailed:
            "Briefly could not start audio playback."
        case .emptySpeech:
            "The voice brief does not contain text to speak."
        case .iCloudUnavailable:
            "Sign in to iCloud and enable iCloud Drive for Briefly."
        case .unexpectedAIResponse:
            "The command ran, but returned an unexpected response."
        }
    }
}
