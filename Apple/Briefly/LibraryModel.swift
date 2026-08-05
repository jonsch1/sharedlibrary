import AVFoundation
import AuthenticationServices
import BrieflyCore
import CloudKit
import CryptoKit
import Observation
import StoreKit
import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
import Carbon.HIToolbox
#elseif os(iOS)
import BackgroundTasks
import MediaPlayer
import UIKit
#endif

enum LibrarySection: String, CaseIterable, Identifiable {
    case items
    case channels
    case briefs

    var id: Self { self }

    var title: String {
        switch self {
        case .items: "Home"
        case .channels: "Channels"
        case .briefs: "Briefs"
        }
    }

    var icon: String {
        switch self {
        case .items: "house"
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
struct BrieflyActivity: Identifiable {
    let id = UUID()
    let icon: String
    let title: String
    let detail: String
}
enum VoiceBriefGenerationPhase: Equatable {
    case retrieving
    case summarizing
    case assembling
}

struct VoiceBriefGenerationProgress {
    let voiceBriefID: String
    var phase = VoiceBriefGenerationPhase.retrieving
    var checkedChannelCount = 0
    var totalChannelCount = 0
    var retrievedItemCount = 0
    var summarizedItemCount = 0
    var failedItemCount = 0
}

private struct ProcessingJobResult: Sendable {
    let entryID: String
    let selectedID: String?
    let succeeded: Bool
}

@MainActor
@Observable
final class LibraryModel {
    private static let subscriptionProductID = "fyi.readbriefly.plus.monthly"
    private static let managedAICommand =
        "briefly://openrouter/openai/gpt-5.6-luna"
    private static let processingDefaultCommand = managedAICommand
    private static let processingCommandKey = "BrieflyProcessingCommand"
    private static let processingPromptKey = "BrieflyProcessingPrompt"
    private static let aboutYouKey = "BrieflyAboutYou"
    private let backend = BrieflyBackend.shared
    private let environment: AppEnvironment
    private var cloud: CloudDocumentSync?
    private var started = false
    private var library: SQLiteLibraryStore?
    private var hasLoadedChannels = false
    private var hasLoadedHighlights = false
    private var hasLoadedTrash = false
    private var pendingSync: Task<Void, Never>?
    private var localSpeechPreparation: Task<Void, Never>?
    #if os(iOS)
    private static let continuedVoiceBriefTaskPrefix =
        "fyi.readbriefly.BrieflyNative.voice-brief"
    @ObservationIgnored
    private var continuedVoiceBriefTask: AnyObject?
    @ObservationIgnored
    private var continuedVoiceBriefWork: Task<Void, Never>?
    #endif

    var isReady = false
    var projection = LibraryProjection.empty
    var trashEntries = [LibraryEntry]()
    var activeSection = LibrarySection.briefs
    var selectedID = ""
    var selectedIDs = Set<String>()
    var selectedVoiceBriefID = ""
    var selectedChannelSource = ""
    var newChannelSources = [String]()
    var channelBrowserAddress = ""
    var channelBrowserStagesSource = false
    var showingVoiceBriefSettings = false
    var showingChannelSettings = false
    var selectedVariant = LibraryVariant.concise
    var selectedText = ""
    var highlightsText = ""
    var showingHighlights = false
    var showingTrash = false
    var query = ""
    var selectedTopic = "All"
    var selectedChannelDomain = "All"
    var isLoadingText = false
    var isIngesting = false
    var isSyncing = false
    var syncCompleted = 0
    var syncTotal = 0
    var isProcessing = false
    var isCheckingChannel = false
    var isRunningVoiceBrief = false
    var voiceBriefGenerationProgress: VoiceBriefGenerationProgress?
    var isGeneratingSpeech = false
    var isPreparingSpeech = false
    var isLocalSpeechReady = false
    var speechPreparationStatus = "Preparing local voice…"
    var isCheckingAccount = false
    var isTestingAI = false
    var status = "Loading library…"
    var errorMessage: String?
    var libraryChannels = [LibraryChannel]()
    var topicsText = ""
    var account = BrieflyAccountStatus.signedOut
    var subscriptionProduct: Product?
    var isPurchasingSubscription = false
    var processingCommand =
        UserDefaults.standard.string(forKey: LibraryModel.processingCommandKey) ??
        LibraryModel.processingDefaultCommand
    var processingPrompt =
        UserDefaults.standard.string(forKey: LibraryModel.processingPromptKey) ??
        defaultProcessingPrompt
    var aboutYou =
        UserDefaults.standard.string(forKey: LibraryModel.aboutYouKey) ?? ""

    init(environment: AppEnvironment = .current()) {
        self.environment = environment
    }

    var runsScheduledWork: Bool { !environment.isUITesting }

    var canEdit: Bool {
        library != nil
    }

    private static var cloudKitAvailable: Bool {
        #if os(macOS)
        let signature = Bundle.main.bundleURL
            .appending(path: "Contents/_CodeSignature/CodeResources")
        #else
        let signature = Bundle.main.bundleURL
            .appending(path: "_CodeSignature/CodeResources")
        #endif
        return FileManager.default.fileExists(
            atPath: signature.path
        )
    }

    var usesManagedAI: Bool {
        processingCommand == Self.managedAICommand
    }

    var isWorking: Bool {
        isIngesting || isCheckingChannel || isProcessing || isRunningVoiceBrief ||
            isGeneratingSpeech || isPreparingSpeech || isSyncing || isTestingAI
    }

    var menuBarActivity: String? {
        if isRunningVoiceBrief { return "Creating brief" }
        if isGeneratingSpeech { return "Creating audio" }
        if isPreparingSpeech { return "Preparing voice" }
        if isProcessing { return "Processing" }
        if isIngesting || isCheckingChannel { return "Ingesting" }
        if isSyncing {
            return syncTotal > 0 ? "Syncing \(syncCompleted)/\(syncTotal)" : "Syncing"
        }
        if isTestingAI { return "Testing" }
        return nil
    }

    var menuBarIcon: String {
        if isRunningVoiceBrief || isGeneratingSpeech || isPreparingSpeech {
            return "waveform"
        }
        if isProcessing || isTestingAI { return "sparkles" }
        if isIngesting || isCheckingChannel { return "square.and.arrow.down" }
        if isSyncing { return "arrow.triangle.2.circlepath" }
        return "doc.text"
    }

    var activityStatus: String {
        isPreparingSpeech ? speechPreparationStatus : status
    }

    var activeActivities: [BrieflyActivity] {
        var activities = [BrieflyActivity]()
        if isRunningVoiceBrief {
            activities.append(.init(icon: "sparkles", title: "Creating brief", detail: status))
        }
        if isGeneratingSpeech {
            activities.append(.init(icon: "waveform", title: "Creating audio", detail: status))
        }
        if isPreparingSpeech {
            activities.append(.init(icon: "waveform", title: "Preparing voice", detail: speechPreparationStatus))
        }
        if isProcessing {
            activities.append(.init(icon: "sparkles", title: "Preparing summaries", detail: status))
        }
        if isIngesting || isCheckingChannel {
            activities.append(.init(icon: "square.and.arrow.down", title: "Gathering items", detail: status))
        }
        if isSyncing {
            let detail = syncTotal > 0
                ? "Uploading \(syncCompleted) of \(syncTotal) changes"
                : status
            activities.append(.init(icon: "icloud", title: "Syncing", detail: detail))
        }
        if isTestingAI {
            activities.append(.init(icon: "checkmark.bubble", title: "Testing AI", detail: status))
        }
        return activities
    }

    var selectedEntry: LibraryEntry? {
        (projection.entries + trashEntries).first { $0.id == selectedID }
    }

    var highlightCount: Int {
        highlightsText.components(separatedBy: .newlines)
            .count { $0.hasPrefix("## ") }
    }

    var loadedHighlightCount: Int? {
        hasLoadedHighlights ? highlightCount : nil
    }

    var loadedTrashCount: Int? {
        hasLoadedTrash ? trashEntries.count : nil
    }

    var selectedVoiceBrief: LibraryVoiceBrief? {
        projection.voiceBriefDefinitions.first { $0.id == selectedVoiceBriefID }
    }

    var selectedChannel: LibraryChannel? {
        channels.first { $0.source == selectedChannelSource }
    }

    var homeEntries: [LibraryEntry] {
        projection.entries.filter(\.isMainLibraryEntry)
    }

    var filteredEntries: [LibraryEntry] {
        (showingTrash ? trashEntries : homeEntries).filter {
            (selectedTopic.isEmpty || selectedTopic == "All" ||
                    $0.topicNames.contains(selectedTopic)) &&
                $0.matches(query)
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
        if environment.isUITesting {
            do {
                await openLibrary(databaseURL: try environment.prepareUITestLibrary())
                await loadSelectedText()
                status = "Ready for application tour"
            } catch {
                isReady = true
                errorMessage = error.localizedDescription
            }
            return
        }
        localSpeechPreparation = Task { await prepareLocalSpeech() }
        let usesDemo = ProcessInfo.processInfo.arguments.contains("--demo")
        if usesDemo {
            projection = .demo
            status = "Showing the sample library"
            selectInitialContent()
            isReady = true
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

        async let selectedText: Void = loadSelectedText()
        async let accountRefresh: Void = refreshAccount()
        if library != nil {
            async let cloudSync: Void = sync()
            _ = await (selectedText, accountRefresh, cloudSync)
            await drainProcessingQueue()
            await resumePendingVoiceBriefs()
            await runDueChannelChecks()
            await runDueVoiceBriefs()
        } else {
            _ = await (selectedText, accountRefresh)
        }
    }

    private func prepareLocalSpeech() async {
        guard !isPreparingSpeech, !isLocalSpeechReady else { return }
        isPreparingSpeech = true
        speechPreparationStatus = "Preparing local voice…"
        defer {
            isPreparingSpeech = false
            localSpeechPreparation = nil
        }
        do {
            try await LocalVoiceBriefSynthesizer.shared.prepare { [weak self] stage in
                Task { @MainActor in
                    guard let self else { return }
                    switch stage {
                    case .downloading(let fraction):
                        let percent = Int((min(max(fraction, 0), 1) * 100).rounded())
                        self.speechPreparationStatus =
                            "Downloading local voice… \(percent)%"
                    case .loading:
                        self.speechPreparationStatus = "Loading local voice…"
                    case .ready:
                        self.speechPreparationStatus = "Local voice ready"
                    }
                }
            }
            isLocalSpeechReady = true
            speechPreparationStatus = "Local voice ready"
        } catch {
            isLocalSpeechReady = false
            speechPreparationStatus = "System voice will be used"
        }
    }

    func openLibrary(databaseURL: URL) async {
        do {
            let next = SQLiteLibraryStore(databaseURL: databaseURL)
            projection = try await next.loadLibraryIndex()
            topicsText = try await next.topicDefinitions()
                .map { "\($0.id): \($0.title)" }
                .joined(separator: "\n")
            library = next
            status = "Opened local SQLite library"
            selectInitialContent()
            isReady = true
            let database = try await next.documentDatabase()
            cloud = !environment.isUITesting && Self.cloudKitAvailable
                ? CloudDocumentSync(
                    store: database,
                    containerIdentifier: "iCloud.fyi.readbriefly"
                )
                : nil
        } catch {
            library = nil
            libraryChannels = []
            trashEntries = []
            isReady = true
            errorMessage = error.localizedDescription
        }
    }

    func refreshLibrary(selecting entryID: String? = nil) async {
        guard let library else { return }
        do {
            projection = try await library.loadLibraryIndex()
            if hasLoadedTrash { try await refreshTrash(from: library) }
            if hasLoadedChannels { try await refreshChannels(from: library) }
            if hasLoadedHighlights { try await refreshHighlights(from: library) }
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
            status = url == nil ? "Capturing text…" : "Extracting the item…"
            let router = NativeItemInputRouter()
            var request = ItemInputRequest(source: url.map(ItemInputSource.url) ?? .text(trimmed))
            request.retainAudio = UserDefaults.standard.bool(forKey: "BrieflySaveCapturedAudio") &&
                router.inputID(for: request) == .youtube
            let draft = try await router.ingest(
                request,
                context: itemInputContext()
            )
            let id = try await library.captureItem(draft)
            await refreshLibrary(selecting: id)
            activeSection = .items
            if environment.isUITesting {
                status = "Captured"
                return
            }
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
            let id = try await library.captureItem(ItemDraft(
                inputID: .webPage,
                title: page.title,
                content: page.text,
                sourceURL: url,
                canonicalURL: url,
                faviconData: page.faviconData,
                faviconFileExtension: page.faviconFileExtension
            ))
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
        do {
            let draft = try await NativeItemInputRouter().ingest(
                ItemInputRequest(source: .file(url)),
                context: itemInputContext()
            )
            let entryID = try await library.captureItem(draft)
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
            projection = try await library.loadLibraryIndex()
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
            try await refreshHighlights(from: library)
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
            try await refreshHighlights(from: library)
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
        showingTrash = false
        showingHighlights = true
        Task { await loadHighlights() }
    }

    func showInbox() {
        activeSection = .items
        selectedTopic = "All"
        showingHighlights = false
        showingTrash = false
        clearEntrySelection()
    }

    func showTrash() {
        activeSection = .items
        selectedTopic = "All"
        showingHighlights = false
        showingTrash = true
        clearEntrySelection()
        Task { await loadTrash() }
    }

    func showTopic(_ topic: String) async {
        selectedTopic = topic
        showingHighlights = false
        showingTrash = false
        clearEntrySelection()
    }

    func trashSelected() async {
        await trash(entryID: selectedID)
    }

    func trash(entryID: String) async {
        guard let library else { return }
        let ids = selectedEntryIDs(fallback: entryID)
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
            projection = try await library.loadLibraryIndex()
            try await refreshChannels(from: library)
            activeSection = .briefs
            selectedID = ""
            selectedIDs = []
            selectedVoiceBriefID = id
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
            projection = try await library.loadLibraryIndex()
            try await refreshChannels(from: library)
            selectedVoiceBriefID = ""
            showingVoiceBriefSettings = false
            selectedID = ""
            selectedIDs = []
            status = "Voice brief moved to Trash"
            requestSync()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func stageChannelSource(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let candidate = if trimmed.contains("://") { trimmed } else { "https://\(trimmed)" }
        guard let url = URL(string: candidate), ["http", "https"].contains(url.scheme) else {
            errorMessage = LibraryError.invalidChannel.localizedDescription
            return
        }
        let normalized = url.absoluteString
        guard !newChannelSources.contains(normalized) else { return }
        newChannelSources.append(normalized)
    }

    func removeStagedChannelSource(_ source: String) {
        newChannelSources.removeAll { $0 == source }
    }

    func addChannel(_ source: String) async {
        stageChannelSource(source)
        await createChannel()
    }

    func createChannel() async {
        guard let library else {
            errorMessage = "Open a Briefly library before adding channels."
            return
        }
        guard !newChannelSources.isEmpty else { return }
        do {
            let groupID = try await library.addChannel(newChannelSources)
            try await refreshChannels(from: library)
            guard let added = libraryChannels.first(where: { $0.source == groupID }) else {
                throw LibraryError.missingChannel
            }
            selectedChannelSource = added.source
            newChannelSources = []
            showingChannelSettings = false
            status = added.sources.count == 1
                ? "Channel added"
                : "Channel added with \(added.sources.count) sources"
            requestSync()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func updateSelectedChannel(
        title: String,
        sources: [String],
        retrievalCount: Int,
        autoSummarize: Bool,
        schedule: String
    ) async {
        guard let library, let channel = selectedChannel else { return }
        do {
            try await library.updateChannelGroup(
                channel.source,
                title: title,
                sources: sources,
                retrievalCount: retrievalCount,
                autoSummarize: autoSummarize,
                schedule: schedule
            )
            try await refreshChannels(from: library)
            status = "Channel settings saved"
            requestSync()
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
            var newEntryIDs = [String]()
            var lastError: Error?
            for source in channel.sources {
                do {
                    let result = try await retrieveChannel(
                        library,
                        source: source,
                        loadMore: loadMore
                    )
                    newEntryIDs.append(contentsOf: result.newEntryIDs)
                } catch {
                    lastError = error
                }
            }
            projection = try await library.loadLibraryIndex()
            try await refreshChannels(from: library)
            selectedChannelSource = channel.source
            if let lastError {
                errorMessage = lastError.localizedDescription
                status = newEntryIDs.isEmpty
                    ? "Channel check failed."
                    : "Gathered \(newEntryIDs.count) items; some sources failed and will retry."
            } else {
                status = newEntryIDs.isEmpty
                    ? "Channel checked. No new items."
                    : "Gathered \(newEntryIDs.count) new " +
                        (newEntryIDs.count == 1 ? "item" : "items")
            }
            if channel.autoSummarize {
                await enqueueProcessing(newEntryIDs)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func removeSelectedChannel() async {
        guard let library, let channel = selectedChannel else { return }
        do {
            let deletedItemCount = try await library.removeChannelGroup(channel.source)
            projection = try await library.loadLibraryIndex()
            try await refreshChannels(from: library)
            selectedChannelSource = ""
            showingChannelSettings = false
            selectedID = ""
            selectedIDs = []
            status = deletedItemCount == 1
                ? "Channel removed and 1 downloaded item deleted"
                : "Channel removed and \(deletedItemCount) downloaded items deleted"
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
            var channelErrors = [String]()
            for source in brief.sources {
                do {
                    let result = try await retrieveChannel(library, source: source)
                    newEntryIDs += result.newEntryIDs
                    if let error = result.channel.error { channelErrors.append(error) }
                } catch {
                    channelErrors.append(error.localizedDescription)
                }
            }
            projection = try await library.loadLibraryIndex()
            try await refreshChannels(from: library)
            status = newEntryIDs.isEmpty
                ? "Channels checked. No new items."
                : "Prepared \(newEntryIDs.count) new " +
                    (newEntryIDs.count == 1 ? "item" : "items")
            if let error = channelErrors.first { errorMessage = error }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func runSelectedVoiceBrief() async {
        guard let brief = selectedVoiceBrief else { return }
        do {
            try await library?.queueVoiceBriefRun(id: brief.id)
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        #if os(iOS)
        if #available(iOS 26.0, *), submitContinuedVoiceBrief(brief) {
            return
        }
        #endif
        await generateVoiceBrief(brief, selectEpisode: true, reportErrors: true)
    }

    func resumePendingVoiceBriefs() async {
        guard let library, !isRunningVoiceBrief, !isGeneratingSpeech else { return }
        guard let pending = try? await library.pendingVoiceBriefIDs() else { return }
        for id in pending {
            guard let brief = projection.voiceBriefDefinitions.first(where: { $0.id == id }) else {
                continue
            }
            await generateVoiceBrief(brief, selectEpisode: false, reportErrors: false)
        }
    }

    func runDueVoiceBriefs() async {
        guard let library, !isRunningVoiceBrief, !isGeneratingSpeech else { return }
        do {
            let due = try await library.dueVoiceBriefIDs()
            for id in due {
                guard let brief = projection.voiceBriefDefinitions.first(where: {
                    $0.id == id
                }) else {
                    continue
                }
                try await library.markVoiceBriefAttempt(id: id)
                try await library.queueVoiceBriefRun(id: id)
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

    func runDueChannelChecks() async {
        guard let library, !isCheckingChannel, !isRunningVoiceBrief else { return }
        guard let due = try? await library.dueChannelSources(), !due.isEmpty else { return }
        isCheckingChannel = true
        defer { isCheckingChannel = false }
        var newEntryIDs = [String]()
        for source in due {
            do {
                newEntryIDs += try await retrieveChannel(
                    library,
                    source: source
                ).newEntryIDs
            } catch {
                continue
            }
        }
        projection = (try? await library.loadLibraryIndex()) ?? projection
        try? await refreshChannels(from: library)
        let autoSummarizeIDs = Set(libraryChannels.filter(\.autoSummarize).flatMap(\.entryIDs))
        await enqueueProcessing(newEntryIDs.filter(autoSummarizeIDs.contains))
        if !newEntryIDs.isEmpty { requestSync() }
    }

    @discardableResult
    private func generateVoiceBrief(
        _ brief: LibraryVoiceBrief,
        selectEpisode: Bool,
        reportErrors: Bool,
        runAlreadyClaimed: Bool = false
    ) async -> Bool {
        guard let library else { return false }
        if runAlreadyClaimed {
            guard isRunningVoiceBrief else { return false }
        } else {
            guard !isRunningVoiceBrief else { return false }
            isRunningVoiceBrief = true
        }
        voiceBriefGenerationProgress = VoiceBriefGenerationProgress(
            voiceBriefID: brief.id,
            totalChannelCount: brief.sources.count
        )
        updateContinuedVoiceBriefProgress()
        defer {
            isRunningVoiceBrief = false
            voiceBriefGenerationProgress = nil
        }
        do {
            status = "Fetching channels for \(brief.title)…"
            var newEntryIDs = [String]()
            for source in brief.sources {
                do {
                    newEntryIDs += try await retrieveChannel(
                        library,
                        source: source
                    ).newEntryIDs
                } catch {
                    // A failed channel should not hide progress from the channels that succeeded.
                }
                if Task.isCancelled { throw CancellationError() }
                voiceBriefGenerationProgress?.checkedChannelCount += 1
                voiceBriefGenerationProgress?.retrievedItemCount = newEntryIDs.count
                updateContinuedVoiceBriefProgress()
            }
            projection = try await library.loadLibraryIndex()
            try await refreshChannels(from: library)
            voiceBriefGenerationProgress?.phase = .summarizing
            updateContinuedVoiceBriefProgress()
            await enqueueProcessing(
                newEntryIDs,
                trackingVoiceBriefEntries: Set(newEntryIDs)
            )
            try Task.checkCancellation()
            voiceBriefGenerationProgress?.phase = .assembling
            updateContinuedVoiceBriefProgress()
            status = "Assembling short and detailed versions of \(brief.title)…"
            let episode = try await library.runVoiceBrief(id: brief.id)
            projection = try await library.loadLibraryIndex()
            try await refreshChannels(from: library)
            if selectEpisode {
                selectedVoiceBriefID = brief.id
                await select(episode.entryID)
            }
            status = "Brief ready"
            completeContinuedVoiceBriefProgress()
            requestSync()
            return true
        } catch is CancellationError {
            status = "Brief preparation will resume when you try again"
            return false
        } catch {
            if reportErrors {
                errorMessage = error.localizedDescription
            } else {
                status = "\(brief.title): \(error.localizedDescription)"
            }
            return false
        }
    }

    #if os(iOS)
    @available(iOS 26.0, *)
    private func submitContinuedVoiceBrief(_ brief: LibraryVoiceBrief) -> Bool {
        let identifier = Self.continuedVoiceBriefTaskPrefix + "." + UUID().uuidString
        let scheduler = BGTaskScheduler.shared
        let registered = scheduler.register(
            forTaskWithIdentifier: identifier,
            using: nil
        ) { [weak self] task in
            guard let task = task as? BGContinuedProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            Task { @MainActor [weak self] in
                self?.startContinuedVoiceBrief(task, brief: brief)
            }
        }
        guard registered else { return false }

        let request = BGContinuedProcessingTaskRequest(
            identifier: identifier,
            title: "Preparing \(brief.title)",
            subtitle: "Waiting to gather channel items"
        )
        request.strategy = .queue
        do {
            isRunningVoiceBrief = true
            voiceBriefGenerationProgress = VoiceBriefGenerationProgress(
                voiceBriefID: brief.id,
                totalChannelCount: brief.sources.count
            )
            status = "Waiting to prepare \(brief.title)…"
            try scheduler.submit(request)
            return true
        } catch {
            isRunningVoiceBrief = false
            voiceBriefGenerationProgress = nil
            return false
        }
    }

    @available(iOS 26.0, *)
    private func startContinuedVoiceBrief(
        _ task: BGContinuedProcessingTask,
        brief: LibraryVoiceBrief
    ) {
        continuedVoiceBriefTask = task
        task.progress.totalUnitCount = 1_000
        task.progress.completedUnitCount = 0
        updateContinuedVoiceBriefProgress()
        task.expirationHandler = { [weak self] in
            Task { @MainActor [weak self] in
                try? await self?.library?.cancelVoiceBriefRun(id: brief.id)
                self?.continuedVoiceBriefWork?.cancel()
            }
        }

        continuedVoiceBriefWork = Task { @MainActor [weak self] in
            guard let self else {
                task.setTaskCompleted(success: false)
                return
            }
            let succeeded = await generateVoiceBrief(
                brief,
                selectEpisode: true,
                reportErrors: true,
                runAlreadyClaimed: true
            )
            task.setTaskCompleted(success: succeeded)
            continuedVoiceBriefTask = nil
            continuedVoiceBriefWork = nil
        }
    }
    #endif

    private func updateContinuedVoiceBriefProgress() {
        #if os(iOS)
        guard #available(iOS 26.0, *),
              let task = continuedVoiceBriefTask as? BGContinuedProcessingTask,
              let progress = voiceBriefGenerationProgress
        else { return }

        let completed: Int64
        let subtitle: String
        switch progress.phase {
        case .retrieving:
            let total = max(1, progress.totalChannelCount)
            completed = Int64(200 * progress.checkedChannelCount / total)
            subtitle = "Checked \(progress.checkedChannelCount) of " +
                "\(progress.totalChannelCount) channels · " +
                "\(progress.retrievedItemCount) new items"
        case .summarizing:
            let processed = progress.summarizedItemCount + progress.failedItemCount
            let total = max(1, progress.retrievedItemCount)
            completed = 200 + Int64(600 * processed / total)
            subtitle = progress.retrievedItemCount == 0
                ? "No new items to summarize"
                : "Summarized \(processed) of \(progress.retrievedItemCount) items"
        case .assembling:
            completed = 850
            subtitle = "Writing short and detailed versions"
        }
        task.progress.completedUnitCount = completed
        task.updateTitle("Preparing your brief", subtitle: subtitle)
        #endif
    }

    private func completeContinuedVoiceBriefProgress() {
        #if os(iOS)
        guard #available(iOS 26.0, *),
              let task = continuedVoiceBriefTask as? BGContinuedProcessingTask
        else { return }
        task.progress.completedUnitCount = task.progress.totalUnitCount
        task.updateTitle("Brief ready", subtitle: "Short and detailed versions are ready")
        #endif
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
        guard context.count <= 10_000 else {
            errorMessage = "Personal context must be 10,000 characters or fewer."
            return
        }
        aboutYou = context
        UserDefaults.standard.set(context, forKey: Self.aboutYouKey)
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
            projection = try await library.loadLibraryIndex()
            status = "Topics saved"
            requestSync()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func renameTopic(_ currentTitle: String, to newTitle: String) async {
        guard let library else { return }
        do {
            let definitions = try await library.topicDefinitions()
            guard let topic = definitions.first(where: { $0.title == currentTitle }) else {
                throw BrieflyBackendError.message("That collection no longer exists.")
            }
            let renamed = definitions.map {
                $0.id == topic.id
                    ? LibraryTopicDefinition(id: $0.id, title: newTitle)
                    : $0
            }
            let saved = try await library.replaceTopicDefinitions(renamed)
            let savedTitle = saved.first(where: { $0.id == topic.id })?.title ?? newTitle
            await refreshLibrary()
            if selectedTopic == currentTitle { selectedTopic = savedTitle }
            status = "Collection renamed"
            requestSync()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func deleteTopic(_ title: String) async {
        guard let library else { return }
        do {
            let definitions = try await library.topicDefinitions()
            guard let topic = definitions.first(where: { $0.title == title }) else {
                throw BrieflyBackendError.message("That collection no longer exists.")
            }
            try await library.deleteTopicDefinition(id: topic.id)
            if selectedTopic == title { showInbox() }
            await refreshLibrary()
            status = "Collection deleted. Its notes are still in your library."
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

    func signInWithApple(
        _ result: Result<ASAuthorization, Error>,
        nonce: String
    ) async {
        do {
            guard
                case .success(let authorization) = result,
                let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                let identityToken = credential.identityToken,
                !nonce.isEmpty
            else {
                if case .failure(let error) = result { throw error }
                throw BrieflyBackendError.message("Apple sign-in did not return a credential.")
            }
            account = try await backend.signInWithApple(
                identityToken: identityToken,
                nonce: nonce
            )
            status = "Signed in with Apple"
            await syncStoreEntitlements()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func loadSubscription() async {
        do {
            subscriptionProduct = try await Product.products(
                for: [Self.subscriptionProductID]
            ).first
            await syncStoreEntitlements()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func purchaseSubscription() async {
        guard
            let product = subscriptionProduct,
            let accountID = account.accountID,
            !isPurchasingSubscription
        else { return }
        isPurchasingSubscription = true
        defer { isPurchasingSubscription = false }
        do {
            switch try await product.purchase(options: [.appAccountToken(accountID)]) {
            case .success(.verified(let transaction)):
                account = try await backend.syncAppStoreTransaction(String(transaction.id))
                await transaction.finish()
                status = "Briefly membership activated"
            case .success(.unverified):
                throw BrieflyBackendError.message("The App Store purchase could not be verified.")
            case .pending:
                status = "The App Store purchase is awaiting approval"
            case .userCancelled:
                break
            @unknown default:
                break
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func restoreSubscription() async {
        guard account.authenticated, !isPurchasingSubscription else { return }
        isPurchasingSubscription = true
        defer { isPurchasingSubscription = false }
        do {
            try await AppStore.sync()
            await syncStoreEntitlements()
            status = account.entitled == true
                ? "Briefly membership restored"
                : "No active Briefly membership was found"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func syncStoreEntitlements() async {
        guard account.authenticated else { return }
        do {
            for await result in Transaction.currentEntitlements {
                guard
                    case .verified(let transaction) = result,
                    transaction.productID == Self.subscriptionProductID
                else { continue }
                account = try await backend.syncAppStoreTransaction(String(transaction.id))
                await transaction.finish()
            }
            if account.entitled != true { await refreshAccount() }
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
        guard let library else {
            throw BrieflyBackendError.message("Open the local library before publishing.")
        }
        let document = try await library.getDocument(entry.id)
        let filename = "\(captureID).md"
        var texts = [BrieflyShareSource.Text]()
        for variant in LibraryVariant.allCases where variant != .source {
            let markdown = (document.texts[variant] ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !markdown.isEmpty {
                texts.append(.init(variant: variant.rawValue, markdown: markdown))
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
        let result = try await backend.publishShare(
            captureID: captureID,
            source: source
        )
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

    func audioPlaybackID(
        for entry: LibraryEntry,
        variant: LibraryVariant,
        text: String
    ) -> String {
        let key = "\(entry.id)\n\(variant.rawValue)\n\(text)"
        let digest = SHA256.hash(data: Data(key.utf8))
            .prefix(8)
            .map { String(format: "%02x", $0) }
            .joined()
        return "\(entry.id):\(variant.rawValue):\(digest)"
    }

    func streamPlayableAudio(
        for entry: LibraryEntry,
        variant: LibraryVariant,
        text rawText: String,
        segmentReady: (URL) throws -> Void
    ) async -> Bool {
        if variant == .source, let original = await audioURL(for: entry.id) {
            do {
                try segmentReady(original)
                return true
            } catch {
                errorMessage = error.localizedDescription
                return false
            }
        }

        let segments = narrationSegments(from: rawText)
        guard !segments.isEmpty else {
            errorMessage = NativeLibraryError.emptySpeech.localizedDescription
            return false
        }
        guard !isGeneratingSpeech, !isRunningVoiceBrief else { return false }

        isGeneratingSpeech = true
        defer { isGeneratingSpeech = false }
        let description = variant == .source
            ? "document"
            : "\(variant.title.lowercased()) summary"
        var useSystemVoice = !isLocalSpeechReady

        do {
            for (index, text) in segments.enumerated() {
                status = "Preparing \(description) audio \(index + 1)/\(segments.count)…"
                let localURL = try speechCacheURL(
                    entryID: entry.id,
                    variant: variant,
                    text: text,
                    engine: "kokoro-ane-v1"
                )
                if usableCachedAudio(at: localURL) {
                    try segmentReady(localURL)
                    continue
                }

                if !useSystemVoice {
                    do {
                        try await LocalVoiceBriefSynthesizer.shared.synthesize(
                            text,
                            to: localURL
                        )
                        try segmentReady(localURL)
                        continue
                    } catch {
                        useSystemVoice = true
                    }
                }

                let systemURL = try speechCacheURL(
                    entryID: entry.id,
                    variant: variant,
                    text: text,
                    engine: "system-v1"
                )
                if !usableCachedAudio(at: systemURL) {
                    try? FileManager.default.removeItem(at: systemURL)
                    status = "Local voice unavailable; using system voice…"
                    try await synthesizeSystemVoiceBriefAudio(text, to: systemURL)
                }
                try segmentReady(systemURL)
            }
            status = useSystemVoice
                ? "Audio ready (system voice)"
                : "Audio ready (on-device voice)"
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    private func narrationSegments(from markdown: String) -> [String] {
        var paragraphs = [String]()
        var lines = [String]()

        func finishParagraph() {
            guard !lines.isEmpty else { return }
            let paragraph = spokenVoiceBriefText(lines.joined(separator: "\n"))
            if !paragraph.isEmpty { paragraphs.append(paragraph) }
            lines.removeAll(keepingCapacity: true)
        }

        for line in markdown.components(separatedBy: .newlines) {
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                finishParagraph()
            } else {
                lines.append(line)
            }
        }
        finishParagraph()

        return paragraphs.flatMap {
            LocalVoiceBriefSynthesizer.segments(for: $0)
        }
    }

    private func speechCacheURL(
        entryID: String,
        variant: LibraryVariant,
        text: String,
        engine: String
    ) throws -> URL {
        guard let caches = FileManager.default.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        ).first else {
            throw NativeLibraryError.audioGenerationFailed
        }
        let directory = caches
            .appending(path: "Briefly", directoryHint: .isDirectory)
            .appending(path: "Speech", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let key = "\(engine)\n\(entryID)\n\(variant.rawValue)\n\(text)"
        let digest = SHA256.hash(data: Data(key.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return directory.appending(path: "\(digest).wav")
    }

    private func usableCachedAudio(at url: URL) -> Bool {
        let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize
        return (size ?? 0) > 44
    }

    func show(_ section: LibrarySection) async {
        activeSection = section
        showingHighlights = false
        showingTrash = false
        query = ""
        clearEntrySelection()
        switch section {
        case .items:
            #if os(iOS)
            selectedTopic = ""
            #else
            selectedTopic = "All"
            #endif
        case .channels:
            selectedChannelDomain = "All"
            selectedChannelSource = ""
            showingChannelSettings = false
            await loadChannels()
        case .briefs:
            selectedVoiceBriefID = ""
            showingVoiceBriefSettings = false
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
        showingTrash = false
        showingVoiceBriefSettings = false
        clearEntrySelection()
        selectedVoiceBriefID = id
    }

    func selectChannel(_ source: String) {
        showingHighlights = false
        showingTrash = false
        showingChannelSettings = false
        clearEntrySelection()
        selectedChannelSource = source
    }

    func showVoiceBriefSettings(_ id: String) {
        selectVoiceBrief(id)
        showingVoiceBriefSettings = true
        Task { await loadChannels() }
    }

    func showChannelSettings(_ source: String) {
        selectChannel(source)
        showingChannelSettings = true
        Task { await loadChannels() }
    }

    func showChannelDomain(_ domain: String) {
        selectedChannelDomain = domain
        selectedChannelSource = ""
        showingChannelSettings = false
        clearEntrySelection()
    }

    func navigateBack() {
        if !selectedID.isEmpty {
            clearEntrySelection()
        } else if activeSection == .channels {
            selectedChannelSource = ""
            showingChannelSettings = false
        } else if activeSection == .briefs {
            if showingVoiceBriefSettings {
                showingVoiceBriefSettings = false
                if selectedVoiceBriefID == "new" {
                    selectedVoiceBriefID = ""
                }
            } else {
                selectedVoiceBriefID = ""
            }
        }
    }

    private func clearEntrySelection() {
        selectedID = ""
        selectedIDs = []
        selectedText = ""
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
            status = "Checking iCloud for changes…"
            try await cloud.synchronize(
                onProgress: { [weak self] completed, total in
                    guard let self else { return }
                    syncCompleted = completed
                    syncTotal = total
                    status = total > 0
                        ? "Uploading \(completed) of \(total) changes…"
                        : "Finishing iCloud sync…"
                },
                onFetchedChanges: { [weak self] in
                    guard let self else { return }
                    try await refreshLibraryAfterCloudFetch(from: library)
                }
            )
            try await refreshLibraryAfterCloudFetch(from: library)
            status = "Sync complete"
        } catch {
            errorMessage = error.localizedDescription
            status = "Using the last complete offline library"
        }
    }

    private func refreshLibraryAfterCloudFetch(from library: SQLiteLibraryStore) async throws {
        projection = try await library.loadLibraryIndex()
        if hasLoadedTrash { try await refreshTrash(from: library) }
        if hasLoadedChannels { try await refreshChannels(from: library) }
        if hasLoadedHighlights { try await refreshHighlights(from: library) }
        topicsText = try await library.topicDefinitions()
            .map { "\($0.id): \($0.title)" }
            .joined(separator: "\n")
        await restoreSelection()
    }

    func clearError() {
        errorMessage = nil
    }

    private func enqueueProcessing(
        _ entryID: String,
        selectWhenFinished: Bool = true
    ) async {
        await enqueueProcessing([entryID], selectWhenFinished: selectWhenFinished)
    }

    private func enqueueProcessing(
        _ entryIDs: [String],
        selectWhenFinished: Bool = false,
        trackingVoiceBriefEntries: Set<String> = []
    ) async {
        guard let library else { return }
        do {
            for entryID in entryIDs {
                try await library.enqueueProcessingJob(
                    entryID: entryID,
                    selectWhenFinished: selectWhenFinished
                )
            }
            await drainProcessingQueue(trackingVoiceBriefEntries: trackingVoiceBriefEntries)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func drainProcessingQueue(
        trackingVoiceBriefEntries: Set<String> = []
    ) async {
        guard let library, !isProcessing else { return }
        isProcessing = true
        status = "Preparing summaries…"
        var selectedProcessedID: String?
        await withTaskGroup(of: ProcessingJobResult.self) { group in
            var activeTasks = 0

            for _ in 0..<3 {
                guard let job = try? await library.claimNextProcessingJob() else { break }
                activeTasks += 1
                group.addTask { await self.process(job) }
            }

            while activeTasks > 0 {
                if Task.isCancelled { group.cancelAll() }
                if let result = await group.next() {
                    if let processedID = result.selectedID {
                        selectedProcessedID = processedID
                    }
                    if trackingVoiceBriefEntries.contains(result.entryID) {
                        if result.succeeded {
                            voiceBriefGenerationProgress?.summarizedItemCount += 1
                        } else {
                            voiceBriefGenerationProgress?.failedItemCount += 1
                        }
                        updateContinuedVoiceBriefProgress()
                    }
                }
                activeTasks -= 1
                if !Task.isCancelled,
                   let job = try? await library.claimNextProcessingJob() {
                    activeTasks += 1
                    group.addTask { await self.process(job) }
                }
            }
        }
        isProcessing = false
        await refreshLibrary(selecting: selectedProcessedID)
        status = "Summaries ready"
        requestSync()
    }

    private func requestSync() {
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
                candidate: candidate
            )
        }
        let channel = libraryChannels.first { $0.source == source }
        let maximum = loadMore
            ? min(100, (channel?.items.count ?? 0) + (channel?.retrievalCount ?? 5))
            : nil
        return try await library.checkChannelInput(
            source,
            maximumItems: maximum,
            discover: { limit in
                try await NativeChannelInputRouter().enumerate(
                    source: source,
                    maximumItems: limit,
                    context: self.channelInputContext()
                )
            },
            ingest: ingest
        )
    }

    private func ingestURL(
        _ url: URL,
        in library: SQLiteLibraryStore,
        candidate: LibraryChannelCandidate? = nil
    ) async throws -> String {
        let hints = ItemInputHints(
            preferredInput: candidate?.preferredInput,
            title: candidate?.title,
            content: candidate?.content,
            mediaURL: candidate?.mediaURL.flatMap(URL.init(string:)),
            transcriptURL: candidate?.transcriptURL.flatMap(URL.init(string:)),
            transcriptType: candidate?.transcriptType,
            transcriptLanguage: candidate?.transcriptLanguage
        )
        let draft = try await NativeItemInputRouter().ingest(
            ItemInputRequest(source: .url(url), hints: hints),
            context: itemInputContext()
        )
        return try await library.captureItem(draft, asVoiceBriefSource: true)
    }

    private func itemInputContext() -> ItemInputContext {
        .init(
            render: { url in
                let page = try await ChannelBrowserSession.shared.extractPage(from: url)
                return RenderedInputPage(
                    title: page.title,
                    content: page.text,
                    sourceURL: url,
                    faviconData: page.faviconData,
                    faviconFileExtension: page.faviconFileExtension
                )
            },
            firecrawl: { try await BrieflyBackend.shared.firecrawl($0) },
            transcribe: { try await BrieflyBackend.shared.transcribe($0) },
            downloadAudio: { try await BrieflyBackend.shared.downloadAudio($0) }
        )
    }

    private func channelInputContext() -> ChannelInputContext {
        .init(render: { url, limit in
            let page = try await ChannelBrowserSession.shared.extractPage(from: url)
            let host = url.host?.lowercased() ?? ""
            let isX = host == "x.com" || host.hasSuffix(".x.com") || host.contains("twitter.com")
            if !page.items.isEmpty {
                return ChannelInputBatch(
                    inputID: isX ? .x : .page,
                    title: page.title,
                    kind: .page,
                    items: page.items.prefix(limit).compactMap { item in
                        guard let itemURL = URL(string: item.url) else { return nil }
                        return ChannelItemReference(
                            id: item.id,
                            title: item.title,
                            url: itemURL,
                            publishedAt: item.publishedAt,
                            hints: .init(
                                preferredInput: isX ? .x : .webPage,
                                title: item.title,
                                content: item.content
                            )
                        )
                    }
                )
            }
            let digest = SHA256.hash(data: Data(page.text.utf8))
                .map { String(format: "%02x", $0) }.joined()
            return ChannelInputBatch(
                inputID: isX ? .x : .page,
                title: page.title,
                kind: .page,
                items: [.init(
                    id: digest,
                    title: page.title,
                    url: url,
                    hints: .init(
                        preferredInput: .webPage,
                        title: page.title,
                        content: page.text
                    )
                )]
            )
        })
    }

    private func process(_ job: SQLiteProcessingJob) async -> ProcessingJobResult {
        guard let library else {
            return ProcessingJobResult(
                entryID: job.documentID,
                selectedID: nil,
                succeeded: false
            )
        }
        let entryID = job.documentID
        do {
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
            try await library.completeProcessingJob(entryID: entryID)
            return ProcessingJobResult(
                entryID: entryID,
                selectedID: job.selectWhenFinished ? processedID : nil,
                succeeded: true
            )
        } catch is CancellationError {
            try? await library.enqueueProcessingJob(
                entryID: entryID,
                selectWhenFinished: job.selectWhenFinished
            )
            return ProcessingJobResult(
                entryID: entryID,
                selectedID: nil,
                succeeded: false
            )
        } catch {
            try? await library.failProcessingJob(
                entryID: entryID,
                error: error.localizedDescription
            )
            errorMessage = error.localizedDescription
            status = "The capture is saved without summaries"
            return ProcessingJobResult(
                entryID: entryID,
                selectedID: nil,
                succeeded: false
            )
        }
    }

    private func selectInitialContent() {
        showingHighlights = false
        showingTrash = false
        #if os(macOS)
        activeSection = .items
        selectedTopic = "All"
        selectedChannelDomain = "All"
        selectedChannelSource = ""
        selectedVoiceBriefID = ""
        showingChannelSettings = false
        showingVoiceBriefSettings = false
        clearEntrySelection()
        #else
        if projection.voiceBriefDefinitions.contains(where: {
            !projection.episodes(for: $0.id).isEmpty
        }) {
            activeSection = .briefs
            selectedVoiceBriefID = ""
            selectedID = ""
            selectedIDs = []
            selectedText = ""
        } else {
            activeSection = .items
            selectedID = projection.entries.first(where: \.isMainLibraryEntry)?.id ?? ""
            selectedIDs = selectedID.isEmpty ? [] : [selectedID]
            selectedVariant = selectedEntry?.preferredVariant ?? .concise
            selectedText = ""
        }
        #endif
    }

    private func restoreSelection(preferredEntryID: String? = nil) async {
        if showingHighlights {
            clearEntrySelection()
            return
        }
        let entryID = preferredEntryID ?? selectedID
        if (projection.entries + trashEntries).contains(where: { $0.id == entryID }) {
            await select(entryID)
            return
        }

        clearEntrySelection()
        #if os(macOS)
        if selectedChannelSource != "new" &&
            !channels.contains(where: { $0.source == selectedChannelSource })
        {
            selectedChannelSource = ""
            showingChannelSettings = false
        }
        if selectedVoiceBriefID != "new" &&
            !projection.voiceBriefDefinitions.contains(where: {
                $0.id == selectedVoiceBriefID
            })
        {
            selectedVoiceBriefID = ""
            showingVoiceBriefSettings = false
        }
        #else
        switch activeSection {
        case .items:
            break
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
        #endif
    }

    private func refreshTrash(from store: SQLiteLibraryStore) async throws {
        trashEntries = try await store.loadTrashIndex().filter(\.isMainLibraryEntry)
        hasLoadedTrash = true
    }

    private func loadTrash() async {
        guard let library, !hasLoadedTrash else { return }
        do {
            try await refreshTrash(from: library)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func refreshChannels(from store: SQLiteLibraryStore) async throws {
        libraryChannels = try await store.loadChannels()
        hasLoadedChannels = true
    }

    private func loadChannels() async {
        guard let library, !hasLoadedChannels else { return }
        do {
            try await refreshChannels(from: library)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func refreshHighlights(from store: SQLiteLibraryStore) async throws {
        highlightsText = try await store.loadHighlights()
        hasLoadedHighlights = true
    }

    private func loadSelectedText() async {
        guard
            let entry = selectedEntry,
            let reference = entry.text(for: selectedVariant)
        else {
            selectedText = ""
            return
        }
        guard let library else {
            selectedText = reference.text ?? ""
            return
        }
        let entryID = entry.id
        let variant = selectedVariant
        isLoadingText = true
        defer { isLoadingText = false }
        do {
            let document = try await library.getDocument(
                entryID,
                includeDeleted: showingTrash
            )
            guard selectedID == entryID, selectedVariant == variant else { return }
            selectedText = document.texts[variant] ?? ""
            await loadHighlights()
        } catch {
            errorMessage = error.localizedDescription
            selectedText = ""
        }
    }

    private func loadHighlights() async {
        guard let library, !hasLoadedHighlights else { return }
        do {
            try await refreshHighlights(from: library)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
