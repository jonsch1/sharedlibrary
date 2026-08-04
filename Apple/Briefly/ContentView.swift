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

@MainActor
@Observable
final class LibraryModel {
    private static let subscriptionProductID = "fyi.readbriefly.plus.monthly"
    private static let managedAICommand =
        "briefly://openrouter/deepseek/deepseek-v4-flash"
    private static let processingDefaultCommand = managedAICommand
    private static let processingCommandKey = "BrieflyProcessingCommand"
    private static let processingPromptKey = "BrieflyProcessingPrompt"
    private static let voiceBriefPromptKey = "BrieflyVoiceBriefPrompt"
    private static let aboutYouKey = "BrieflyAboutYou"
    private let backend = BrieflyBackend.shared
    private var cloud: CloudDocumentSync?
    private var started = false
    private var library: SQLiteLibraryStore?
    private var hasLoadedChannels = false
    private var hasLoadedHighlights = false
    private var hasLoadedTrash = false
    private var pendingProcessingIDs = [String]()
    private var processingShouldSelect = [String: Bool]()
    private var pendingSync: Task<Void, Never>?
    private var localSpeechPreparation: Task<Void, Never>?

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
    var voiceBriefPrompt =
        UserDefaults.standard.string(forKey: LibraryModel.voiceBriefPromptKey) ??
        defaultVoiceBriefPrompt
    var aboutYou =
        UserDefaults.standard.string(forKey: LibraryModel.aboutYouKey) ?? ""

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
            cloud = Self.cloudKitAvailable
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
        schedule: String
    ) async {
        guard let library, let channel = selectedChannel else { return }
        do {
            try await library.updateChannelGroup(
                channel.source,
                title: title,
                sources: sources,
                retrievalCount: retrievalCount,
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
            for entryID in newEntryIDs {
                await enqueueProcessing(entryID, selectWhenFinished: false)
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
            for entryID in newEntryIDs {
                await enqueueProcessing(entryID, selectWhenFinished: false)
            }
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
        await generateVoiceBrief(brief, selectEpisode: true, reportErrors: true)
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
        for entryID in newEntryIDs {
            await enqueueProcessing(entryID, selectWhenFinished: false)
        }
        if !newEntryIDs.isEmpty { requestSync() }
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
                do {
                    newEntryIDs += try await retrieveChannel(
                        library,
                        source: source
                    ).newEntryIDs
                } catch {
                    continue
                }
            }
            projection = try await library.loadLibraryIndex()
            try await refreshChannels(from: library)
            for entryID in newEntryIDs {
                await enqueueProcessing(entryID, selectWhenFinished: false)
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
            let speechText = spokenVoiceBriefText(episode.script)
            var usedLocalVoice = false
            if isLocalSpeechReady {
                status = "Preparing on-device voice…"
                do {
                    try await LocalVoiceBriefSynthesizer.shared.synthesize(
                        speechText,
                        to: audioURL
                    )
                    usedLocalVoice = true
                } catch {
                    status = "Local voice unavailable; using system voice…"
                    try await synthesizeSystemVoiceBriefAudio(speechText, to: audioURL)
                }
            } else {
                status = "Local voice unavailable; using system voice…"
                try await synthesizeSystemVoiceBriefAudio(speechText, to: audioURL)
            }
            try await library.attachAudio(entryID: episode.entryID, file: audioURL)
            projection = try await library.loadLibraryIndex()
            try await refreshChannels(from: library)
            if selectEpisode {
                selectedVoiceBriefID = brief.id
                await select(episode.entryID)
            }
            status = usedLocalVoice
                ? "Voice brief ready (on-device voice)"
                : "Voice brief ready (system voice)"
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
        let filename = captureID
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
        if entry.voiceBriefID != nil {
            guard let url = await audioURL(for: entry.id) else {
                errorMessage = "This voice brief audio is not available locally."
                return false
            }
            do {
                try segmentReady(url)
                return true
            } catch {
                errorMessage = error.localizedDescription
                return false
            }
        }
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
            status = "Everything is up to date"
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
        processingShouldSelect[entryID] =
            (processingShouldSelect[entryID] ?? false) || selectWhenFinished
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
            let selectWhenFinished = processingShouldSelect.removeValue(forKey: entryID) ?? true
            await refreshLibrary(selecting: selectWhenFinished ? processedID : nil)
            status = "Summaries ready"
            requestSync()
        } catch {
            processingShouldSelect.removeValue(forKey: entryID)
            errorMessage = error.localizedDescription
            status = "The capture is saved without summaries"
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

@MainActor
private func synthesizeSystemVoiceBriefAudio(_ text: String, to url: URL) async throws {
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
                    file = nil
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
    private struct Segment {
        let url: URL
        let duration: Double
    }

    private var player: AVAudioPlayer?
    private var currentURL: URL?
    private var currentTitle: String?
    private var currentPlaybackID: String?
    private var positionKey: String?
    private var segments = [Segment]()
    private var segmentIndex = 0
    private var segmentStartTime = 0.0
    private var resumeTarget: Double?
    private var streamIsFinished = true
    private var shouldPlay = false
    private var timer: Timer?
    private var sleepTimer: Timer?
    #if os(iOS)
    private var remoteCommandTargets = [(MPRemoteCommand, Any)]()
    #endif
    private(set) var currentEntryID: String?
    var isPlaying = false
    var currentTime = 0.0
    var duration = 0.0
    var sleepTimerMinutes: Int?
    var rate = UserDefaults.standard.double(forKey: "BrieflyAudioRate").nonzero ?? 1
    var volume = UserDefaults.standard.object(forKey: "BrieflyAudioVolume") == nil
        ? 1
        : UserDefaults.standard.double(forKey: "BrieflyAudioVolume")

    override init() {
        super.init()
        #if os(iOS)
        configureRemoteCommands()
        #endif
    }

    deinit {
        #if os(iOS)
        for (command, target) in remoteCommandTargets {
            command.removeTarget(target)
        }
        #endif
    }

    @discardableResult
    func startStream(
        entryID: String,
        title: String,
        playbackID: String,
        positionID: String
    ) throws -> Bool {
        if currentPlaybackID == playbackID {
            shouldPlay = true
            resume()
            return false
        }
        stop()
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .spokenAudio)
        try session.setActive(true)
        #endif
        currentEntryID = entryID
        currentTitle = title
        currentPlaybackID = playbackID
        let key = "BrieflyAudioPosition.\(positionID)"
        positionKey = key
        let saved = UserDefaults.standard.double(forKey: key)
        resumeTarget = saved > 0 ? saved : nil
        streamIsFinished = false
        shouldPlay = true
        #if os(iOS)
        setRemoteCommandsEnabled(true)
        #endif
        return true
    }

    func appendSegment(_ url: URL, playbackID: String) throws {
        guard currentPlaybackID == playbackID else { return }
        let probe = try AVAudioPlayer(contentsOf: url)
        guard probe.duration > 0 else {
            throw NativeLibraryError.audioGenerationFailed
        }
        segments.append(Segment(url: url, duration: probe.duration))
        duration = segments.reduce(0) { $0 + $1.duration }
        if player == nil {
            try startNextSegmentIfAvailable()
        }
        #if os(iOS)
        updateNowPlayingInfo()
        #endif
    }

    func finishStream(playbackID: String) {
        guard currentPlaybackID == playbackID else { return }
        streamIsFinished = true
        if player == nil {
            do {
                try startNextSegmentIfAvailable()
            } catch {
                completePlayback(removeSavedPosition: false)
            }
        }
    }

    func seek(_ time: Double) {
        guard !segments.isEmpty else { return }
        let target = min(max(0, time), duration)
        player?.stop()
        player = nil
        currentURL = nil
        segmentIndex = 0
        segmentStartTime = 0
        resumeTarget = target
        do {
            try startNextSegmentIfAvailable()
        } catch {
            completePlayback(removeSavedPosition: false)
        }
        savePosition()
        #if os(iOS)
        updateNowPlayingInfo()
        #endif
    }

    func skip(by seconds: Double) {
        seek(currentTime + seconds)
    }

    func pause() {
        shouldPlay = false
        guard let player else {
            isPlaying = false
            return
        }
        player.pause()
        isPlaying = false
        savePosition()
        #if os(iOS)
        updateNowPlayingInfo()
        #endif
    }

    func resume() {
        shouldPlay = true
        guard let player else {
            try? startNextSegmentIfAvailable()
            return
        }
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif
        guard player.play() else {
            isPlaying = false
            return
        }
        isPlaying = true
        #if os(iOS)
        updateNowPlayingInfo()
        #endif
        startTimer()
    }

    func setRate(_ value: Double) {
        rate = value
        player?.rate = Float(value)
        UserDefaults.standard.set(value, forKey: "BrieflyAudioRate")
        #if os(iOS)
        updateNowPlayingInfo()
        #endif
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
        currentTitle = nil
        currentPlaybackID = nil
        positionKey = nil
        segments.removeAll()
        segmentIndex = 0
        segmentStartTime = 0
        resumeTarget = nil
        streamIsFinished = true
        shouldPlay = false
        isPlaying = false
        currentTime = 0
        duration = 0
        #if os(iOS)
        setRemoteCommandsEnabled(false)
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        try? AVAudioSession.sharedInstance().setActive(
            false,
            options: .notifyOthersOnDeactivation
        )
        #endif
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        guard self.player === player else { return }
        segmentStartTime += segments[segmentIndex].duration
        segmentIndex += 1
        self.player = nil
        currentURL = nil
        do {
            try startNextSegmentIfAvailable()
        } catch {
            completePlayback(removeSavedPosition: false)
        }
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) {
            [weak self] _ in
            guard let self, let player = self.player else { return }
            self.currentTime = self.segmentStartTime + player.currentTime
            self.isPlaying = player.isPlaying
        }
    }

    private func savePosition() {
        guard let positionKey else { return }
        let position = player.map { segmentStartTime + $0.currentTime } ?? currentTime
        UserDefaults.standard.set(position, forKey: positionKey)
    }

    private func startNextSegmentIfAvailable() throws {
        while segmentIndex < segments.count {
            let segment = segments[segmentIndex]
            if let resumeTarget,
               resumeTarget >= segmentStartTime + segment.duration
            {
                segmentStartTime += segment.duration
                segmentIndex += 1
                continue
            }

            let next = try AVAudioPlayer(contentsOf: segment.url)
            next.delegate = self
            next.enableRate = true
            next.rate = Float(rate)
            next.volume = Float(volume)
            next.prepareToPlay()
            if let resumeTarget {
                next.currentTime = min(
                    max(0, resumeTarget - segmentStartTime),
                    next.duration
                )
                self.resumeTarget = nil
            }
            if shouldPlay, !next.play() {
                throw NativeLibraryError.audioPlaybackFailed
            }
            player = next
            currentURL = segment.url
            currentTime = segmentStartTime + next.currentTime
            isPlaying = next.isPlaying
            startTimer()
            #if os(iOS)
            updateNowPlayingInfo()
            #endif
            return
        }

        player = nil
        currentURL = nil
        currentTime = min(segmentStartTime, duration)
        isPlaying = false
        if streamIsFinished {
            completePlayback(removeSavedPosition: true)
        }
    }

    private func completePlayback(removeSavedPosition: Bool) {
        timer?.invalidate()
        timer = nil
        setSleepTimer(minutes: nil)
        player?.stop()
        player = nil
        currentURL = nil
        currentPlaybackID = nil
        shouldPlay = false
        streamIsFinished = true
        isPlaying = false
        currentTime = 0
        if removeSavedPosition, let positionKey {
            UserDefaults.standard.removeObject(forKey: positionKey)
        }
        #if os(iOS)
        setRemoteCommandsEnabled(false)
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        try? AVAudioSession.sharedInstance().setActive(
            false,
            options: .notifyOthersOnDeactivation
        )
        #endif
    }

    #if os(iOS)
    private func configureRemoteCommands() {
        let commands = MPRemoteCommandCenter.shared()
        commands.skipBackwardCommand.preferredIntervals = [15]
        commands.skipForwardCommand.preferredIntervals = [30]
        commands.nextTrackCommand.isEnabled = false
        commands.previousTrackCommand.isEnabled = false
        commands.seekBackwardCommand.isEnabled = false
        commands.seekForwardCommand.isEnabled = false

        remoteCommandTargets = [
            (commands.playCommand, commands.playCommand.addTarget { [weak self] _ in
                DispatchQueue.main.async { self?.resume() }
                return .success
            }),
            (commands.pauseCommand, commands.pauseCommand.addTarget { [weak self] _ in
                DispatchQueue.main.async { self?.pause() }
                return .success
            }),
            (
                commands.togglePlayPauseCommand,
                commands.togglePlayPauseCommand.addTarget { [weak self] _ in
                    DispatchQueue.main.async {
                        guard let self else { return }
                        self.isPlaying ? self.pause() : self.resume()
                    }
                    return .success
                }
            ),
            (
                commands.skipBackwardCommand,
                commands.skipBackwardCommand.addTarget { [weak self] event in
                    guard let event = event as? MPSkipIntervalCommandEvent else {
                        return .commandFailed
                    }
                    DispatchQueue.main.async { self?.skip(by: -event.interval) }
                    return .success
                }
            ),
            (
                commands.skipForwardCommand,
                commands.skipForwardCommand.addTarget { [weak self] event in
                    guard let event = event as? MPSkipIntervalCommandEvent else {
                        return .commandFailed
                    }
                    DispatchQueue.main.async { self?.skip(by: event.interval) }
                    return .success
                }
            ),
            (
                commands.changePlaybackPositionCommand,
                commands.changePlaybackPositionCommand.addTarget { [weak self] event in
                    guard let event = event as? MPChangePlaybackPositionCommandEvent else {
                        return .commandFailed
                    }
                    DispatchQueue.main.async { self?.seek(event.positionTime) }
                    return .success
                }
            )
        ]
        setRemoteCommandsEnabled(false)
    }

    private func setRemoteCommandsEnabled(_ enabled: Bool) {
        let commands = MPRemoteCommandCenter.shared()
        commands.playCommand.isEnabled = enabled
        commands.pauseCommand.isEnabled = enabled
        commands.togglePlayPauseCommand.isEnabled = enabled
        commands.skipBackwardCommand.isEnabled = enabled
        commands.skipForwardCommand.isEnabled = enabled
        commands.changePlaybackPositionCommand.isEnabled = enabled
    }

    private func updateNowPlayingInfo() {
        guard let player, let currentEntryID else { return }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: currentTitle ?? "Briefly Audio",
            MPMediaItemPropertyArtist: "Briefly",
            MPMediaItemPropertyAlbumTitle: "Briefly",
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime:
                segmentStartTime + player.currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: player.isPlaying ? Double(player.rate) : 0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: rate,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
            MPNowPlayingInfoPropertyExternalContentIdentifier: currentEntryID
        ]
    }
    #endif
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
    @State private var showsCaptureComposer = false
    @State private var showsPDFImporter = false
    @State private var windowControlsVisible = true
    @State private var audioPlayer = NativeAudioPlayer()
    @State private var audioEntry: LibraryEntry?

    var body: some View {
        Group {
            if model.isReady {
                #if os(macOS)
                HStack(alignment: .top, spacing: 24) {
                    MacXNavigation(
                        model: model,
                        showsSettings: $showsSettings,
                        showsCaptureComposer: $showsCaptureComposer
                    )
                    .frame(width: 220)

                    if showsSettings {
                        MacXSettingsWorkspace(model: model)
                            .frame(width: 1_014)
                    } else {
                        LibraryDetail(
                            model: model,
                            showsChannelBrowser: $showsChannelBrowser,
                            audioPlayer: audioPlayer,
                            audioEntry: $audioEntry
                        )
                        .layoutPriority(1)
                        .frame(width: 680)
                        .frame(maxHeight: .infinity)
                        .background(.ultraThinMaterial.opacity(0.56))
                        .overlay { Rectangle().stroke(Color.primary.opacity(0.10)) }

                        MacXRightRail(model: model)
                            .frame(width: 310)
                    }
                }
                .padding(.horizontal, 20)
                .frame(maxWidth: 1298, maxHeight: .infinity, alignment: .top)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background {
                    BrieflyAtmosphere()
                        .ignoresSafeArea()
                }
                .ignoresSafeArea(.container, edges: .top)
                .modifier(FullScreenToolbarBehavior())
                .background(
                    WindowControlPositioner(
                        x: 10,
                        y: -12,
                        controlsVisible: $windowControlsVisible
                    )
                )
                #else
                MobileXAppShell(
                    model: model,
                    showsSettings: $showsSettings,
                    showsCaptureComposer: $showsCaptureComposer,
                    showsChannelBrowser: $showsChannelBrowser,
                    audioPlayer: audioPlayer,
                    audioEntry: $audioEntry
                )
                #endif
            } else {
                #if os(macOS)
                MacXLoadingWorkspace(status: model.status)
                #else
                ProgressView(model.status)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                #endif
            }
        }
        .task { await model.start() }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled else { return }
                await model.runDueChannelChecks()
                await model.runDueVoiceBriefs()
            }
        }
        .onChange(of: scenePhase) {
            if scenePhase == .active {
                Task {
                    #if os(iOS)
                    if model.canEdit { await model.sync() }
                    #endif
                    await model.runDueChannelChecks()
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
                    initialAddress: model.channelBrowserAddress.isEmpty
                        ? model.selectedChannel?.primarySource ?? ""
                        : model.channelBrowserAddress,
                    onCapture: { url, page in
                        if model.selectedChannelSource == "new" ||
                            model.channelBrowserStagesSource
                        {
                            model.stageChannelSource(url.absoluteString)
                        } else {
                            await model.captureWebPage(url: url, page: page)
                        }
                    },
                    onActivity: model.setBrowserIngesting
                )
            } else {
                ChannelLoginView(
                    initialAddress: model.channelBrowserAddress.isEmpty
                        ? model.selectedChannel?.primarySource ?? ""
                        : model.channelBrowserAddress
                )
            }
        }
        #if os(macOS)
        .sheet(isPresented: $showsCaptureComposer) {
            MacCaptureComposer(
                model: model,
                openPDFImporter: {
                    showsCaptureComposer = false
                    showsPDFImporter = true
                },
                openBrowser: {
                    showsCaptureComposer = false
                    showsChannelBrowser = true
                }
            )
        }
        #endif
        #if os(iOS)
        .fullScreenCover(isPresented: $showsSettings) {
            SettingsView(model: model)
        }
        .fullScreenCover(isPresented: $showsCaptureComposer) {
            MobileCaptureComposer(
                model: model,
                openPDFImporter: {
                    showsCaptureComposer = false
                    showsPDFImporter = true
                },
                openBrowser: {
                    showsCaptureComposer = false
                    showsChannelBrowser = true
                }
            )
        }
        #endif
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
        #if os(iOS)
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
        #else
        .overlay(alignment: .top) {
            if let message = model.errorMessage {
                XErrorBanner(message: message, dismiss: model.clearError)
                    .padding(.top, 18)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        #endif
        #if os(macOS)
        .overlay(alignment: .bottomTrailing) {
            BrieflyLogo()
                .padding(.trailing, 24)
                .padding(.bottom, 18)
        }
        #endif
        .overlay(alignment: .bottomTrailing) {
            if model.isSyncing {
                SyncActivityView(model: model)
                    #if os(iOS)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.horizontal, 18)
                    .padding(.bottom, 152)
                    #else
                    .padding(.horizontal, 18)
                    .padding(.bottom, 66)
                    #endif
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            } else if model.isProcessing || model.isGeneratingSpeech ||
                model.isPreparingSpeech
            {
                HStack(spacing: 9) {
                    ProgressView()
                        .controlSize(.small)
                    Text(model.activityStatus)
                        .font(.callout)
                }
                .padding(.horizontal, 14)
                .frame(height: 40)
                #if os(macOS)
                .macLiquidGlass(in: Capsule())
                #else
                .background(.regularMaterial, in: Capsule())
                #endif
                .padding(18)
                #if os(macOS)
                .padding(.bottom, 48)
                #endif
                .accessibilityElement(children: .combine)
            }
        }
        .animation(.snappy(duration: 0.24), value: model.isSyncing)
        .sheet(item: $audioEntry) { entry in
            AudioPlayerScreen(
                text: model.selectedID == entry.id && !model.selectedText.isEmpty
                    ? model.selectedText
                    : entry.text(for: model.selectedVariant)?.text ?? entry.excerpt,
                audioPlayer: audioPlayer
            )
        }
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
        .fontDesign(.rounded)
        #if os(macOS)
        .controlSize(.large)
        #endif
}
}

#if os(macOS)
private struct MacXLoadingWorkspace: View {
    let status: String

    var body: some View {
        HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 5) {
                Color.clear
                    .frame(height: 42)
                    .accessibilityHidden(true)
                ForEach([
                    ("house", "Home"),
                    ("dot.radiowaves.left.and.right", "Channels"),
                    ("headphones", "Briefs"),
                    ("highlighter", "Highlights"),
                    ("trash", "Trash")
                ], id: \.1) { icon, title in
                    Label(title, systemImage: icon)
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                }
                Spacer()
            }
            .padding(.vertical, 12)
            .frame(width: 220)

            VStack(spacing: 0) {
                HStack {
                    Text("Home").font(.title2.weight(.bold))
                    Spacer()
                }
                .padding(18)
                Divider()
                XLoadingState(
                    title: "Opening your library",
                    message: status
                )
            }
            .frame(width: 680)
            .frame(maxHeight: .infinity)
            .background(.ultraThinMaterial.opacity(0.64))
            .overlay { Rectangle().stroke(Color.primary.opacity(0.10)) }

            VStack(alignment: .leading, spacing: 14) {
                Capsule()
                    .fill(Color.primary.opacity(0.07))
                    .frame(height: 44)
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.primary.opacity(0.045))
                    .frame(height: 230)
            }
            .frame(width: 310)
        }
        .padding(.horizontal, 20)
        .frame(maxWidth: 1_298, maxHeight: .infinity, alignment: .top)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background { BrieflyAtmosphere().ignoresSafeArea() }
        .ignoresSafeArea(.container, edges: .top)
    }
}

private struct XErrorBanner: View {
    let message: String
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.red)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text("Something went wrong")
                    .font(.callout.weight(.semibold))
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
            Spacer(minLength: 12)
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .frame(width: 520)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.primary.opacity(0.12))
        }
        .shadow(color: .black.opacity(0.20), radius: 18, y: 8)
    }
}

private struct MacCaptureComposer: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: LibraryModel
    let openPDFImporter: () -> Void
    let openBrowser: () -> Void
    @State private var draft = ""
    @FocusState private var focused: Bool

    private var canCapture: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !model.isProcessing
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Text("Capture")
                    .font(.headline)
                Spacer()
                Button("Save") {
                    let value = draft
                    dismiss()
                    Task { await model.capture(value) }
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .disabled(!canCapture)
            }
            .padding(.horizontal, 16)
            .frame(height: 54)

            Divider()

            HStack(alignment: .top, spacing: 12) {
                Circle()
                    .fill(Color.primary.opacity(0.07))
                    .overlay {
                        Image(systemName: "doc.text")
                            .font(.system(size: 17, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    .frame(width: 42, height: 42)

                TextEditor(text: $draft)
                    .font(.system(size: 18))
                    .scrollContentBackground(.hidden)
                    .focused($focused)
                    .overlay(alignment: .topLeading) {
                        if draft.isEmpty {
                            Text("Paste a link or write something…")
                                .font(.system(size: 18))
                                .foregroundStyle(.tertiary)
                                .allowsHitTesting(false)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 8)
                        }
                    }
            }
            .padding(16)
            .frame(minHeight: 190, alignment: .top)

            Divider()

            HStack(spacing: 4) {
                composerTool("doc.richtext", label: "Import PDF", action: openPDFImporter)
                composerTool("globe", label: "Signed-in browser", action: openBrowser)
                composerTool("clipboard", label: "Paste clipboard") {
                    draft = NSPasteboard.general.string(forType: .string) ?? ""
                }
                Spacer()
                if model.isProcessing {
                    ProgressView().controlSize(.small)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 56)
        }
        .frame(width: 600, height: 302)
        .background(.regularMaterial)
        .task {
            if draft.isEmpty {
                draft = NSPasteboard.general.string(forType: .string) ?? ""
            }
            focused = true
        }
    }

    private func composerTool(
        _ icon: String,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }
}

private struct MacXNavigation: View {
    @Bindable var model: LibraryModel
    @Binding var showsSettings: Bool
    @Binding var showsCaptureComposer: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Color.clear
                .frame(height: 42)
                .accessibilityHidden(true)

            ForEach(LibrarySection.allCases) { section in
                Button {
                    showsSettings = false
                    Task { await model.show(section) }
                } label: {
                    navigationRow(
                        section.title,
                        icon: section.icon,
                        selected: model.activeSection == section &&
                            !model.showingHighlights && !model.showingTrash
                    )
                }
                .buttonStyle(.plain)
            }

            Button {
                showsSettings = false
                model.showHighlights()
            } label: {
                navigationRow(
                    "Highlights",
                    icon: "highlighter",
                    selected: model.showingHighlights
                )
            }
            .buttonStyle(.plain)

            Button {
                showsSettings = false
                model.showTrash()
            } label: {
                navigationRow("Trash", icon: "trash", selected: model.showingTrash)
            }
            .buttonStyle(.plain)

            Button {
                switch model.activeSection {
                case .items:
                    showsCaptureComposer = true
                case .channels:
                    model.query = ""
                    model.showChannelSettings("new")
                case .briefs:
                    model.query = ""
                    model.showVoiceBriefSettings("new")
                }
            } label: {
                Label(primaryActionTitle, systemImage: "plus")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .padding(.top, 12)
            .padding(.horizontal, 4)

            Spacer(minLength: 18)

            Button {
                showsSettings = true
            } label: {
                navigationRow("Settings", icon: "gearshape", selected: showsSettings)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Settings")
        }
        .padding(.vertical, 12)
        .frame(maxHeight: .infinity)
    }

    private var primaryActionTitle: String {
        switch model.activeSection {
        case .items: "Capture"
        case .channels: "New channel"
        case .briefs: "New brief"
        }
    }

    private func navigationRow(
        _ title: String,
        icon: String,
        selected: Bool
    ) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 19, weight: selected ? .semibold : .regular))
                .frame(width: 24)
            Text(title)
                .font(.system(size: 17, weight: selected ? .bold : .medium))
            Spacer()
        }
        .foregroundStyle(selected ? Color.primary : Color.primary.opacity(0.82))
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .contentShape(Rectangle())
    }
}

private struct MacXRightRail: View {
    @Bindable var model: LibraryModel
    @State private var topicBeingRenamed: String?
    @State private var renamedTopic = ""
    @State private var topicBeingDeleted: String?

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 9) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search your library", text: $model.query)
                    .textFieldStyle(.plain)
                if !model.query.isEmpty {
                    Button {
                        model.query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 44)
            .background(.regularMaterial, in: Capsule())
            .overlay { Capsule().stroke(Color.primary.opacity(0.10)) }

            if let entry = model.selectedEntry {
                FeedRailCard(title: "About this post") {
                    if let source = entry.sourceURL,
                        let url = URL(string: source)
                    {
                        Link(destination: url) {
                            HStack(spacing: 8) {
                                Image(systemName: "link")
                                    .foregroundStyle(.secondary)
                                Text(url.host ?? source)
                                    .lineLimit(1)
                                Spacer()
                                Image(systemName: "arrow.up.right")
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(.tertiary)
                            }
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .contentShape(Rectangle())
                        }
                        .foregroundStyle(.primary)
                    }
                    ForEach(Array(entry.topicNames.prefix(5)), id: \.self) { topic in
                        Button {
                            Task {
                                await model.select("")
                                await model.showTopic(topic)
                            }
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "number")
                                    .foregroundStyle(.secondary)
                                Text(topic).lineLimit(1)
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(.tertiary)
                            }
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            } else {
                contextualCard
            }

            FeedRailCard(title: "Your library") {
                FeedMetric(
                    label: "Saved notes",
                    value: model.projection.entries.filter(\.isMainLibraryEntry).count
                )
                FeedMetric(label: "Channels", value: model.channels.count)
                FeedMetric(
                    label: "Voice briefs",
                    value: model.projection.voiceBriefDefinitions.count
                )
            }

            Spacer()
        }
        .padding(.top, 16)
        .frame(maxHeight: .infinity)
        .alert("Rename collection", isPresented: renamingCollection) {
            TextField("Collection name", text: $renamedTopic)
            Button("Cancel", role: .cancel) {}
            Button("Rename") {
                guard let topicBeingRenamed else { return }
                Task { await model.renameTopic(topicBeingRenamed, to: renamedTopic) }
            }
            .disabled(renamedTopic.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .alert("Delete collection?", isPresented: deletingCollection) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                guard let topicBeingDeleted else { return }
                Task { await model.deleteTopic(topicBeingDeleted) }
            }
        } message: {
            Text("The collection will be removed, but its notes will stay in your library.")
        }
    }

    private var renamingCollection: Binding<Bool> {
        Binding(
            get: { topicBeingRenamed != nil },
            set: { if !$0 { topicBeingRenamed = nil } }
        )
    }

    private var deletingCollection: Binding<Bool> {
        Binding(
            get: { topicBeingDeleted != nil },
            set: { if !$0 { topicBeingDeleted = nil } }
        )
    }

    @ViewBuilder
    private var contextualCard: some View {
        switch model.activeSection {
        case .items:
            FeedRailCard(title: "Collections") {
                ForEach(Array(model.projection.documentTopics.prefix(6)), id: \.self) { topic in
                    collectionRow(topic)
                }
            }
        case .channels:
            FeedRailCard(title: "Main channels") {
                ForEach(Array(model.channels.prefix(6))) { channel in
                    railButton(compactLabel(channel.title), icon: channel.kind == .podcast ? "waveform" : "dot.radiowaves.left.and.right") {
                        model.selectChannel(channel.source)
                    }
                }
            }
        case .briefs:
            FeedRailCard(title: "Main briefs") {
                ForEach(Array(model.projection.voiceBriefDefinitions.prefix(6)), id: \.id) { brief in
                    railButton(brief.title, icon: "headphones") {
                        model.selectVoiceBrief(brief.id)
                    }
                }
            }
        }
    }

    private func collectionRow(_ topic: String) -> some View {
        HStack(spacing: 6) {
            Button {
                Task { await model.showTopic(topic) }
            } label: {
                Text(topic)
                    .font(.system(size: 17, weight: .semibold))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Menu {
                Button("Rename", systemImage: "pencil") {
                    renamedTopic = topic
                    topicBeingRenamed = topic
                }
                Button("Delete", systemImage: "trash", role: .destructive) {
                    topicBeingDeleted = topic
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .accessibilityLabel("Settings for \(topic)")
            .help("Settings for \(topic)")
        }
    }

    private func railButton(
        _ title: String,
        icon: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                Text(title)
                    .lineLimit(1)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
#endif

#if os(iOS)
private enum MobilePrimaryTab: String, Hashable {
    case home
    case channels
    case briefs
    case library
}

private struct MobileXAppShell: View {
    @Bindable var model: LibraryModel
    @Binding var showsSettings: Bool
    @Binding var showsCaptureComposer: Bool
    @Binding var showsChannelBrowser: Bool
    @Bindable var audioPlayer: NativeAudioPlayer
    @Binding var audioEntry: LibraryEntry?
    @AppStorage("BrieflyMobileTab") private var selectedTab = MobilePrimaryTab.home
    @State private var showsDetail = false

    var body: some View {
        TabView(selection: $selectedTab) {
            mobileStack(.home)
                .tabItem { Label("Home", systemImage: "house") }
                .tag(MobilePrimaryTab.home)

            mobileStack(.channels)
                .tabItem { Label("Channels", systemImage: "dot.radiowaves.left.and.right") }
                .tag(MobilePrimaryTab.channels)

            mobileStack(.briefs)
                .tabItem { Label("Briefs", systemImage: "headphones") }
                .tag(MobilePrimaryTab.briefs)

            NavigationStack {
                MobileXLibraryScreen(
                    model: model,
                    showsSettings: $showsSettings,
                    openEntry: openEntry
                )
                .navigationDestination(isPresented: $showsDetail) {
                    MobileXDetail(
                        model: model,
                        showsChannelBrowser: $showsChannelBrowser,
                        audioPlayer: audioPlayer,
                        audioEntry: $audioEntry
                    )
                }
            }
            .tabItem { Label("Library", systemImage: "bookmark") }
            .tag(MobilePrimaryTab.library)
        }
        .tint(.primary)
        .overlay(alignment: .bottomTrailing) {
            Button(action: primaryCreate) {
                Image(systemName: "plus")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 56, height: 56)
                    .background(Color.accentColor, in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .shadow(color: .black.opacity(0.18), radius: 10, y: 5)
            .padding(.trailing, 18)
            .padding(.bottom, 58)
            .accessibilityLabel(primaryCreateLabel)
        }
        .onChange(of: selectedTab) {
            showsDetail = false
            model.query = ""
            Task { await activate(selectedTab) }
        }
        .task { await activate(selectedTab) }
    }

    private func mobileStack(_ tab: MobilePrimaryTab) -> some View {
        NavigationStack {
            MobileXFeedScreen(
                model: model,
                tab: tab,
                showsSettings: $showsSettings,
                openEntry: openEntry,
                openConfiguration: {
                    showsDetail = true
                }
            )
            .navigationDestination(isPresented: $showsDetail) {
                MobileXDetail(
                    model: model,
                    showsChannelBrowser: $showsChannelBrowser,
                    audioPlayer: audioPlayer,
                    audioEntry: $audioEntry
                )
            }
        }
    }

    private func openEntry(_ entry: LibraryEntry) {
        Task {
            if entry.voiceBriefID != nil {
                model.activeSection = .briefs
                model.selectedVoiceBriefID = entry.voiceBriefID ?? ""
            } else if selectedTab == .home {
                model.activeSection = .items
            }
            await model.select(entry.id)
            showsDetail = true
        }
    }

    private func activate(_ tab: MobilePrimaryTab) async {
        switch tab {
        case .home: await model.show(.items)
        case .channels: await model.show(.channels)
        case .briefs: await model.show(.briefs)
        case .library: break
        }
    }

    private var primaryCreateLabel: String {
        switch selectedTab {
        case .home, .library: "Capture"
        case .channels: "New channel"
        case .briefs: "New brief"
        }
    }

    private func primaryCreate() {
        switch selectedTab {
        case .home, .library:
            showsCaptureComposer = true
        case .channels:
            model.showChannelSettings("new")
            showsDetail = true
        case .briefs:
            model.showVoiceBriefSettings("new")
            showsDetail = true
        }
    }
}

private struct MobileXFeedScreen: View {
    @Bindable var model: LibraryModel
    let tab: MobilePrimaryTab
    @Binding var showsSettings: Bool
    let openEntry: (LibraryEntry) -> Void
    let openConfiguration: () -> Void

    private var entries: [LibraryEntry] {
        let candidates: [LibraryEntry]
        switch tab {
        case .home:
            candidates = model.filteredEntries
        case .channels:
            if model.selectedChannelSource.isEmpty {
                var seen = Set<String>()
                candidates = model.channels.flatMap { model.channelEntries(for: $0.source) }
                    .filter { seen.insert($0.id).inserted }
            } else {
                candidates = model.channelEntries(for: model.selectedChannelSource)
            }
        case .briefs:
            if model.selectedVoiceBriefID.isEmpty {
                candidates = model.projection.voiceBriefDefinitions.flatMap {
                    model.projection.episodes(for: $0.id)
                }
            } else {
                candidates = model.projection.episodes(for: model.selectedVoiceBriefID)
            }
        case .library:
            candidates = []
        }
        return candidates
            .filter { $0.matches(model.query) }
            .sorted {
                ($0.createdAt ?? $0.updatedAt ?? "") >
                    ($1.createdAt ?? $1.updatedAt ?? "")
            }
    }

    var body: some View {
        VStack(spacing: 0) {
            MobileXHeader(
                title: title,
                showsLogo: tab == .home,
                showsSettings: $showsSettings,
                trailing: configurationAction
            )

            MobileXSearchField(text: $model.query, prompt: searchPrompt)
                .padding(.top, 8)

            choices

            if entries.isEmpty {
                XEmptyState(
                    icon: emptyIcon,
                    title: emptyTitle,
                    message: emptyMessage
                )
                .frame(maxWidth: 720, maxHeight: .infinity)
                .frame(maxWidth: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(entries) { entry in
                            FeedEntryRow(entry: entry) {
                                openEntry(entry)
                            }
                            .modifier(EntryContextMenu(model: model, entry: entry))
                        }
                    }
                    .frame(maxWidth: 720)
                    .frame(maxWidth: .infinity)
                    .padding(.bottom, 96)
                }
                .scrollIndicators(.hidden)
                .refreshable { await refresh() }
            }
        }
        .background(readerBackground.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
    }

    private var choices: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                choiceButton("All", selected: allSelected) {
                    switch tab {
                    case .home: Task { await model.showTopic("All") }
                    case .channels: model.selectedChannelSource = ""
                    case .briefs: model.selectedVoiceBriefID = ""
                    case .library: break
                    }
                }

                switch tab {
                case .home:
                    ForEach(model.projection.documentTopics, id: \.self) { topic in
                        choiceButton(topic, selected: model.selectedTopic == topic) {
                            Task { await model.showTopic(topic) }
                        }
                    }
                case .channels:
                    ForEach(model.channels) { channel in
                        choiceButton(
                            channel.title,
                            selected: model.selectedChannelSource == channel.source
                        ) {
                            model.selectChannel(channel.source)
                        }
                    }
                case .briefs:
                    ForEach(model.projection.voiceBriefDefinitions, id: \.id) { brief in
                        choiceButton(
                            brief.title,
                            selected: model.selectedVoiceBriefID == brief.id
                        ) {
                            model.selectVoiceBrief(brief.id)
                        }
                    }
                case .library:
                    EmptyView()
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .defaultScrollAnchor(.leading)
        .overlay(alignment: .bottom) { Divider() }
    }

    private func choiceButton(
        _ label: String,
        selected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(label)
                .font(.subheadline.weight(selected ? .semibold : .regular))
                .lineLimit(1)
                .padding(.horizontal, 15)
                .frame(height: 38)
                .background(selected ? Color.primary : Color.primary.opacity(0.06), in: Capsule())
                .foregroundStyle(selected ? Color(uiColor: .systemBackground) : Color.primary)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private var configurationAction: MobileXHeaderAction? {
        switch tab {
        case .channels:
            guard let channel = model.selectedChannel else { return nil }
            return MobileXHeaderAction(icon: "ellipsis", label: "Channel settings") {
                model.showChannelSettings(channel.source)
                openConfiguration()
            }
        case .briefs:
            guard let brief = model.selectedVoiceBrief else { return nil }
            return MobileXHeaderAction(icon: "ellipsis", label: "Brief settings") {
                model.showVoiceBriefSettings(brief.id)
                openConfiguration()
            }
        default:
            return nil
        }
    }

    private func refresh() async {
        switch tab {
        case .home: await model.refreshLibrary()
        case .channels:
            if model.selectedChannel != nil { await model.checkSelectedChannel() }
            else { await model.runDueChannelChecks() }
        case .briefs:
            if model.selectedVoiceBrief != nil { await model.runSelectedVoiceBrief() }
            else { await model.runDueVoiceBriefs() }
        case .library: break
        }
    }

    private var title: String {
        switch tab {
        case .home: "Home"
        case .channels: "Channels"
        case .briefs: "Briefs"
        case .library: "Library"
        }
    }

    private var searchPrompt: String {
        switch tab {
        case .home: "Search Home"
        case .channels: "Search Channels"
        case .briefs: "Search Briefs"
        case .library: "Search Library"
        }
    }

    private var allSelected: Bool {
        switch tab {
        case .home: model.selectedTopic == "All" || model.selectedTopic.isEmpty
        case .channels: model.selectedChannelSource.isEmpty
        case .briefs: model.selectedVoiceBriefID.isEmpty
        case .library: false
        }
    }

    private var emptyIcon: String {
        if !model.query.isEmpty { return "magnifyingglass" }
        return switch tab {
        case .home: "tray"
        case .channels: "dot.radiowaves.left.and.right"
        case .briefs: "headphones"
        case .library: "bookmark"
        }
    }

    private var emptyTitle: String {
        if !model.query.isEmpty { return "No matches" }
        return switch tab {
        case .home: "Nothing here yet"
        case .channels: "No channel updates"
        case .briefs: "No generated briefs"
        case .library: "Library is empty"
        }
    }

    private var emptyMessage: String {
        if !model.query.isEmpty { return "Try another search." }
        return switch tab {
        case .home: "Capture a link or note to start your feed."
        case .channels: "Add a channel, then pull to fetch its latest updates."
        case .briefs: "Create a brief from your channels, then generate an episode."
        case .library: "Highlights and recently deleted notes appear here."
        }
    }
}

private struct MobileXHeaderAction {
    let icon: String
    let label: String
    let action: () -> Void
}

private struct MobileXHeader: View {
    let title: String
    var showsLogo = false
    @Binding var showsSettings: Bool
    var trailing: MobileXHeaderAction? = nil

    var body: some View {
        ZStack {
            if showsLogo {
                BrieflyLogo()
            } else {
                Text(title)
                    .font(.headline.weight(.bold))
            }

            HStack {
                Button { showsSettings = true } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 19, weight: .semibold))
                        .frame(width: 44, height: 44)
                        .background(Color(uiColor: .systemBackground), in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Settings")

                Spacer()

                if let trailing {
                    headerButton(trailing)
                } else {
                    Color.clear.frame(width: 44, height: 44)
                }
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 52)
        .background(.regularMaterial)
        .overlay(alignment: .bottom) { Divider() }
    }

    private func headerButton(_ action: MobileXHeaderAction) -> some View {
        Button(action: action.action) {
            Image(systemName: action.icon)
                .font(.system(size: 18, weight: .semibold))
                .frame(width: 44, height: 44)
                .background(Color(uiColor: .systemBackground), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(action.label)
    }
}

private struct MobileXSearchField: View {
    @Binding var text: String
    let prompt: String

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .submitLabel(.search)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 6)
        .frame(maxWidth: 688)
        .frame(height: 44)
        .background(Color.primary.opacity(0.06), in: Capsule())
        .padding(.horizontal, 16)
    }
}

private struct MobileXLibraryScreen: View {
    private enum Section: String, CaseIterable, Hashable {
        case highlights = "Highlights"
        case trash = "Trash"
    }

    @Bindable var model: LibraryModel
    @Binding var showsSettings: Bool
    let openEntry: (LibraryEntry) -> Void
    @State private var section = Section.highlights

    var body: some View {
        VStack(spacing: 0) {
            MobileXHeader(title: "Library", showsSettings: $showsSettings)

            HStack(spacing: 8) {
                ForEach(Section.allCases, id: \.self) { item in
                    Button {
                        section = item
                        if item == .highlights { model.showHighlights() }
                        else { model.showTrash() }
                    } label: {
                        Text(item.rawValue)
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .background(section == item ? Color.primary : Color.primary.opacity(0.06), in: Capsule())
                            .foregroundStyle(section == item ? Color(uiColor: .systemBackground) : Color.primary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .overlay(alignment: .bottom) { Divider() }

            if section == .highlights {
                if model.highlightsText.isEmpty {
                    XEmptyState(
                        icon: "highlighter",
                        title: "No highlights yet",
                        message: "Select a passage in any saved document, then choose Highlight."
                    )
                    .frame(maxWidth: 720, maxHeight: .infinity)
                } else {
                    ScrollView {
                        MarkdownArticle(model.highlightsText)
                            .frame(maxWidth: 680, alignment: .leading)
                            .padding(.horizontal, 22)
                            .padding(.vertical, 28)
                            .padding(.bottom, 80)
                            .frame(maxWidth: .infinity)
                    }
                }
            } else if model.trashEntries.isEmpty {
                XEmptyState(
                    icon: "trash",
                    title: "Trash is empty",
                    message: "Deleted notes remain available here."
                )
                .frame(maxWidth: 720, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(model.trashEntries) { entry in
                            FeedEntryRow(entry: entry) { openEntry(entry) }
                        }
                    }
                    .frame(maxWidth: 720)
                    .frame(maxWidth: .infinity)
                    .padding(.bottom, 96)
                }
            }
        }
        .background(readerBackground.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .task { model.showHighlights() }
    }
}

private struct MobileXDetail: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: LibraryModel
    @Binding var showsChannelBrowser: Bool
    @Bindable var audioPlayer: NativeAudioPlayer
    @Binding var audioEntry: LibraryEntry?

    var body: some View {
        LibraryDetail(
            model: model,
            showsChannelBrowser: $showsChannelBrowser,
            audioPlayer: audioPlayer,
            audioEntry: $audioEntry
        )
        .background(readerBackground.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    model.navigateBack()
                    dismiss()
                } label: {
                    Image(systemName: "arrow.left")
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Back")
            }
            if model.selectedEntry != nil {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        if model.canEdit && !model.showingTrash {
                            Button("Regenerate summaries", systemImage: "arrow.clockwise") {
                                Task { await model.processSelected() }
                            }
                            .disabled(model.isProcessing)
                            Button("Move to Trash", systemImage: "trash", role: .destructive) {
                                Task {
                                    await model.trashSelected()
                                    dismiss()
                                }
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .frame(width: 44, height: 44)
                            .background(Color(uiColor: .systemBackground), in: Circle())
                            .contentShape(Circle())
                    }
                    .accessibilityLabel("More actions")
                }
            }
        }
        .navigationBarBackButtonHidden(true)
    }
}

private struct MobileCaptureComposer: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: LibraryModel
    let openPDFImporter: () -> Void
    let openBrowser: () -> Void
    @State private var draft = ""
    @FocusState private var focused: Bool

    private var canCapture: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !model.isProcessing
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                TextEditor(text: $draft)
                    .font(.system(size: 19))
                    .scrollContentBackground(.hidden)
                    .focused($focused)
                    .padding(.horizontal, 14)
                    .padding(.top, 12)
                    .overlay(alignment: .topLeading) {
                        if draft.isEmpty {
                            Text("Paste a link or write something…")
                                .font(.system(size: 19))
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 19)
                                .padding(.top, 22)
                                .allowsHitTesting(false)
                        }
                    }

                Divider()

                HStack(spacing: 8) {
                    composerTool("doc.richtext", label: "Import PDF", action: openPDFImporter)
                    composerTool("globe", label: "Signed-in browser", action: openBrowser)
                    Spacer()
                    if model.isProcessing { ProgressView().controlSize(.small) }
                }
                .padding(.horizontal, 10)
                .frame(height: 58)
            }
            .background(readerBackground.ignoresSafeArea())
            .navigationTitle("Capture")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let value = draft
                        dismiss()
                        Task { await model.capture(value) }
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
                    .disabled(!canCapture)
                }
            }
        }
        .task { focused = true }
    }

    private func composerTool(
        _ icon: String,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

private struct MobileHome: View {
    @Bindable var model: LibraryModel
    @Binding var showsSettings: Bool
    let onOpenDetail: () -> Void

    private var entries: [LibraryEntry] {
        model.homeEntries
            .filter { $0.matches(model.query) }
            .sorted {
                ($0.createdAt ?? $0.updatedAt ?? "") <
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

                BrieflyLogo()
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
                    LazyVStack(spacing: 0) {
                        ForEach(entries) { entry in
                            MobileHomeEntryCard(
                                entry: entry
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
                .defaultScrollAnchor(.bottom)
                .scrollIndicators(.hidden)
            }
        }
        .background(sidebarBackground.ignoresSafeArea())
    }
}

private struct MobileHomeEntryCard: View {
    let entry: LibraryEntry
    let action: () -> Void

    var body: some View {
        MobileEntryRow(entry: entry, kind: inferredKind, action: action)
    }

    private var inferredKind: MobileEntryKind {
        entry.voiceBriefID == nil ? .item : .brief
    }
}

private enum MobileEntryKind {
    case item
    case channel
    case brief

    var palette: GrainyGradientPalette {
        switch self {
        case .item: .item
        case .channel: .channel
        case .brief: .brief
        }
    }
}

private struct MobileEntryCard: View {
    let entry: LibraryEntry
    let kind: MobileEntryKind
    var selected = false
    let action: () -> Void

    var body: some View {
        MobileEntryRow(
            entry: entry,
            kind: kind,
            selected: selected,
            action: action
        )
    }
}

private struct MobileEntryRow: View {
    let entry: LibraryEntry
    let kind: MobileEntryKind
    var selected = false
    let action: () -> Void

    private var accent: Color {
        switch kind {
        case .item: Color(red: 0.60, green: 0.34, blue: 0.96)
        case .channel: Color(red: 0.93, green: 0.39, blue: 0.25)
        case .brief: Color(red: 0.08, green: 0.70, blue: 0.62)
        }
    }

    private var icon: String {
        switch kind {
        case .brief:
            return entry.hasAudio == true ? "waveform" : "headphones"
        case .channel:
            return "dot.radiowaves.left.and.right"
        case .item:
            return switch entry.entryType {
            case "pdf": "doc.richtext"
            case "link": "link"
            default: "doc.text"
            }
        }
    }

    private var date: Date? {
        guard let value = entry.createdAt ?? entry.updatedAt else { return nil }
        return try? Date(value, strategy: .iso8601)
    }

    private var dateText: String? {
        guard let date else { return nil }
        let elapsed = max(0, Date().timeIntervalSince(date))
        switch elapsed {
        case ..<3_600: return "\(max(1, Int(elapsed / 60)))m"
        case ..<86_400: return "\(Int(elapsed / 3_600))h"
        case ..<604_800: return "\(Int(elapsed / 86_400))d"
        case ..<2_592_000: return "\(Int(elapsed / 604_800))w"
        case ..<31_536_000: return "\(Int(elapsed / 2_592_000))mo"
        default: return "\(Int(elapsed / 31_536_000))y"
        }
    }

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(accent)
                    .symbolRenderingMode(.hierarchical)
                    .frame(width: 30, height: 30)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(entry.title)
                            .font(.headline.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        if let dateText {
                            Text(dateText)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.tertiary)
                                .monospacedDigit()
                                .fixedSize()
                        }
                    }

                    if !entry.excerpt.isEmpty {
                        Text(entry.excerpt)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(accent.opacity(0.9))
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, minHeight: 76, alignment: .leading)
            .contentShape(Rectangle())
            .background(selected ? accent.opacity(0.10) : Color.clear)
        }
        .buttonStyle(.plain)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.primary.opacity(0.075))
                .frame(height: 0.5)
                .padding(.leading, 54)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityValue(
            date.map {
                $0.formatted(.relative(presentation: .named, unitsStyle: .wide))
            } ?? ""
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
                    if isItemDetail, let entry = model.selectedEntry {
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
                    Button(action: primaryAction) {
                        if model.isGeneratingSpeech && isPlayableDetail {
                            ProgressView()
                                .tint(.white)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .contentShape(Circle())
                        } else {
                            Image(systemName: primaryActionIcon)
                                .font(.system(size: 23, weight: .medium))
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .contentShape(Circle())
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.primary)
                    .frame(width: 58, height: 58)
                    .mobileGlass(in: Circle(), tint: .accentColor)
                    .accessibilityLabel(primaryActionLabel)
                    .disabled(primaryActionDisabled)

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

    private var isPlayableDetail: Bool {
        isVoiceBriefDetail || isItemDetail
    }

    private var isChannelPage: Bool {
        !homeSelected && model.activeSection == .channels &&
            model.selectedChannel != nil && model.selectedID.isEmpty
    }

    private var isVoiceBriefPage: Bool {
        !homeSelected && model.activeSection == .briefs &&
            model.selectedVoiceBrief != nil && model.selectedID.isEmpty
    }

    private var primaryActionIcon: String {
        if isPlayableDetail { return "play.fill" }
        if isChannelPage { return "arrow.clockwise" }
        if isVoiceBriefPage { return "sparkles" }
        return "plus"
    }

    private var primaryActionLabel: String {
        if isPlayableDetail { return "Play audio" }
        if isChannelPage { return "Fetch fresh channel items" }
        if isVoiceBriefPage { return "Generate fresh voice brief" }
        return createLabel
    }

    private var primaryActionDisabled: Bool {
        (isPlayableDetail &&
            (model.isGeneratingSpeech || model.isRunningVoiceBrief ||
                model.selectedText.isEmpty)) ||
            (isChannelPage && model.isCheckingChannel) ||
            (isVoiceBriefPage &&
                (model.isRunningVoiceBrief || model.selectedVoiceBrief?.sources.isEmpty != false))
    }

    private func primaryAction() {
        if isPlayableDetail, let entry = model.selectedEntry {
            Task {
                let variant = model.selectedVariant
                let text = model.selectedText
                let playbackID = model.audioPlaybackID(
                    for: entry,
                    variant: variant,
                    text: text
                )
                do {
                    let shouldGenerate = try audioPlayer.startStream(
                        entryID: entry.id,
                        title: entry.title,
                        playbackID: playbackID,
                        positionID: "\(entry.id):\(variant.rawValue)"
                    )
                    if shouldGenerate {
                        var startedPlayback = false
                        _ = await model.streamPlayableAudio(
                            for: entry,
                            variant: variant,
                            text: text
                        ) { url in
                            try audioPlayer.appendSegment(url, playbackID: playbackID)
                            if !startedPlayback {
                                startedPlayback = true
                                audioEntry = entry
                            }
                        }
                        audioPlayer.finishStream(playbackID: playbackID)
                        if !startedPlayback { audioPlayer.stop() }
                    } else {
                        audioEntry = entry
                    }
                } catch {
                    model.errorMessage = error.localizedDescription
                    audioPlayer.stop()
                }
            }
            return
        }
        if isChannelPage {
            Task { await model.checkSelectedChannel() }
        } else if isVoiceBriefPage {
            Task { await model.runSelectedVoiceBrief() }
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

#endif

private struct AudioPlayerScreen: View {
    @Environment(\.dismiss) private var dismiss
    let text: String
    @Bindable var audioPlayer: NativeAudioPlayer

    var body: some View {
        VStack(spacing: 0) {
            #if os(macOS)
            HStack(spacing: 12) {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Text("Listen")
                    .font(.headline)
                Spacer()
                if audioPlayer.isPlaying {
                    Text("Now playing")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 54)
            Divider()
            #endif

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
        #if os(iOS)
        .presentationBackground(playerBackground)
        .presentationCornerRadius(32)
        .presentationDragIndicator(.visible)
        .presentationDetents([.large])
        #else
        .frame(minWidth: 560, idealWidth: 680, minHeight: 620, idealHeight: 760)
        #endif
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

    private var playerBackground: Color {
        readerBackground
    }
}

#if os(iOS)
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
private struct FullScreenToolbarBehavior: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.windowToolbarFullScreenVisibility(.onHover)
        } else {
            content
        }
    }
}

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

private extension View {
    func macLiquidGlass<S: Shape>(
        in shape: S,
        tint: Color? = nil,
        interactive: Bool = false
    ) -> some View {
        modifier(
            MacLiquidGlass(
                shape: shape,
                tint: tint,
                interactive: interactive
            )
        )
    }

    @ViewBuilder
    func actionBarGlass() -> some View {
        macLiquidGlass(in: Capsule(), interactive: true)
    }
}

private struct MacLiquidGlass<S: Shape>: ViewModifier {
    let shape: S
    let tint: Color?
    let interactive: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            let glass = tint.map { Glass.regular.tint($0) } ?? .regular
            if interactive {
                content.glassEffect(glass.interactive(), in: shape)
            } else {
                content.glassEffect(glass, in: shape)
            }
        } else if let tint {
            content.background(tint.opacity(0.22), in: shape)
                .background(.regularMaterial, in: shape)
        } else {
            content.background(.regularMaterial, in: shape)
        }
    }
}
#endif

private struct BrieflyAtmosphere: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24.0, paused: reduceMotion)) {
            context in
            GeometryReader { geometry in
                let time = reduceMotion
                    ? 0
                    : context.date.timeIntervalSinceReferenceDate
                        .truncatingRemainder(dividingBy: 240)
                Color.white.colorEffect(
                    ShaderLibrary.organicAtmosphere(
                        .float2(geometry.size),
                        .float(time),
                        .float(colorScheme == .dark ? 1 : 0)
                    )
                )
            }
        }
        .overlay {
            Rectangle().fill(
                colorScheme == .dark
                    ? Color.black.opacity(0.12)
                    : Color.white.opacity(0.08)
            )
        }
    }
}

private struct BrieflyLogo: View {
    var body: some View {
        Group {
            #if os(macOS)
            Image("BrieflyWordmark")
                .resizable()
                .renderingMode(.template)
                .scaledToFit()
                .frame(width: 76, height: 30)
            #else
            Image("BrieflyWordmark")
                .resizable()
                .renderingMode(.template)
                .scaledToFit()
                .frame(width: 97, height: 39)
            #endif
        }
        .foregroundStyle(.primary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Briefly")
    }
}

private struct SyncActivityView: View {
    @Bindable var model: LibraryModel

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "icloud")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 36, height: 36)
                .background(Color.accentColor.opacity(0.12), in: Circle())

            VStack(alignment: .leading, spacing: 5) {
                Text("Syncing with iCloud")
                    .font(.subheadline.weight(.semibold))

                if model.syncTotal > 0 {
                    HStack {
                        Text("\(model.syncCompleted) of \(model.syncTotal) changes")
                        Spacer(minLength: 16)
                        Text(
                            Double(model.syncCompleted) / Double(model.syncTotal),
                            format: .percent.precision(.fractionLength(0))
                        )
                        .monospacedDigit()
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    ProgressView(
                        value: Double(model.syncCompleted),
                        total: Double(model.syncTotal)
                    )
                    .tint(.accentColor)
                } else {
                    HStack(spacing: 7) {
                        ProgressView()
                            .controlSize(.small)
                        Text(model.status)
                            .lineLimit(1)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            .frame(width: 210, alignment: .leading)
        }
        .padding(14)
        #if os(macOS)
        .macLiquidGlass(
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
        #else
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        #endif
        .shadow(color: .black.opacity(0.13), radius: 16, y: 7)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Syncing with iCloud")
        .accessibilityValue(
            model.syncTotal > 0
                ? "\(model.syncCompleted) of \(model.syncTotal) changes"
                : model.status
        )
    }
}

private struct LibrarySidebar: View {
    @Bindable var model: LibraryModel
    @Binding var showsSettings: Bool
    @Bindable var audioPlayer: NativeAudioPlayer
    @Binding var audioEntry: LibraryEntry?
    var onOpenDetail: () -> Void = {}

    var body: some View {
        VStack(spacing: 0) {
            #if os(macOS)
            Color.clear
            .frame(height: 45)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            #endif

            #if os(macOS)
            HStack {
                BrieflyLogo()
                Spacer()
            }
            .padding(.horizontal, 20)
            .frame(height: 54)
            #endif

            #if os(iOS)
            MobileLibraryRows(model: model, onOpenDetail: onOpenDetail)
            #else
            ScrollView {
                xSidebarNavigation
            }
            .scrollIndicators(.hidden)
            #endif

            #if os(macOS)
            sidebarFooter
                .padding(14)
            #endif
        }
        #if os(macOS)
        .background {
            ZStack {
                sidebarBackground.opacity(0.22)
                Rectangle()
                    .fill(.thinMaterial)
                    .opacity(0.72)
            }
            .ignoresSafeArea()
        }
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(.white.opacity(0.07))
                .frame(width: 1)
                .ignoresSafeArea()
        }
        #else
        .background(sidebarBackground.ignoresSafeArea())
        #endif
    }

    #if os(macOS)
    private var xSidebarNavigation: some View {
        LazyVStack(alignment: .leading, spacing: 4) {
            ForEach(LibrarySection.allCases) { section in
                Button {
                    Task { await model.show(section) }
                } label: {
                    xSidebarRow(
                        icon: section.icon,
                        title: section.title,
                        selected: model.activeSection == section
                    )
                }
                .accessibilityAddTraits(
                    model.activeSection == section ? .isSelected : []
                )
                .help(section.title)
            }

            if model.activeSection == .items {
                Divider()
                    .padding(.vertical, 10)
                    .padding(.horizontal, 8)

                Button(action: model.showInbox) {
                    xSidebarRow(
                        icon: "tray",
                        title: "Inbox",
                        selected: model.selectedTopic == "All" &&
                            !model.showingHighlights && !model.showingTrash
                    )
                }
                Button(action: model.showHighlights) {
                    xSidebarRow(
                        icon: "highlighter",
                        title: "Highlights",
                        selected: model.showingHighlights
                    )
                }
                Button(action: model.showTrash) {
                    xSidebarRow(
                        icon: "trash",
                        title: "Trash",
                        selected: model.showingTrash
                    )
                }
            }

            if model.activeSection != .items {
                Button {
                    model.query = ""
                    if model.activeSection == .channels {
                        model.showChannelSettings("new")
                    } else {
                        model.showVoiceBriefSettings("new")
                    }
                } label: {
                    Label(
                        model.activeSection == .channels ? "New channel" : "New brief",
                        systemImage: "plus"
                    )
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .frame(height: 42)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .padding(.top, 14)
                .padding(.horizontal, 4)
            } else {
                Button {
                    let text = NSPasteboard.general.string(forType: .string) ?? ""
                    Task { await model.capture(text) }
                } label: {
                    Label("Capture", systemImage: "plus")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .frame(height: 42)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .padding(.top, 14)
                .padding(.horizontal, 4)
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 14)
        .padding(.top, 8)
    }

    private var sidebarFooter: some View {
        VStack(spacing: 4) {
            if let playingEntry {
                Button {
                    audioEntry = playingEntry
                } label: {
                    xSidebarRow(icon: "waveform", title: "Now playing", selected: false)
                }
                .symbolEffect(.variableColor.iterative, options: .repeating)
            }

            Button {
                showsSettings = true
            } label: {
                xSidebarRow(icon: "gearshape", title: "Settings", selected: false)
            }
            .help("Settings")
        }
        .buttonStyle(.plain)
    }

    private var playingEntry: LibraryEntry? {
        guard
            audioPlayer.isPlaying,
            let id = audioPlayer.currentEntryID
        else { return nil }
        return model.projection.entries.first { $0.id == id }
    }

    private func xSidebarRow(
        icon: String,
        title: String,
        selected: Bool
    ) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 19, weight: selected ? .semibold : .regular))
                .frame(width: 24)
            Text(title)
                .font(.system(size: 17, weight: selected ? .bold : .medium))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .foregroundStyle(selected ? Color.primary : Color.primary.opacity(0.82))
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, minHeight: 46, alignment: .leading)
        .contentShape(Rectangle())
    }
    #endif
}

#if os(macOS)
private struct SidebarTopic: Identifiable {
    let name: String
    let count: Int
    var id: String { name }
}

private struct MacSidebarFilters: View {
    @Bindable var model: LibraryModel

    private var notes: [LibraryEntry] {
        model.projection.entries.filter(\.isMainLibraryEntry)
    }

    private var topics: [SidebarTopic] {
        model.projection.documentTopics.map { topic in
            SidebarTopic(
                name: topic,
                count: notes.count { $0.topicNames.contains(topic) }
            )
        }
        .sorted {
            $0.count != $1.count
                ? $0.count > $1.count
                : $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    var body: some View {
        LazyVStack(spacing: 2) {
            switch model.activeSection {
            case .items:
                SidebarRow(
                    icon: "tray",
                    title: "Inbox",
                    count: notes.count,
                    selected: model.selectedTopic == "All" &&
                        !model.showingHighlights && !model.showingTrash,
                    action: model.showInbox
                )
                SidebarRow(
                    icon: "highlighter",
                    title: "Highlights",
                    count: model.loadedHighlightCount,
                    selected: model.showingHighlights,
                    action: model.showHighlights
                )
                SidebarRow(
                    icon: "trash",
                    title: "Trash",
                    count: model.loadedTrashCount,
                    selected: model.showingTrash,
                    action: model.showTrash
                )

                if !topics.isEmpty {
                    SidebarSectionHeader("Collections")
                    ForEach(topics) { topic in
                        SidebarRow(
                            icon: "folder",
                            title: topic.name,
                            count: topic.count,
                            selected: model.selectedTopic == topic.name &&
                                !model.showingHighlights && !model.showingTrash
                        ) {
                            Task { await model.showTopic(topic.name) }
                        }
                    }
                }

            case .channels:
                SidebarRow(
                    icon: "dot.radiowaves.left.and.right",
                    title: "All Channels",
                    count: model.channels.count,
                    selected: model.selectedChannelDomain == "All"
                ) {
                    model.showChannelDomain("All")
                }
                if !model.channels.isEmpty {
                    SidebarSectionHeader("Domains")
                    ForEach(channelDomainGroups(model.channels)) { group in
                        SidebarRow(
                            icon: "globe",
                            title: group.domain,
                            count: group.channels.count,
                            selected: model.selectedChannelDomain == group.domain
                        ) {
                            model.showChannelDomain(group.domain)
                        }
                    }
                }

            case .briefs:
                SidebarRow(
                    icon: "headphones",
                    title: "All",
                    count: model.projection.entries.count {
                        $0.entryType == "voice_brief_episode"
                    },
                    selected: model.selectedVoiceBriefID.isEmpty
                ) {
                    model.selectVoiceBrief("")
                }
                if !model.projection.voiceBriefDefinitions.isEmpty {
                    SidebarSectionHeader("Voice Briefs")
                    ForEach(model.projection.voiceBriefDefinitions, id: \.id) { brief in
                        SidebarRow(
                            icon: "headphones",
                            title: brief.title,
                            count: model.projection.episodes(for: brief.id).count,
                            selected: model.selectedVoiceBriefID == brief.id
                        ) {
                            model.selectVoiceBrief(brief.id)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, 4)
        .padding(.bottom, 10)
    }
}

private struct SidebarSectionHeader: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title.uppercased())
            .font(.system(size: 11, weight: .semibold))
            .tracking(0.5)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 11)
            .padding(.top, 18)
            .padding(.bottom, 5)
    }
}
#endif

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
private struct MobileLibraryRows: View {
    @Bindable var model: LibraryModel
    let onOpenDetail: () -> Void

    private var notes: [LibraryEntry] {
        model.projection.entries.filter {
            $0.isMainLibraryEntry && $0.matches(model.query)
        }
    }

    private var trashNotes: [LibraryEntry] {
        model.trashEntries.filter { $0.matches(model.query) }
    }

    private var topics: [(name: String, count: Int)] {
        model.projection.documentTopics.compactMap { topic in
            let count = notes.count { $0.topicNames.contains(topic) }
            guard model.query.isEmpty || count > 0 else { return nil }
            return (name: topic, count: count)
        }
        .sorted {
            $0.count != $1.count
                ? $0.count > $1.count
                : $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    private var channels: [LibraryChannel] {
        model.filteredChannels.sorted {
            let leftCount = model.channelEntries(for: $0.source).count
            let rightCount = model.channelEntries(for: $1.source).count
            return leftCount != rightCount
                ? leftCount > rightCount
                : $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
    }

    private var briefs: [LibraryVoiceBrief] {
        let query = model.query.trimmingCharacters(in: .whitespacesAndNewlines)
        let matching = model.projection.voiceBriefDefinitions.filter { brief in
            guard !query.isEmpty else { return true }
            return brief.title.localizedCaseInsensitiveContains(query) ||
                model.projection.episodes(for: brief.id).contains { $0.matches(query) }
        }
        return matching.sorted {
            let leftCount = model.projection.episodes(for: $0.id).count
            let rightCount = model.projection.episodes(for: $1.id).count
            return leftCount != rightCount
                ? leftCount > rightCount
                : $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
    }

    private var itemCollectionCount: Int {
        1 + (model.query.isEmpty ? 1 : 0) + topics.count +
            (model.query.isEmpty || !trashNotes.isEmpty ? 1 : 0)
    }

    private var entries: [LibraryEntry] {
        let candidates = switch model.activeSection {
        case .items:
            model.filteredEntries
        case .channels:
            model.channelEntries(for: model.selectedChannelSource)
        case .briefs:
            model.projection.episodes(for: model.selectedVoiceBriefID)
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
                ? model.showingTrash
                    ? "Trash is empty"
                    : model.selectedTopic == "All"
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

    private var collectionTitle: String {
        switch model.activeSection {
        case .items:
            model.showingTrash
                ? "Trash"
                : model.selectedTopic == "All" ? "Inbox" : model.selectedTopic
        case .channels:
            model.selectedChannel?.title ?? "Channel"
        case .briefs:
            model.selectedVoiceBrief?.title ?? "Voice Brief"
        }
    }

    var body: some View {
        Group {
            switch model.activeSection {
            case .items:
                if model.selectedTopic.isEmpty && !model.showingTrash {
                    itemCollections
                } else {
                    entryCollection
                }
            case .channels:
                if model.selectedChannelSource.isEmpty || model.selectedChannelSource == "new" {
                    channelCollections
                } else {
                    entryCollection
                }
            case .briefs:
                if model.selectedVoiceBriefID.isEmpty || model.selectedVoiceBriefID == "new" {
                    briefCollections
                } else {
                    entryCollection
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func collectionScroll<Content: View>(
        @ViewBuilder content: @escaping (CGFloat) -> Content
    ) -> some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 8) {
                    content(geometry.size.height)
                }
                .padding(.horizontal, 8)
                .padding(.top, 8)
                .padding(.bottom, 150)
                .frame(minHeight: geometry.size.height, alignment: .top)
            }
            .defaultScrollAnchor(.bottom)
            .scrollIndicators(.hidden)
        }
    }

    private var itemCollections: some View {
        collectionScroll { height in
            MobileCollectionCard(
                key: "notes:inbox",
                minimumHeight: itemCollectionCount == 1 ? height : nil,
                icon: "tray",
                eyebrow: "LIBRARY",
                title: "Inbox",
                subtitle: "\(notes.count) notes"
            ) {
                Task { await model.showTopic("All") }
            }

            if model.query.isEmpty {
                MobileCollectionCard(
                    key: "notes:highlights",
                    icon: "highlighter",
                    eyebrow: "LIBRARY",
                    title: "Highlights",
                    subtitle: model.loadedHighlightCount.map { "\($0) highlights" } ?? "Open to load"
                ) {
                    model.showHighlights()
                    onOpenDetail()
                }
            }

            ForEach(topics, id: \.name) { topic in
                MobileCollectionCard(
                    key: "topic:\(topic.name)",
                    icon: "folder",
                    eyebrow: "TOPIC",
                    title: topic.name,
                    subtitle: "\(topic.count) notes"
                ) {
                    Task { await model.showTopic(topic.name) }
                }
            }

            if model.query.isEmpty || !trashNotes.isEmpty {
                MobileCollectionCard(
                    key: "notes:trash",
                    icon: "trash",
                    eyebrow: "LIBRARY",
                    title: "Trash",
                    subtitle: model.loadedTrashCount.map { "\($0) notes" } ?? "Open to load"
                ) {
                    model.showTrash()
                }
            }
        }
    }

    private var channelCollections: some View {
        collectionScroll { height in
            if channels.isEmpty {
                SidebarEmpty(
                    icon: "dot.radiowaves.left.and.right",
                    title: model.query.isEmpty ? "No channels yet" : "No matching channels"
                )
            } else {
                ForEach(channels) { channel in
                    MobileCollectionCard(
                        key: "channel:\(channel.source)",
                        palette: .channel,
                        minimumHeight: channels.count == 1 ? height : nil,
                        icon: channel.kind == .podcast
                            ? "waveform"
                            : "dot.radiowaves.left.and.right",
                        eyebrow: channelDomain(channel.primarySource).uppercased(),
                        title: channel.title,
                        subtitle: "\(model.channelEntries(for: channel.source).count) notes",
                        settingsLabel: "Settings for \(channel.title)",
                        settingsAction: {
                            model.showChannelSettings(channel.source)
                            onOpenDetail()
                        }
                    ) {
                        model.selectChannel(channel.source)
                    }
                }
            }
        }
    }

    private var briefCollections: some View {
        collectionScroll { height in
            if briefs.isEmpty {
                SidebarEmpty(
                    icon: "headphones",
                    title: model.query.isEmpty ? "No voice briefs yet" : "No matching voice briefs"
                )
            } else {
                ForEach(briefs, id: \.id) { brief in
                    MobileCollectionCard(
                        key: "brief:\(brief.id)",
                        palette: .brief,
                        minimumHeight: briefs.count == 1 ? height : nil,
                        icon: "headphones",
                        eyebrow: "VOICE BRIEF",
                        title: brief.title,
                        subtitle: "\(model.projection.episodes(for: brief.id).count) episodes",
                        settingsLabel: "Settings for \(brief.title)",
                        settingsAction: {
                            model.showVoiceBriefSettings(brief.id)
                            onOpenDetail()
                        }
                    ) {
                        model.selectVoiceBrief(brief.id)
                    }
                }
            }
        }
    }

    private var entryCollection: some View {
        VStack(spacing: 0) {
            MobileCollectionHeader(title: collectionTitle, count: entries.count) {
                Task { await model.show(model.activeSection) }
            }

            if entries.isEmpty {
                SidebarEmpty(icon: "doc.text", title: emptyTitle)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            } else {
                GeometryReader { geometry in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(entries) { entry in
                                entryCard(entry)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.top, 8)
                        .padding(.bottom, 150)
                        .frame(
                            maxWidth: .infinity,
                            minHeight: geometry.size.height,
                            alignment: .top
                        )
                    }
                    .defaultScrollAnchor(.bottom)
                    .scrollIndicators(.hidden)
                }
            }
        }
    }

    @ViewBuilder
    private func entryCard(_ entry: LibraryEntry) -> some View {
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

private struct MobileCollectionHeader: View {
    let title: String
    let count: Int
    let back: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: back) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 15, weight: .bold))
                    .frame(width: 44, height: 44)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .mobileGlass(in: Circle())
            .accessibilityLabel("Back to collections")

            Text(title)
                .font(.title3.weight(.bold))
                .lineLimit(1)
            Spacer(minLength: 4)
            Text(count.formatted())
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 4)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }
}

private struct MobileCollectionCard: View {
    let key: String
    var palette: GrainyGradientPalette = .item
    var minimumHeight: CGFloat? = nil
    let icon: String
    let eyebrow: String
    let title: String
    let subtitle: String
    var settingsLabel = "Settings"
    var settingsAction: (() -> Void)?
    let action: () -> Void

    var body: some View {
        GrainyCard(palette: palette, variationKey: key) {
            ZStack(alignment: .topTrailing) {
                Button(action: action) {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(eyebrow, systemImage: icon)
                            .font(.system(size: 10, weight: .bold))
                            .tracking(0.5)
                        Text(title)
                            .font(.title2.weight(.bold))
                            .lineLimit(2)
                        Text(subtitle)
                            .font(.caption.weight(.semibold))
                            .lineLimit(3)
                            .opacity(0.85)
                    }
                    .foregroundStyle(.white)
                    .frame(
                        maxWidth: .infinity,
                        minHeight: minimumHeight ?? 132,
                        alignment: .topLeading
                    )
                    .padding(14)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if let settingsAction {
                    Button(action: settingsAction) {
                        Image(systemName: "gearshape")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.primary)
                            .frame(width: 34, height: 34)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .background(.primary.opacity(0.06), in: Circle())
                    .padding(12)
                    .accessibilityLabel(settingsLabel)
                }
            }
        }
    }
}

#endif

private enum GrainyGradientPalette {
    case item
    case channel
    case brief
}

private struct GrainyCard<Content: View>: View {
    let content: Content

    init(
        palette: GrainyGradientPalette,
        variationKey: String,
        @ViewBuilder content: () -> Content
    ) {
        self.content = content()
    }

    var body: some View {
        content
            .frame(
                maxWidth: .infinity,
                maxHeight: .infinity,
                alignment: .topLeading
            )
            .background {
                ZStack {
                    Rectangle()
                        .fill(.ultraThinMaterial)
                        .opacity(0.78)
                    Color.primary.opacity(0.018)
                }
            }
            .clipShape(
                RoundedRectangle(
                    cornerRadius: cardCornerRadius,
                    style: .continuous
                )
            )
            .overlay {
                RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous)
                    .stroke(.primary.opacity(0.11))
            }
            #if os(macOS)
            .shadow(color: .black.opacity(0.12), radius: 7, y: 3)
            #else
            .shadow(color: .black.opacity(0.12), radius: 12, y: 5)
            #endif
    }

    private var cardCornerRadius: CGFloat {
        #if os(macOS)
        11
        #else
        20
        #endif
    }
}

private struct GrainyEntryCard: View {
    let entry: LibraryEntry
    let paletteOverride: GrainyGradientPalette?
    let selected: Bool
    let minimumHeight: CGFloat?
    let featured: Bool
    let action: () -> Void

    private var palette: GrainyGradientPalette {
        paletteOverride ?? (entry.voiceBriefID == nil ? .item : .brief)
    }

    init(
        entry: LibraryEntry,
        palette: GrainyGradientPalette? = nil,
        selected: Bool = false,
        minimumHeight: CGFloat? = nil,
        featured: Bool = false,
        action: @escaping () -> Void
    ) {
        self.entry = entry
        self.paletteOverride = palette
        self.selected = selected
        self.minimumHeight = minimumHeight
        self.featured = featured
        self.action = action
    }

    private var cardMinimumHeight: CGFloat? {
        if let minimumHeight { return minimumHeight }
        #if os(macOS)
        return nil
        #else
        return 132
        #endif
    }

    private var dateText: String? {
        guard
            let value = entry.createdAt ?? entry.updatedAt,
            let date = try? Date(value, strategy: .iso8601)
        else { return nil }
        return date.formatted(
            .relative(presentation: .named, unitsStyle: .abbreviated)
        )
    }

    var body: some View {
        GrainyCard(palette: palette, variationKey: entry.id) {
            Button(action: action) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .top, spacing: 8) {
                        Text(entry.title)
                            .font(cardTitleFont)
                            .lineLimit(3)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        if let dateText {
                            Text(dateText)
                                .font(.system(size: 10, weight: .medium))
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                                .opacity(0.85)
                        }
                    }

                    if !entry.excerpt.isEmpty {
                        Text(entry.excerpt)
                            .font(.system(size: featured ? 13 : 12, weight: .regular))
                            .lineLimit(featured ? 5 : 4)
                            .multilineTextAlignment(.leading)
                            .opacity(0.85)
                    }
                }
                .foregroundStyle(.primary)
                .frame(
                    maxWidth: .infinity,
                    minHeight: cardMinimumHeight,
                    alignment: .topLeading
                )
                .padding(featured ? 22 : 18)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .overlay {
            RoundedRectangle(cornerRadius: selectionCornerRadius, style: .continuous)
                .stroke(
                    selected ? .white.opacity(0.7) : .clear,
                    lineWidth: selected ? 2 : 0
                )
        }
    }

    private var cardTitleFont: Font {
        #if os(macOS)
        .system(size: featured ? 21 : 16, weight: .semibold)
        #else
        .title2.weight(.bold)
        #endif
    }

    private var selectionCornerRadius: CGFloat {
        #if os(macOS)
        11
        #else
        20
        #endif
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
    Dictionary(grouping: channels, by: { channelDomain($0.primarySource) })
        .map { domain, channels in
            ChannelDomainGroup(
                domain: domain,
                channels: channels.sorted {
                    $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
                }
            )
        }
        .sorted {
            $0.channels.count != $1.channels.count
                ? $0.channels.count > $1.channels.count
                : $0.domain.localizedCaseInsensitiveCompare($1.domain) == .orderedAscending
        }
}

private func channelDomain(_ source: String) -> String {
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

private struct SidebarRow: View {
    let icon: String
    let title: String
    var count: Int? = nil
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
        if selected {
            row.macLiquidGlass(
                in: RoundedRectangle(cornerRadius: 9, style: .continuous),
                tint: Color(red: 0.43, green: 0.34, blue: 0.21).opacity(0.44),
                interactive: true
            )
        } else {
            row
        }
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
                if let count {
                    Text(count.formatted())
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .frame(minHeight: 24)
                        .background(Color.primary.opacity(0.055), in: Capsule())
                        .accessibilityLabel("\(count) items")
                }
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
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(rowBackgroundColor)
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

    private var rowBackgroundColor: Color {
        #if os(iOS)
        selected
            ? Color(red: 0.38, green: 0.10, blue: 0.72).opacity(0.34)
            : .clear
        #else
        .clear
        #endif
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
                    confirmsTrash = true
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
            model.selectionCount(for: entry.id) > 1
                ? "Move \(model.selectionCount(for: entry.id)) items to Trash?"
                : "Move this item to Trash?",
            isPresented: $confirmsTrash
        ) {
            Button("Move to Trash", role: .destructive) {
                Task { await model.trash(entryID: entry.id) }
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
        .padding(.top, 12)
    }
}

private struct LibraryDetail: View {
    @Bindable var model: LibraryModel
    @Binding var showsChannelBrowser: Bool
    @Bindable var audioPlayer: NativeAudioPlayer
    @Binding var audioEntry: LibraryEntry?

    var body: some View {
        Group {
            #if os(macOS)
            if model.showingHighlights {
                HighlightsDocument(model: model)
            } else if let entry = model.selectedEntry {
                LibraryDocument(
                    model: model,
                    entry: entry,
                    audioPlayer: audioPlayer,
                    audioEntry: $audioEntry
                )
            } else if model.activeSection == .briefs &&
                model.showingVoiceBriefSettings
            {
                VoiceBriefConfiguration(model: model)
            } else if model.activeSection == .channels &&
                model.showingChannelSettings
            {
                ChannelConfiguration(
                    model: model,
                    showsChannelBrowser: $showsChannelBrowser
                )
            } else {
                LibraryCardBrowser(model: model)
            }
            #else
            if model.showingHighlights {
                HighlightsDocument(model: model)
            } else if let entry = model.selectedEntry {
                LibraryDocument(
                    model: model,
                    entry: entry,
                    audioPlayer: audioPlayer,
                    audioEntry: $audioEntry
                )
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
            #endif
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        #if os(macOS)
        .background {
            ZStack {
                readerBackground.opacity(0.08)
                Rectangle()
                    .fill(.ultraThinMaterial)
                    .opacity(0.08)
            }
        }
        #else
        .background(readerBackground.ignoresSafeArea())
        #endif
    }

}

#if os(macOS)
private struct MasonryLayout: Layout {
    let minimumColumnWidth: CGFloat
    let maximumColumnWidth: CGFloat
    let spacing: CGFloat

    struct Cache {
        var frames = [CGRect]()
        var size = CGSize.zero
    }

    func makeCache(subviews: Subviews) -> Cache {
        Cache()
    }

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Cache
    ) -> CGSize {
        guard !subviews.isEmpty else {
            cache = Cache()
            return .zero
        }

        let availableWidth = max(
            1,
            proposal.width ?? maximumColumnWidth
        )
        let columnCount = max(
            1,
            Int(
                floor(
                    (availableWidth + spacing) /
                        (minimumColumnWidth + spacing)
                )
            )
        )
        let columnWidth = min(
            maximumColumnWidth,
            (availableWidth - CGFloat(columnCount - 1) * spacing) /
                CGFloat(columnCount)
        )
        var columnHeights = Array(repeating: CGFloat.zero, count: columnCount)
        var frames = Array(repeating: CGRect.zero, count: subviews.count)

        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(
                ProposedViewSize(width: columnWidth, height: nil)
            )
            let column = columnHeights.enumerated().min {
                if $0.element == $1.element {
                    return $0.offset < $1.offset
                }
                return $0.element < $1.element
            }?.offset ?? 0
            let origin = CGPoint(
                x: CGFloat(column) * (columnWidth + spacing),
                y: columnHeights[column]
            )
            frames[index] = CGRect(
                origin: origin,
                size: CGSize(width: columnWidth, height: size.height)
            )
            columnHeights[column] = origin.y + size.height + spacing
        }

        let height = max(0, (columnHeights.max() ?? 0) - spacing)
        cache.frames = frames
        cache.size = CGSize(width: availableWidth, height: height)
        return cache.size
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Cache
    ) {
        if cache.frames.count != subviews.count ||
            abs(cache.size.width - bounds.width) > 0.5
        {
            _ = sizeThatFits(
                proposal: ProposedViewSize(width: bounds.width, height: bounds.height),
                subviews: subviews,
                cache: &cache
            )
        }

        for index in subviews.indices {
            let frame = cache.frames[index]
            subviews[index].place(
                at: CGPoint(
                    x: bounds.minX + frame.minX,
                    y: bounds.minY + frame.minY
                ),
                anchor: .topLeading,
                proposal: ProposedViewSize(
                    width: frame.width,
                    height: nil
                )
            )
        }
    }
}

private struct BalancedTilingLayout: Layout {
    let minimumTileWidth: CGFloat
    let maximumColumns: Int
    let spacing: CGFloat
    let featuredCount: Int

    struct Cache {
        var frames = [CGRect]()
        var size = CGSize.zero
    }

    func makeCache(subviews: Subviews) -> Cache {
        Cache()
    }

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Cache
    ) -> CGSize {
        guard !subviews.isEmpty else {
            cache = Cache()
            return .zero
        }

        let availableWidth = max(1, proposal.width ?? minimumTileWidth)
        let rows = rowCounts(itemCount: subviews.count, width: availableWidth)
        var frames = Array(repeating: CGRect.zero, count: subviews.count)
        var itemIndex = 0
        var y = CGFloat.zero

        for (rowIndex, itemCount) in rows.enumerated() {
            let availableForTiles = availableWidth - CGFloat(itemCount - 1) * spacing
            let weights = rowWeights(count: itemCount, rowIndex: rowIndex)
            let totalWeight = weights.reduce(0, +)
            let widths = weights.map { availableForTiles * $0 / totalWeight }
            var measuredHeights = [CGFloat]()

            for offset in 0..<itemCount {
                let size = subviews[itemIndex + offset].sizeThatFits(
                    ProposedViewSize(width: widths[offset], height: nil)
                )
                measuredHeights.append(size.height)
            }

            let isFeaturedRow = rowIndex == 0 && featuredCount > 0 &&
                subviews.count >= 6
            let rowHeight = max(
                isFeaturedRow ? 262 : 164,
                measuredHeights.max() ?? 0
            )
            var x = CGFloat.zero

            for offset in 0..<itemCount {
                frames[itemIndex + offset] = CGRect(
                    x: x,
                    y: y,
                    width: widths[offset],
                    height: rowHeight
                )
                x += widths[offset] + spacing
            }

            itemIndex += itemCount
            y += rowHeight + spacing
        }

        cache.frames = frames
        cache.size = CGSize(width: availableWidth, height: max(0, y - spacing))
        return cache.size
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Cache
    ) {
        if cache.frames.count != subviews.count ||
            abs(cache.size.width - bounds.width) > 0.5
        {
            _ = sizeThatFits(
                proposal: ProposedViewSize(width: bounds.width, height: nil),
                subviews: subviews,
                cache: &cache
            )
        }

        for index in subviews.indices {
            let frame = cache.frames[index]
            subviews[index].place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: frame.width, height: frame.height)
            )
        }
    }

    private func rowCounts(itemCount: Int, width: CGFloat) -> [Int] {
        let preferred = max(
            2,
            min(
                maximumColumns,
                Int((width + spacing) / (minimumTileWidth + spacing))
            )
        )
        var remaining = itemCount
        var rows = [Int]()

        if featuredCount > 0 && itemCount >= 6 {
            let count = min(featuredCount, remaining)
            rows.append(count)
            remaining -= count
        }

        while remaining > 0 {
            if remaining <= preferred {
                rows.append(remaining)
                break
            }
            if remaining < preferred * 2 {
                let leading = Int(ceil(Double(remaining) / 2.0))
                rows.append(leading)
                rows.append(remaining - leading)
                break
            }
            rows.append(preferred)
            remaining -= preferred
        }
        return rows
    }

    private func rowWeights(count: Int, rowIndex: Int) -> [CGFloat] {
        let weights: [CGFloat] = switch count {
        case 2: [1.08, 0.92]
        case 3: rowIndex == 0 && featuredCount > 0
            ? [1.24, 1.0, 0.86]
            : [1.08, 0.92, 1.0]
        case 4: [1.08, 0.92, 1.04, 0.96]
        case 5: [1.06, 0.94, 1.02, 0.90, 1.08]
        case 6: [1.05, 0.95, 1.0, 1.04, 0.92, 1.04]
        default: Array(repeating: 1, count: count)
        }
        return rowIndex.isMultiple(of: 2) ? weights : Array(weights.reversed())
    }
}

private struct LibraryCardBrowser: View {
    @Bindable var model: LibraryModel

    private var channels: [LibraryChannel] {
        model.filteredChannels.filter {
            model.selectedChannelDomain == "All" ||
                channelDomain($0.primarySource) == model.selectedChannelDomain
        }
    }

    private var channelEntries: [LibraryEntry] {
        guard !model.selectedChannelSource.isEmpty else { return [] }
        return model.channelEntries(for: model.selectedChannelSource).filter {
            $0.matches(model.query)
        }
    }

    private var allChannelEntries: [LibraryEntry] {
        var seen = Set<String>()
        return channels
            .flatMap { model.channelEntries(for: $0.source) }
            .filter { seen.insert($0.id).inserted && $0.matches(model.query) }
            .sorted {
                ($0.createdAt ?? $0.updatedAt ?? "") >
                    ($1.createdAt ?? $1.updatedAt ?? "")
            }
    }

    private var voiceBriefEntries: [LibraryEntry] {
        model.projection.entries.filter {
            $0.entryType == "voice_brief_episode" &&
                (model.selectedVoiceBriefID.isEmpty ||
                    $0.voiceBriefID == model.selectedVoiceBriefID) &&
                $0.matches(model.query)
        }
        .sorted {
            ($0.createdAt ?? $0.updatedAt ?? "") >
                ($1.createdAt ?? $1.updatedAt ?? "")
        }
    }

    private var count: Int {
        switch model.activeSection {
        case .items: model.filteredEntries.count
        case .channels:
            model.selectedChannelSource.isEmpty ? allChannelEntries.count : channelEntries.count
        case .briefs:
            voiceBriefEntries.count
        }
    }

    private var feedEntries: [LibraryEntry]? {
        switch model.activeSection {
        case .items:
            model.filteredEntries
        case .channels:
            model.selectedChannelSource.isEmpty ? allChannelEntries : channelEntries
        case .briefs:
            voiceBriefEntries
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if count == 0 {
                    VStack(spacing: 0) {
                        feedHeader
                        XEmptyState(
                            icon: emptyIcon,
                            title: emptyTitle,
                            message: emptyDescription
                        )
                        .frame(minHeight: 360)
                    }
                    .frame(maxWidth: 680)
                    .frame(maxWidth: .infinity, alignment: .top)
                } else {
                    browserContent
                }
            }
            .padding(.horizontal, 0)
            .padding(.top, 0)
            .padding(.bottom, 80)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.hidden)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.ultraThinMaterial.opacity(0.24))
    }

    @ViewBuilder
    private var browserContent: some View {
        if let feedEntries {
            feedColumn(feedEntries)
                .frame(maxWidth: 680)
                .frame(maxWidth: .infinity, alignment: .top)
        }
    }

    private var channelIndex: some View {
        LazyVStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Channels")
                        .font(.title2.weight(.bold))
                    Text("Sources you follow")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(channels.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(18)
            .background(.regularMaterial)

            Divider()

            ForEach(channels) { channel in
                HStack(spacing: 13) {
                    Image(
                        systemName: channel.kind == .podcast
                            ? "waveform"
                            : "dot.radiowaves.left.and.right"
                    )
                    .font(.system(size: 18, weight: .medium))
                    .frame(width: 42, height: 42)
                    .background(Color.primary.opacity(0.06), in: Circle())

                    VStack(alignment: .leading, spacing: 3) {
                        Text(channel.title)
                            .font(.callout.weight(.semibold))
                            .lineLimit(1)
                        Text(channelDomain(channel.primarySource))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Text("\(model.channelEntries(for: channel.source).count) saved notes")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 12)

                    Button {
                        model.showChannelSettings(channel.source)
                    } label: {
                        Image(systemName: "ellipsis")
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Settings for \(channel.title)")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 13)
                .contentShape(Rectangle())
                .onTapGesture { model.selectChannel(channel.source) }
                .overlay(alignment: .bottom) { Divider().padding(.leading, 70) }
            }
        }
        .background(.ultraThinMaterial.opacity(0.64))
        .overlay { Rectangle().stroke(Color.primary.opacity(0.10)) }
    }

    private func feedColumn(_ entries: [LibraryEntry]) -> some View {
        LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
            Section {
                ForEach(entries) { entry in
                    let row = FeedEntryRow(
                        entry: entry,
                        action: { Task { await model.select(entry.id) } }
                    )
                    if model.showingTrash {
                        row
                    } else {
                        row.modifier(EntryContextMenu(model: model, entry: entry))
                    }
                }
            } header: {
                feedHeader
            }
        }
    }

    private var feedHeader: some View {
        VStack(alignment: .leading, spacing: 0) {
            feedTabs

            if model.activeSection == .briefs, let brief = model.selectedVoiceBrief {
                briefRefreshPrompt(brief)
                    .padding(.horizontal, 14)
                    .padding(.top, 12)
            }

            Divider()
                .padding(.top, 12)
        }
        .background(.regularMaterial)
        .overlay(alignment: .topTrailing) {
            if model.activeSection != .items {
                feedHeaderAction
                    .padding(.top, 12)
                    .padding(.trailing, 10)
            }
        }
    }

    @ViewBuilder
    private var feedTabs: some View {
        switch model.activeSection {
        case .items:
            ScrollView(.horizontal) {
                HStack(spacing: 20) {
                    topicTab("All")
                    ForEach(Array(model.projection.documentTopics.prefix(7)), id: \.self) {
                        topicTab($0)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, 24)
            }
            .scrollIndicators(.hidden)
        case .channels:
            channelTabs
        case .briefs:
            briefTabs
        }
    }

    @ViewBuilder
    private var feedHeaderAction: some View {
        switch model.activeSection {
        case .items:
            EmptyView()
        case .channels:
            if let channel = model.selectedChannel {
                Button {
                    model.showChannelSettings(channel.source)
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(width: 44, height: 44)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .background(opaqueHeaderActionBackground, in: Circle())
                .help("Settings for \(channel.title)")
                .accessibilityLabel("Settings for \(channel.title)")
            } else {
                Button {
                    model.query = ""
                    model.showChannelSettings("new")
                } label: {
                    Image(systemName: "plus")
                        .frame(width: 44, height: 44)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .background(opaqueHeaderActionBackground, in: Circle())
                .help("New channel")
                .accessibilityLabel("New channel")
            }
        case .briefs:
            if let brief = model.selectedVoiceBrief {
                Button {
                    model.showVoiceBriefSettings(brief.id)
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(width: 44, height: 44)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .background(opaqueHeaderActionBackground, in: Circle())
                .help("Settings for \(brief.title)")
                .accessibilityLabel("Settings for \(brief.title)")
            } else {
                Button {
                    model.query = ""
                    model.showVoiceBriefSettings("new")
                } label: {
                    Image(systemName: "plus")
                        .frame(width: 44, height: 44)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .background(opaqueHeaderActionBackground, in: Circle())
                .help("New brief")
                .accessibilityLabel("New brief")
            }
        }
    }

    private var opaqueHeaderActionBackground: Color {
        Color(nsColor: .windowBackgroundColor)
    }

    private var channelTabs: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 20) {
                selectionTab("All", selected: model.selectedChannelSource.isEmpty) {
                    model.selectChannel("")
                }
                ForEach(Array(channels.prefix(7))) { channel in
                    selectionTab(
                        compactLabel(channel.title),
                        selected: model.selectedChannelSource == channel.source
                    ) {
                        model.selectChannel(channel.source)
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.trailing, 62)
            .padding(.top, 24)
        }
        .scrollIndicators(.hidden)
    }

    private var briefTabs: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 20) {
                selectionTab("All", selected: model.selectedVoiceBriefID.isEmpty) {
                    model.selectVoiceBrief("")
                }
                ForEach(Array(model.projection.voiceBriefDefinitions.prefix(7)), id: \.id) { brief in
                    selectionTab(
                        brief.title,
                        selected: model.selectedVoiceBriefID == brief.id
                    ) {
                        model.selectVoiceBrief(brief.id)
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.trailing, 62)
            .padding(.top, 24)
        }
        .scrollIndicators(.hidden)
    }

    private func selectionTab(
        _ title: String,
        selected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 16, weight: selected ? .semibold : .medium))
                    .foregroundStyle(selected ? .primary : .secondary)
                    .lineLimit(1)
                Capsule()
                    .fill(selected ? Color.accentColor : .clear)
                    .frame(height: 4)
            }
            .frame(minHeight: 44)
            .padding(.horizontal, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func topicTab(_ topic: String) -> some View {
        let selected = model.selectedTopic == topic
        return Button {
            Task { await model.showTopic(topic) }
        } label: {
            VStack(spacing: 8) {
                Text(topic)
                    .font(.system(size: 16, weight: selected ? .semibold : .medium))
                    .foregroundStyle(selected ? .primary : .secondary)
                    .lineLimit(1)
                Capsule()
                    .fill(selected ? Color.accentColor : .clear)
                    .frame(height: 4)
            }
            .frame(minHeight: 44)
            .padding(.horizontal, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func briefRefreshPrompt(_ brief: LibraryVoiceBrief) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 38, height: 38)
                .background(Color.primary.opacity(0.07), in: Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text("Ready for a fresh brief?")
                    .font(.callout.weight(.semibold))
                Text("Generate the latest episode from \(brief.sources.count) channels.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Button {
                Task { await model.runSelectedVoiceBrief() }
            } label: {
                if model.isRunningVoiceBrief {
                    ProgressView().controlSize(.small)
                        .frame(minWidth: 82)
                } else {
                    Text("Generate")
                        .font(.callout.weight(.semibold))
                        .frame(minWidth: 82)
                }
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .disabled(model.isRunningVoiceBrief || brief.sources.isEmpty)
        }
        .padding(12)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.primary.opacity(0.08))
        }
    }

    private var feedRail: some View {
        VStack(spacing: 14) {
            HStack(spacing: 9) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search your library", text: $model.query)
                    .textFieldStyle(.plain)
            }
            .padding(.horizontal, 14)
            .frame(height: 44)
            .background(.regularMaterial)
            .clipShape(Capsule())
            .overlay { Capsule().stroke(Color.primary.opacity(0.10)) }

            FeedRailCard(title: "Collections") {
                ForEach(Array(model.projection.documentTopics.prefix(6)), id: \.self) { topic in
                    Button {
                        Task { await model.showTopic(topic) }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "folder")
                                .foregroundStyle(.secondary)
                            Text(topic)
                                .lineLimit(1)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 5)
                    }
                    .buttonStyle(.plain)
                }
            }

            FeedRailCard(title: "Your library") {
                FeedMetric(label: "Saved notes", value: model.projection.entries.filter(\.isMainLibraryEntry).count)
                FeedMetric(label: "Channels", value: model.channels.count)
                FeedMetric(label: "Voice briefs", value: model.projection.voiceBriefDefinitions.count)
            }
        }
    }

    private var feedTitle: String {
        switch model.activeSection {
        case .items:
            model.showingTrash ? "Trash" : model.selectedTopic == "All" ? "For you" : model.selectedTopic
        case .channels:
            model.selectedChannel?.title ?? "Channel"
        case .briefs:
            model.selectedVoiceBrief?.title ?? "Briefs"
        }
    }

    @ViewBuilder
    private var desktopActions: some View {
        if model.activeSection == .channels,
            let channel = model.selectedChannel
        {
            HStack {
                Spacer()
                Button {
                    Task { await model.checkSelectedChannel() }
                } label: {
                    if model.isCheckingChannel {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Fetch fresh", systemImage: "arrow.clockwise")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isCheckingChannel)

                Button {
                    model.showChannelSettings(channel.source)
                } label: {
                    Image(systemName: "gearshape")
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("Settings for \(channel.title)")
                .help("Settings for \(channel.title)")
            }
        } else if model.activeSection == .briefs,
            let brief = model.selectedVoiceBrief
        {
            HStack {
                Spacer()
                Button {
                    Task { await model.runSelectedVoiceBrief() }
                } label: {
                    if model.isRunningVoiceBrief {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Generate fresh", systemImage: "sparkles")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isRunningVoiceBrief || brief.sources.isEmpty)

                Button {
                    model.showVoiceBriefSettings(brief.id)
                } label: {
                    Image(systemName: "gearshape")
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("Settings for \(brief.title)")
                .help("Settings for \(brief.title)")
            }
        }
    }

    @ViewBuilder
    private func noteCard(
        _ entry: LibraryEntry,
        minimumHeight: CGFloat? = nil,
        featured: Bool = false
    ) -> some View {
        let card = GrainyEntryCard(
            entry: entry,
            minimumHeight: minimumHeight,
            featured: featured,
            action: { Task { await model.select(entry.id) } }
        )
        if model.showingTrash {
            card
        } else {
            card.modifier(EntryContextMenu(model: model, entry: entry))
        }
    }

    private func channelCard(_ channel: LibraryChannel) -> some View {
        BrowserCard(
            action: { model.selectChannel(channel.source) },
            settingsAction: { model.showChannelSettings(channel.source) },
            settingsLabel: "Settings for \(channel.title)",
            palette: .channel,
            variationKey: channel.source
        ) {
            CardEyebrow(
                icon: channel.kind == .podcast
                    ? "waveform"
                    : "dot.radiowaves.left.and.right",
                title: channelDomain(channel.primarySource)
            )
            Text(channel.title)
                .font(.title3.weight(.semibold))
                .lineLimit(2)
            Text(channel.sources.joined(separator: " · "))
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)
            Label(
                "\(model.channelEntries(for: channel.source).count) notes",
                systemImage: "doc.text"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var emptyTitle: String {
        if !model.query.isEmpty { return "No matches" }
        return switch model.activeSection {
        case .items: model.showingTrash ? "Trash is empty" : "No notes yet"
        case .channels:
            model.selectedChannelSource.isEmpty ? "No channels yet" : "No notes yet"
        case .briefs:
            "No briefs yet"
        }
    }

    private var emptyIcon: String {
        switch model.activeSection {
        case .items: model.showingTrash ? "trash" : "doc.text"
        case .channels: "dot.radiowaves.left.and.right"
        case .briefs: "headphones"
        }
    }

    private var emptyDescription: String {
        if !model.query.isEmpty { return "Try another search." }
        return switch model.activeSection {
        case .items:
            model.showingTrash
                ? "Notes moved to Trash appear here."
                : "Add a note to start your library."
        case .channels:
            model.selectedChannelSource.isEmpty
                ? "Add a channel to follow its updates."
                : "New notes from this channel appear here."
        case .briefs:
            model.projection.voiceBriefDefinitions.isEmpty
                ? "Create a voice brief from your channels."
                : "Generated briefs appear here."
        }
    }
}

#endif

private struct FeedEntryRow: View {
    let entry: LibraryEntry
    let action: () -> Void

    private var sourceURL: URL? {
        entry.sourceURL.flatMap(URL.init(string:))
    }

    private var sourceName: String {
        if let sharedBy = entry.sharedByDisplayName, !sharedBy.isEmpty {
            return sharedBy
        }
        if let host = sourceURL?.host {
            return host.replacingOccurrences(of: "www.", with: "")
        }
        return entry.entryType == "voice_brief_episode" ? "Voice Brief" : "Briefly"
    }

    private var relativeDate: String? {
        guard
            let rawDate = entry.createdAt ?? entry.updatedAt,
            let date = try? Date(rawDate, strategy: .iso8601)
        else { return nil }
        return date.formatted(.relative(presentation: .named, unitsStyle: .abbreviated))
    }

    private var displayExcerpt: String {
        let excerpt = entry.excerpt.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = entry.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty,
            excerpt.lowercased().hasPrefix(title.lowercased())
        else { return excerpt }
        return String(excerpt.dropFirst(title.count))
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Text(sourceName)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                if let username = entry.sharedByUsername, !username.isEmpty {
                    Text("@\(username)")
                        .lineLimit(1)
                }
                if let relativeDate {
                    Text("·")
                    Text(relativeDate)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
            }
            .padding(.trailing, sourceURL == nil ? 0 : 40)
            .font(.callout)
            .foregroundStyle(.secondary)

            Text(entry.title)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            if !displayExcerpt.isEmpty {
                Text(displayExcerpt)
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .lineSpacing(2)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }

        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
        .overlay(alignment: .topTrailing) {
            if let sourceURL {
                Link(destination: sourceURL) {
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 14, weight: .medium))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Open original")
                .padding(.trailing, 6)
                .padding(.top, 2)
            }
        }
        .overlay(alignment: .bottom) {
            Divider()
        }
    }
}

#if os(macOS)
private struct FeedRailCard<Content: View>: View {
    let title: String
    let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial.opacity(0.72))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.primary.opacity(0.10))
        }
    }
}

private struct FeedMetric: View {
    let label: String
    let value: Int

    var body: some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value, format: .number)
                .fontWeight(.semibold)
        }
        .font(.callout)
        .padding(.vertical, 3)
    }
}

private struct BrowserCard<Content: View>: View {
    let palette: GrainyGradientPalette
    let variationKey: String
    let action: () -> Void
    let settingsAction: (() -> Void)?
    let settingsLabel: String
    let content: Content

    init(
        action: @escaping () -> Void,
        settingsAction: (() -> Void)? = nil,
        settingsLabel: String = "Settings",
        palette: GrainyGradientPalette = .item,
        variationKey: String = "",
        @ViewBuilder content: () -> Content
    ) {
        self.palette = palette
        self.variationKey = variationKey
        self.action = action
        self.settingsAction = settingsAction
        self.settingsLabel = settingsLabel
        self.content = content()
    }

    var body: some View {
        GrainyCard(palette: palette, variationKey: variationKey) {
            ZStack(alignment: .topTrailing) {
                Button(action: action) {
                    VStack(alignment: .leading, spacing: 10) {
                        content
                    }
                    .padding(.leading, 18)
                    .padding(.vertical, 18)
                    .padding(.trailing, settingsAction == nil ? 18 : 50)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                }
                .buttonStyle(.plain)

                if let settingsAction {
                    Button(action: settingsAction) {
                        Image(systemName: "gearshape")
                            .frame(width: 44, height: 44)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .macLiquidGlass(in: Circle(), interactive: true)
                    .padding(10)
                    .foregroundStyle(.primary)
                    .accessibilityLabel(settingsLabel)
                    .help(settingsLabel)
                }
            }
        }
    }
}

private struct CardEyebrow: View {
    let icon: String
    let title: String
    var date: String? = nil

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
            Text(title.uppercased())
                .lineLimit(1)
            Spacer(minLength: 6)
            if let date, let value = try? Date(date, strategy: .iso8601) {
                Text(
                    value.formatted(
                        .relative(presentation: .named, unitsStyle: .abbreviated)
                    )
                )
                .foregroundStyle(.tertiary)
            }
        }
        .font(.system(size: 10, weight: .bold))
        .tracking(0.4)
        .foregroundStyle(.secondary)
    }
}
#endif

private struct XEmptyState: View {
    let icon: String
    let title: String
    let message: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.title2.weight(.bold))
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: 360, alignment: .leading)
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }
}

private struct XLoadingState: View {
    let title: String
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ProgressView()
                .controlSize(.small)
            Text(title)
                .font(.headline)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: 360, alignment: .leading)
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }
}

private struct HighlightsDocument: View {
    @Bindable var model: LibraryModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Highlights")
                        .font(.title2.weight(.bold))
                    Text("Passages saved from your library")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(18)
            .background(.regularMaterial)

            Divider()

            GeometryReader { geometry in
                if model.highlightsText.isEmpty {
                    XEmptyState(
                        icon: "highlighter",
                        title: "No highlights yet",
                        message: "Select a passage in any document, then choose Highlight."
                    )
                } else {
                    ScrollView {
                        MarkdownArticle(model.highlightsText)
                            .frame(maxWidth: 620, alignment: .leading)
                            .padding(.horizontal, 28)
                            .padding(.top, 34)
                            .padding(.bottom, 80)
                            .frame(maxWidth: .infinity)
                            .frame(minHeight: geometry.size.height, alignment: .top)
                    }
                }
            }
        }
        .frame(maxWidth: 680)
        .frame(maxWidth: .infinity, alignment: .top)
        .background(.ultraThinMaterial.opacity(0.64))
        .overlay { Rectangle().stroke(Color.primary.opacity(0.10)) }
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
            isEditable: model.canEdit && !model.showingTrash && isEditing,
            highlightedPassages: highlightedPassages,
            onHighlight: model.canEdit && !model.showingTrash ? { text in
                Task { await model.addHighlight(text) }
            } : nil,
            onRemoveHighlight: model.canEdit && !model.showingTrash ? { text in
                Task { await model.removeHighlight(text) }
            } : nil
        )
        .onChange(of: sourceText) { oldValue, newValue in
            if draft == oldValue { draft = newValue }
        }
        .onChange(of: draft) {
            guard model.canEdit, !model.showingTrash, isEditing, draft != sourceText else {
                return
            }
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

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        textContainerInset = NSSize(
            width: max(32, (newSize.width - 780) / 2),
            height: 90
        )
    }

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
    @Binding var audioEntry: LibraryEntry?
    @State private var isEditing = false
    @State private var showsSharing = false

    var body: some View {
        VStack(spacing: 0) {
            #if os(macOS)
            HStack(spacing: 12) {
                Button {
                    Task { await model.select("") }
                } label: {
                    Image(systemName: "arrow.left")
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .contentShape(Circle())

                Spacer()
                Menu {
                    Button("Regenerate summaries", systemImage: "arrow.clockwise") {
                        Task { await model.processSelected() }
                    }
                    .disabled(model.isProcessing)
                    Button("Move to Trash", systemImage: "trash", role: .destructive) {
                        Task { await model.trashSelected() }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
            .padding(.horizontal, 14)
            .frame(height: 56)
            .background(.regularMaterial)
            Divider()
            #endif

            ZStack(alignment: .bottom) {
            if model.isLoadingText {
                XLoadingState(
                    title: "Loading post",
                    message: "Fetching the saved document and its reading variants."
                )
            } else if model.selectedText.isEmpty && !model.canEdit {
                XEmptyState(
                    icon: "icloud.slash",
                    title: "Document unavailable",
                    message: "Sync the library to download this document."
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
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .id("\(entry.id):\(model.selectedVariant.rawValue)")
            }

            HStack(alignment: .bottom, spacing: 0) {
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
                    #if os(iOS)
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
                    #endif
                }

                #if os(iOS)
                Spacer()
                #else
                Spacer(minLength: 12)
                #endif

                HStack(spacing: 0) {
                    if model.canEdit && !model.showingTrash {
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

                    if !usesMobileVoiceBriefControls && !usesMobileItemControls {
                        Button {
                            Task {
                                let variant = model.selectedVariant
                                let text = model.selectedText
                                let playbackID = model.audioPlaybackID(
                                    for: entry,
                                    variant: variant,
                                    text: text
                                )
                                do {
                                    let shouldGenerate = try audioPlayer.startStream(
                                        entryID: entry.id,
                                        title: entry.title,
                                        playbackID: playbackID,
                                        positionID: "\(entry.id):\(variant.rawValue)"
                                    )
                                    if shouldGenerate {
                                        var startedPlayback = false
                                        _ = await model.streamPlayableAudio(
                                            for: entry,
                                            variant: variant,
                                            text: text
                                        ) { url in
                                            try audioPlayer.appendSegment(
                                                url,
                                                playbackID: playbackID
                                            )
                                            if !startedPlayback {
                                                startedPlayback = true
                                                audioEntry = entry
                                            }
                                        }
                                        audioPlayer.finishStream(playbackID: playbackID)
                                        if !startedPlayback { audioPlayer.stop() }
                                    } else {
                                        audioEntry = entry
                                    }
                                } catch {
                                    model.errorMessage = error.localizedDescription
                                    audioPlayer.stop()
                                }
                            }
                        } label: {
                            if model.isGeneratingSpeech {
                                ProgressView()
                                    .tint(.white)
                                    .frame(width: 44, height: 44)
                                    .background(Color.accentColor, in: Circle())
                            } else {
                                Image(systemName: "play.fill")
                                    .font(.system(size: 17, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .frame(width: 44, height: 44)
                                    .background(Color.accentColor, in: Circle())
                                    .contentShape(Circle())
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Play audio")
                        .help("Play audio")
                        .disabled(
                            model.isGeneratingSpeech || model.isRunningVoiceBrief ||
                                model.selectedText.isEmpty
                        )
                    }

                    if let source = entry.sourceURL, let url = URL(string: source) {
                        Link(destination: url) {
                            Image(systemName: "arrow.up.right")
                                .frame(width: 44, height: 44)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Open original source")
                    }

                    if !model.showingTrash &&
                        entry.origin != .shared &&
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
                #if os(iOS)
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
                #endif
            }
            #if os(macOS)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity)
            .frame(height: 58)
            .background(.regularMaterial)
            .overlay(alignment: .top) { Divider() }
            .frame(maxWidth: .infinity, alignment: .bottom)
            #endif
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        #if os(macOS)
        .frame(maxWidth: 680)
        .frame(maxWidth: .infinity, alignment: .top)
        .background(.ultraThinMaterial.opacity(0.64))
        .overlay { Rectangle().stroke(Color.primary.opacity(0.10)) }
        #else
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        #endif
        .onChange(of: entry.id) {
            isEditing = false
        }
        .contextMenu {
            if model.canEdit && !model.showingTrash {
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
        VStack(spacing: 0) {
            HStack {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Text("Share link")
                    .font(.headline)
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
            }
            .padding(.horizontal, 16)
            .frame(height: 54)
            Divider()

            VStack(alignment: .leading, spacing: 20) {
                Text(entry.title)
                    .font(.title3.weight(.bold))
                    .lineLimit(2)
                Text(
                    "Publish the available summaries. The private captured source text is never included."
                )
                .foregroundStyle(.secondary)

                if !model.account.authenticated {
                    Label(
                        "Sign in to your Briefly account in Settings before publishing.",
                        systemImage: "person.crop.circle.badge.exclamationmark"
                    )
                } else if let urlString = link?.url, let url = URL(string: urlString) {
                    Text(url.absoluteString)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 10))
                    HStack {
                        Button("Copy link", systemImage: "doc.on.doc") {
                            copyShareURL(url)
                        }
                        ShareLink(item: url) {
                            Label("Share…", systemImage: "square.and.arrow.up")
                        }
                        Spacer()
                        Button("Stop sharing", role: .destructive) {
                            Task { await revoke() }
                        }
                    }
                } else if link?.shared == true {
                    Label("The shareable reader is being prepared.", systemImage: "clock")
                } else {
                    Button("Create share link", systemImage: "link.badge.plus") {
                        Task { await publish() }
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
                    .disabled(isBusy)
                }

                if !errorMessage.isEmpty {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(.regularMaterial)
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
                        .font(.system(size: 30, weight: .bold))

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
                            Text("\(model.channels.count(where: isChannelSelected)) selected")
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
                                        toggleChannel(channel)
                                    } label: {
                                        HStack(spacing: 11) {
                                            Image(
                                                systemName: isChannelSelected(channel)
                                                    ? "checkmark.circle.fill"
                                                    : "circle"
                                            )
                                            .foregroundStyle(
                                                isChannelSelected(channel)
                                                    ? Color.accentColor
                                                    : Color.secondary
                                            )
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(channel.title)
                                                    .font(.system(size: 13, weight: .semibold))
                                                Text(channel.sources.joined(separator: " · "))
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
                                        isChannelSelected(channel)
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

                    ScheduleEditor(schedule: $schedule)
                    LabeledField(
                        label: "Length",
                        placeholder: "about 5 minutes",
                        value: $length
                    )

                    HStack {
                        if model.selectedVoiceBrief != nil {
                            Button("Move voice brief to Trash", role: .destructive) {
                                confirmsTrash = true
                            }
                        }
                        Spacer()
                    }
                }
                .padding(24)
                .frame(maxWidth: 680, alignment: .leading)
                .background(.ultraThinMaterial.opacity(0.64))
                .overlay { Rectangle().stroke(Color.primary.opacity(0.10)) }
                .frame(maxWidth: .infinity, alignment: .top)
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
                XEmptyState(
                    icon: "headphones",
                    title: "No voice briefs",
                    message: "Create a voice brief to gather and synthesize channels."
                )
                .frame(maxWidth: 680)
                .background(.ultraThinMaterial.opacity(0.64))
                .overlay { Rectangle().stroke(Color.primary.opacity(0.10)) }
                .frame(maxWidth: .infinity, alignment: .top)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .safeAreaInset(edge: .top, spacing: 0) {
            if model.canEdit &&
                (model.selectedVoiceBrief != nil || model.selectedVoiceBriefID == "new")
            {
                HStack(spacing: 10) {
                    Button {
                        model.navigateBack()
                    } label: {
                        Image(systemName: "arrow.left")
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Text("Voice brief")
                        .font(.headline)
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
                                Label("Generate fresh", systemImage: "sparkles")
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
                .frame(maxWidth: 680)
                .background(.regularMaterial)
                .overlay { Rectangle().stroke(Color.primary.opacity(0.10)) }
                .frame(maxWidth: .infinity, alignment: .top)
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

    private func isChannelSelected(_ channel: LibraryChannel) -> Bool {
        !channel.sources.isEmpty && channel.sources.allSatisfy(selectedSources.contains)
    }

    private func toggleChannel(_ channel: LibraryChannel) {
        var selected = selectedSources
        if isChannelSelected(channel) {
            selected.subtract(channel.sources)
        } else {
            selected.formUnion(channel.sources)
        }
        sources = selected.sorted().joined(separator: "\n")
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

private enum ScheduleFrequency: String, CaseIterable, Identifiable {
    case daily
    case weekly

    var id: Self { self }
    var title: String { rawValue.capitalized }
}

private struct ScheduleEditor: View {
    @Binding var schedule: String

    private var isEnabled: Binding<Bool> {
        Binding(
            get: { schedule != "manual" },
            set: { enabled in
                schedule = enabled
                    ? scheduledValue(frequency: .daily, weekday: weekday, time: time)
                    : "manual"
            }
        )
    }

    private var frequency: ScheduleFrequency {
        schedule.hasPrefix("weekly ") ? .weekly : .daily
    }

    private var frequencyBinding: Binding<ScheduleFrequency> {
        Binding(
            get: { frequency },
            set: { schedule = scheduledValue(frequency: $0, weekday: weekday, time: time) }
        )
    }

    private var weekday: Int {
        guard schedule.hasPrefix("weekly ") else {
            return Calendar.current.component(.weekday, from: Date())
        }
        let code = schedule.split(separator: " ").dropFirst().first.map(String.init) ?? ""
        return ["sun", "mon", "tue", "wed", "thu", "fri", "sat"]
            .firstIndex(of: code).map { $0 + 1 } ?? Calendar.current.firstWeekday
    }

    private var weekdayBinding: Binding<Int> {
        Binding(
            get: { weekday },
            set: { schedule = scheduledValue(frequency: frequency, weekday: $0, time: time) }
        )
    }

    private var time: Date {
        let parts = schedule.split(separator: " ").last?
            .split(separator: ":").compactMap { Int($0) } ?? []
        guard parts.count == 2 else { return Date() }
        return Calendar.current.date(
            bySettingHour: parts[0],
            minute: parts[1],
            second: 0,
            of: Date()
        ) ?? Date()
    }

    private var timeBinding: Binding<Date> {
        Binding(
            get: { time },
            set: { schedule = scheduledValue(frequency: frequency, weekday: weekday, time: $0) }
        )
    }

    private var orderedWeekdays: [Int] {
        (0..<7).map { (($0 + Calendar.current.firstWeekday - 1) % 7) + 1 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle(isOn: isEnabled) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Schedule automatically")
                        .font(.headline)
                    Text("Leave this off to refresh only when you ask.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)

            if isEnabled.wrappedValue {
                Picker("Frequency", selection: frequencyBinding) {
                    ForEach(ScheduleFrequency.allCases) {
                        Text($0.title).tag($0)
                    }
                }
                if frequency == .weekly {
                    Picker("Weekday", selection: weekdayBinding) {
                        ForEach(orderedWeekdays, id: \.self) {
                            Text(Calendar.current.weekdaySymbols[$0 - 1]).tag($0)
                        }
                    }
                }
                DatePicker("Time", selection: timeBinding, displayedComponents: .hourAndMinute)
            }
        }
        .padding(14)
        .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
    }

    private func scheduledValue(
        frequency: ScheduleFrequency,
        weekday: Int,
        time: Date
    ) -> String {
        let components = Calendar.current.dateComponents([.hour, .minute], from: time)
        let value = String(format: "%02d:%02d", components.hour ?? 9, components.minute ?? 0)
        guard frequency == .weekly else { return "daily \(value)" }
        let code = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"][
            min(7, max(1, weekday)) - 1
        ]
        return "weekly \(code) \(value)"
    }
}

private struct ChannelConfiguration: View {
    @Bindable var model: LibraryModel
    @Binding var showsChannelBrowser: Bool
    @State private var source = ""
    @State private var channelTitle = ""
    @State private var retrievalCount = 5
    @State private var schedule = "manual"
    @State private var confirmsRemoval = false

    var body: some View {
        ScrollView {
            if model.selectedChannelSource == "new" {
                channelCreation
            } else if let channel = model.selectedChannel {
                #if os(macOS)
                VStack(alignment: .leading, spacing: 30) {
                    HStack(alignment: .top, spacing: 18) {
                        Image(
                            systemName: channel.kind == .podcast
                                ? "waveform"
                                : "dot.radiowaves.left.and.right"
                        )
                        .font(.system(size: 28, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 58, height: 58)
                        .background(Color.accentColor.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 14))

                        VStack(alignment: .leading, spacing: 6) {
                            Text("CHANNEL")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            TextField("Channel name", text: $channelTitle)
                                .textFieldStyle(.plain)
                                .font(.system(size: 28, weight: .bold))
                                .onSubmit(saveSettings)
                        }

                        Spacer(minLength: 20)

                        Button {
                            Task { await model.checkSelectedChannel() }
                        } label: {
                            if model.isCheckingChannel {
                                ProgressView().controlSize(.small)
                            } else {
                                Label("Fetch fresh", systemImage: "arrow.clockwise")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.isCheckingChannel)

                        Menu {
                            Button {
                                Task { await model.checkSelectedChannel(loadMore: true) }
                            } label: {
                                Label("Load more", systemImage: "arrow.down")
                            }
                            .disabled(model.isCheckingChannel || !channel.canLoadMore)
                            Button {
                                model.channelBrowserAddress = channel.primarySource
                                model.channelBrowserStagesSource = false
                                showsChannelBrowser = true
                            } label: {
                                Label("Sign in", systemImage: "person.crop.circle")
                            }
                            Divider()
                            Button("Remove channel", role: .destructive) {
                                confirmsRemoval = true
                            }
                        } label: {
                            Image(systemName: "ellipsis")
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        .accessibilityLabel("More channel actions")
                    }

                    Divider()

                    channelSourceEditor(listTitle: "Included sources", allowsOpening: true)

                    Grid(alignment: .leading, horizontalSpacing: 52, verticalSpacing: 6) {
                        GridRow {
                            Text("CAPTURED ITEMS")
                            Text("TYPE")
                            Text("LAST CHECKED")
                        }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        GridRow {
                            Text(model.channelEntries(for: channel.source).count.formatted())
                            Text(channel.kind?.rawValue.capitalized ?? "Not checked")
                            Text(channel.lastCheckedAt ?? "Never")
                        }
                        .font(.title3.weight(.semibold))
                    }

                    if let error = channel.error {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.callout)
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                    }

                    ScheduleEditor(schedule: $schedule)

                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Refresh depth")
                                .font(.headline)
                            Text("How many recent items Briefly gathers on each check.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Stepper(
                            "Items per check: \(retrievalCount)",
                            value: $retrievalCount,
                            in: 1...100
                        )
                        .fixedSize()
                    }

                    if !channel.briefTitles.isEmpty {
                        LabeledContent(
                            "Voice briefs",
                            value: channel.briefTitles.joined(separator: ", ")
                        )
                    }

                    Divider()
                    HStack {
                        Text("\(model.newChannelSources.count) " +
                             (model.newChannelSources.count == 1 ? "source" : "sources"))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Save changes", action: saveSettings)
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                            .disabled(
                                model.newChannelSources.isEmpty ||
                                    channelTitle.trimmingCharacters(
                                        in: .whitespacesAndNewlines
                                    ).isEmpty
                            )
                    }
                }
                .frame(maxWidth: 680, alignment: .leading)
                .padding(24)
                .background(.ultraThinMaterial.opacity(0.64))
                .overlay { Rectangle().stroke(Color.primary.opacity(0.10)) }
                .frame(maxWidth: .infinity, alignment: .top)
                #else
                ConfigurationCard(
                    eyebrow: "CHANNEL",
                    title: "Channel settings",
                    description: "Edit this channel's name, sources, and refresh settings."
                ) {
                    TextField("Channel name", text: $channelTitle)
                        .font(.system(size: 28, weight: .bold))
                        .onSubmit(saveSettings)
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
                    channelSourceEditor(listTitle: "Included sources", allowsOpening: true)
                    ScheduleEditor(schedule: $schedule)
                    Stepper(
                        "Items per check: \(retrievalCount)",
                        value: $retrievalCount,
                        in: 1...100
                    )
                    HStack {
                        Button {
                            Task { await model.checkSelectedChannel() }
                        } label: {
                            if model.isCheckingChannel {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Label("Fetch fresh", systemImage: "arrow.clockwise")
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
                        Text("\(model.newChannelSources.count) " +
                             (model.newChannelSources.count == 1 ? "source" : "sources"))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Save changes", action: saveSettings)
                            .buttonStyle(.borderedProminent)
                            .disabled(
                                model.newChannelSources.isEmpty ||
                                    channelTitle.trimmingCharacters(
                                        in: .whitespacesAndNewlines
                                    ).isEmpty
                            )
                    }
                    Divider()
                    Button("Remove channel", role: .destructive) {
                        confirmsRemoval = true
                    }
                }
                #endif
            } else {
                XEmptyState(
                    icon: "dot.radiowaves.left.and.right",
                    title: "No channels",
                    message: "Add a channel to gather new material."
                )
                .frame(maxWidth: 680)
                .background(.ultraThinMaterial.opacity(0.64))
                .overlay { Rectangle().stroke(Color.primary.opacity(0.10)) }
                .frame(maxWidth: .infinity, alignment: .top)
            }
        }
        #if os(macOS)
        .safeAreaInset(edge: .top, spacing: 0) {
            HStack(spacing: 12) {
                Button {
                    model.navigateBack()
                } label: {
                    Image(systemName: "arrow.left")
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Text(model.selectedChannelSource == "new" ? "Add channel" : "Channel")
                    .font(.headline)
                Spacer()
            }
            .padding(.horizontal, 14)
            .frame(height: 56)
            .frame(maxWidth: 680)
            .background(.regularMaterial)
            .overlay { Rectangle().stroke(Color.primary.opacity(0.10)) }
            .frame(maxWidth: .infinity, alignment: .top)
        }
        #endif
        .task(id: model.selectedChannelSource) {
            source = ""
            retrievalCount = model.selectedChannel?.retrievalCount ?? 5
            schedule = model.selectedChannel?.schedule ?? "manual"
            channelTitle = model.selectedChannel?.title ?? ""
            model.newChannelSources = model.selectedChannelSource == "new"
                ? []
                : model.selectedChannel?.sources ?? []
            model.channelBrowserAddress = ""
            model.channelBrowserStagesSource = model.selectedChannelSource == "new"
        }
        .confirmationDialog("Delete this channel?", isPresented: $confirmsRemoval) {
            Button("Delete Channel and Items", role: .destructive) {
                Task { await model.removeSelectedChannel() }
            }
        } message: {
            let count = model.selectedChannel.map {
                model.channelEntries(for: $0.source).count
            } ?? 0
            Text(
                count == 1
                    ? "The channel and its 1 downloaded item will be moved to Trash."
                    : "The channel and its \(count) downloaded items will be moved to Trash."
            )
        }
    }

    private var channelCreation: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text("CHANNEL")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .tracking(1.2)
                Text("Add channel")
                    .font(.system(size: 32, weight: .bold))
                Text("Add websites, blogs, podcasts, profiles, or pages to this channel.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Divider().padding(.vertical, 26)

            channelSourceEditor(listTitle: "Added sources", allowsOpening: false)

            Spacer(minLength: 38)
            Divider()
            HStack {
                Text("\(model.newChannelSources.count) " +
                     (model.newChannelSources.count == 1 ? "source" : "sources") + " added")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") {
                    model.newChannelSources = []
                    model.navigateBack()
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                Button("Create channel") {
                    Task { await model.createChannel() }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(model.newChannelSources.isEmpty)
            }
            .padding(.top, 22)
        }
        .frame(maxWidth: 920, minHeight: 620, alignment: .topLeading)
        .padding(28)
        #if os(macOS)
        .background(.ultraThinMaterial.opacity(0.58))
        .overlay { Rectangle().stroke(Color.primary.opacity(0.10)) }
        #endif
        .frame(maxWidth: .infinity, alignment: .top)
    }

    private func addSource() {
        model.stageChannelSource(source)
        source = ""
    }

    @ViewBuilder
    private func channelSourceEditor(
        listTitle: String,
        allowsOpening: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Sources")
                .font(.headline)
            HStack(spacing: 12) {
                Image(systemName: "link")
                    .foregroundStyle(.secondary)
                TextField("Paste a domain or URL", text: $source)
                    .textFieldStyle(.plain)
                    .autocorrectionDisabled()
                    .onSubmit(addSource)
            }
            .padding(.horizontal, 16)
            .frame(height: 48)
            .background(.primary.opacity(0.025))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(.primary.opacity(0.16), lineWidth: 1)
            }
            Text("Add by domain or URL, or choose a page in the browser.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                Spacer()
                Button {
                    model.channelBrowserAddress = ""
                    model.channelBrowserStagesSource = true
                    showsChannelBrowser = true
                } label: {
                    Label("Open signed-in browser", systemImage: "globe")
                }
                .buttonStyle(.bordered)
                .controlSize(.large)

                Button(action: addSource) {
                    Label("Add source", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.top, 4)
        }

        if !model.newChannelSources.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                Text(listTitle)
                    .font(.headline)
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 250), spacing: 12)],
                    alignment: .leading,
                    spacing: 12
                ) {
                    ForEach(model.newChannelSources, id: \.self) { source in
                        ChannelSourceCard(
                            source: source,
                            openInBrowser: allowsOpening ? {
                                model.channelBrowserAddress = source
                                model.channelBrowserStagesSource = false
                                showsChannelBrowser = true
                            } : nil,
                            remove: {
                                model.removeStagedChannelSource(source)
                            }
                        )
                    }
                }
            }
            .padding(.top, 38)
        }
    }

    private func saveSettings() {
        Task {
            await model.updateSelectedChannel(
                title: channelTitle,
                sources: model.newChannelSources,
                retrievalCount: retrievalCount,
                schedule: schedule
            )
        }
    }
}

private struct ChannelSourceCard: View {
    let source: String
    let openInBrowser: (() -> Void)?
    let remove: () -> Void

    private var displaySource: String {
        guard let url = URL(string: source) else { return source }
        let host = url.host?.replacingOccurrences(of: "www.", with: "") ?? source
        let path = url.path == "/" ? "" : url.path
        return host + path
    }

    private var symbol: String {
        guard let host = URL(string: source)?.host?.lowercased() else { return "globe" }
        if host.contains("youtube") { return "play.fill" }
        if host.contains("podcast") || host.contains("spotify") { return "waveform" }
        if host == "x.com" || host.hasSuffix("twitter.com") { return "at" }
        if host.contains("reddit") { return "bubble.left.and.bubble.right.fill" }
        return "globe"
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 36, height: 36)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
            Text(displaySource)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            if let openInBrowser {
                Button(action: openInBrowser) {
                    Image(systemName: "globe")
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Open \(displaySource) in browser")
            }
            Button(action: remove) {
                Image(systemName: "xmark")
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel("Remove \(displaySource)")
        }
        .padding(.horizontal, 14)
        .frame(height: 58)
        .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(.primary.opacity(0.12), lineWidth: 1)
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
                .font(.system(size: 28, weight: .bold))
            Text(description)
                .font(.callout)
                .foregroundStyle(.secondary)
            Divider()
            content
        }
        .frame(maxWidth: 680, alignment: .leading)
        .padding(24)
        #if os(macOS)
        .background(.ultraThinMaterial.opacity(0.64))
        .overlay { Rectangle().stroke(Color.primary.opacity(0.10)) }
        #endif
        .frame(maxWidth: .infinity, alignment: .top)
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

#if os(macOS)
private struct MacXSettingsWorkspace: View {
    @AppStorage("BrieflyAppearance") private var appearance = "system"
    @AppStorage("BrieflySaveCapturedAudio") private var saveCapturedAudio = false
    @Bindable var model: LibraryModel
    @State private var selectedSection = BrieflySettingsSection.general
    @State private var query = ""
    @State private var captureShortcut = CaptureShortcut.load()
    @State private var shortcutRegistered = UserDefaults.standard.bool(
        forKey: "BrieflyCaptureShortcutRegistered"
    )
    @State private var showsChannelBrowser = false
    @State private var showsPDFImporter = false
    @State private var appleSignInNonce = ""

    private var filteredSections: [BrieflySettingsSection] {
        guard !query.isEmpty else { return BrieflySettingsSection.allCases }
        return BrieflySettingsSection.allCases.filter {
            $0.title.localizedCaseInsensitiveContains(query) ||
                subtitle(for: $0).localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            settingsIndex
                .frame(width: 390)

            settingsDetail
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .background(.ultraThinMaterial.opacity(0.48))
        .overlay { Rectangle().stroke(Color.primary.opacity(0.10)) }
        .fileImporter(isPresented: $showsPDFImporter, allowedContentTypes: [.pdf]) { result in
            switch result {
            case .success(let url):
                Task { await model.capturePDF(url) }
            case .failure(let error):
                model.errorMessage = error.localizedDescription
            }
        }
        .sheet(isPresented: $showsChannelBrowser) {
            ChannelLoginView()
        }
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
        .task {
            await model.refreshAccount()
            await model.loadSubscription()
        }
    }

    private var settingsIndex: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Settings")
                .font(.title2.weight(.bold))
                .padding(.horizontal, 18)
                .padding(.top, 17)
                .padding(.bottom, 14)

            HStack(spacing: 9) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search Settings", text: $query)
                    .textFieldStyle(.plain)
                if !query.isEmpty {
                    Button { query = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 13)
            .frame(height: 40)
            .background(Color.primary.opacity(0.055), in: Capsule())
            .overlay { Capsule().stroke(Color.primary.opacity(0.09)) }
            .padding(.horizontal, 14)
            .padding(.bottom, 10)

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(filteredSections) { section in
                        Button { selectedSection = section } label: {
                            HStack(spacing: 12) {
                                Image(systemName: section.icon)
                                    .frame(width: 22)
                                    .foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(section.title)
                                        .font(.callout.weight(.medium))
                                    Text(subtitle(for: section))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.horizontal, 16)
                            .frame(minHeight: 55)
                            .background(
                                selectedSection == section
                                    ? Color.primary.opacity(0.055)
                                    : .clear
                            )
                            .overlay(alignment: .trailing) {
                                Rectangle()
                                    .fill(selectedSection == section ? Color.accentColor : .clear)
                                    .frame(width: 3)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }

                    Divider().padding(.vertical, 8)
                    indexLink("Feedback", icon: "bubble.left.and.bubble.right", url: "https://www.readbriefly.fyi/feedback")
                    indexLink("Privacy Policy", icon: "hand.raised", url: "https://www.readbriefly.fyi/privacy")
                    indexLink("Terms of Use", icon: "doc.text", url: "https://www.readbriefly.fyi/terms")
                }
            }
        }
        .background(.ultraThinMaterial.opacity(0.42))
        .overlay(alignment: .trailing) { Divider() }
    }

    private var settingsDetail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(selectedSection.title)
                        .font(.title2.weight(.bold))
                    Text(detailSubtitle(for: selectedSection))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 14)

                Divider()
                detailContent
            }
        }
        .scrollIndicators(.hidden)
    }

    @ViewBuilder
    private var detailContent: some View {
        switch selectedSection {
        case .general:
            detailGroup("Display") {
                detailRow(icon: "circle.lefthalf.filled", title: "Appearance", subtitle: "Choose how Briefly looks on this Mac") {
                    Picker("", selection: $appearance) {
                        Text("System").tag("system")
                        Text("Light").tag("light")
                        Text("Dark").tag("dark")
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 210)
                }
            }

        case .library:
            detailGroup("Library") {
                valueRow(icon: "internaldrive", title: "Storage", value: "Local SQLite database")
                valueRow(icon: "checkmark.circle", title: "Status", value: model.status)
                actionRow(icon: "arrow.clockwise", title: "Refresh library", subtitle: "Reload all saved notes from local storage") {
                    Task { await model.refreshLibrary() }
                }
                actionRow(icon: "arrow.triangle.2.circlepath", title: model.isSyncing ? "Syncing…" : "Sync with iCloud", subtitle: "Push and pull the latest library changes") {
                    Task { await model.sync() }
                }
                .disabled(model.isSyncing)
            }

        case .capture:
            detailGroup("Capture") {
                detailRow(icon: "keyboard", title: "Global shortcut", subtitle: shortcutRegistered ? "Active system-wide" : "Choose another shortcut") {
                    ShortcutRecorder(shortcut: $captureShortcut)
                        .frame(width: 150, height: 30)
                }
                actionRow(icon: "clipboard", title: "Capture clipboard", subtitle: "Save the current clipboard as a note") {
                    let text = NSPasteboard.general.string(forType: .string) ?? ""
                    Task { await model.capture(text) }
                }
                .disabled(!model.canEdit)
                actionRow(icon: "doc.richtext", title: "Import PDF", subtitle: "Add and process a local PDF document") {
                    showsPDFImporter = true
                }
                .disabled(!model.canEdit)
                actionRow(icon: "globe", title: "Signed-in browser", subtitle: "Capture pages that require a login") {
                    showsChannelBrowser = true
                }
                detailRow(icon: "waveform", title: "Save captured YouTube audio", subtitle: "Applies to manual link captures") {
                    Toggle("", isOn: $saveCapturedAudio)
                        .labelsHidden()
                }
            }

        case .account:
            detailGroup("Your account") {
                valueRow(icon: "person.crop.circle", title: "Account", value: model.account.authenticated ? model.account.email ?? "Signed in" : "Signed out")
                if model.account.authenticated {
                    valueRow(icon: "checkmark.seal", title: "Membership", value: model.account.entitled == true ? "Active" : "Needs activation")
                    actionRow(icon: "arrow.clockwise", title: "Refresh account", subtitle: "Check membership and subscription status") {
                        Task { await model.refreshAccount(reportErrors: true) }
                    }
                    if model.account.entitled == true {
                        externalDetailRow(icon: "creditcard", title: "Manage App Store subscription", url: "https://apps.apple.com/account/subscriptions")
                    } else if let product = model.subscriptionProduct {
                        actionRow(icon: "sparkles", title: "Subscribe — \(product.displayPrice)/month", subtitle: "Unlock Briefly membership") {
                            Task { await model.purchaseSubscription() }
                        }
                    }
                    actionRow(icon: "arrow.counterclockwise", title: "Restore purchases", subtitle: "Restore an existing App Store subscription") {
                        Task { await model.restoreSubscription() }
                    }
                    actionRow(icon: "rectangle.portrait.and.arrow.right", title: "Sign out", subtitle: "Remove this account from the Mac", destructive: true) {
                        Task { await model.signOut() }
                    }
                } else {
                    SignInWithAppleButton(.signIn) { request in
                        let nonce = randomAppleNonce()
                        appleSignInNonce = nonce
                        request.requestedScopes = [.email]
                        request.nonce = SHA256.hash(data: Data(nonce.utf8))
                            .map { String(format: "%02x", $0) }
                            .joined()
                    } onCompletion: { result in
                        let nonce = appleSignInNonce
                        appleSignInNonce = ""
                        Task { await model.signInWithApple(result, nonce: nonce) }
                    }
                    .signInWithAppleButtonStyle(.black)
                    .frame(width: 260, height: 42)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 16)
                }
            }

        case .personalization:
            editorGroup(
                title: "Personalization",
                description: "Context used when Prioritize for me is enabled.",
                firstTitle: "About you",
                firstText: $model.aboutYou,
                secondTitle: "Voice brief prompt",
                secondText: $model.voiceBriefPrompt,
                restore: { model.voiceBriefPrompt = defaultVoiceBriefPrompt },
                save: model.savePersonalizationSettings
            )

        case .topics:
            detailGroup("Topics") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("One reusable topic per line, written as “id: Title”.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextEditor(text: $model.topicsText)
                        .font(.system(.body, design: .monospaced))
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 220)
                        .padding(10)
                        .background(Color.primary.opacity(0.04))
                        .overlay { Rectangle().stroke(Color.primary.opacity(0.10)) }
                    HStack {
                        Spacer()
                        Button("Save topics") { Task { await model.saveTopics() } }
                            .buttonStyle(.borderedProminent)
                            .buttonBorderShape(.capsule)
                    }
                }
                .padding(20)
            }

        case .ai:
            detailGroup("AI processing") {
                detailRow(icon: "sparkles", title: "Use Briefly AI", subtitle: "Managed processing with zero-data retention") {
                    Toggle("", isOn: Binding(get: { model.usesManagedAI }, set: model.useManagedAI))
                        .labelsHidden()
                }
                if !model.usesManagedAI {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Processing command")
                            .font(.callout.weight(.semibold))
                        TextField("Command", text: $model.processingCommand, axis: .vertical)
                            .textFieldStyle(.plain)
                            .padding(11)
                            .background(Color.primary.opacity(0.04))
                            .overlay { Rectangle().stroke(Color.primary.opacity(0.10)) }
                    }
                    .padding(20)
                    Divider().padding(.leading, 58)
                }
                VStack(alignment: .leading, spacing: 10) {
                    Text("Processing prompt")
                        .font(.callout.weight(.semibold))
                    TextEditor(text: $model.processingPrompt)
                        .font(.system(.caption, design: .monospaced))
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 230)
                        .padding(10)
                        .background(Color.primary.opacity(0.04))
                        .overlay { Rectangle().stroke(Color.primary.opacity(0.10)) }
                    HStack {
                        Button("Restore default") { model.processingPrompt = defaultProcessingPrompt }
                        Button("Test") { Task { await model.testProcessingCommand() } }
                            .disabled(model.isTestingAI)
                        Spacer()
                        Button("Save") { model.saveProcessingSettings() }
                            .buttonStyle(.borderedProminent)
                            .buttonBorderShape(.capsule)
                    }
                }
                .padding(20)
            }
        }
    }

    private func detailGroup<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.headline)
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 10)
            content()
        }
    }

    private func detailRow<Trailing: View>(
        icon: String,
        title: String,
        subtitle: String,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(spacing: 13) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.callout.weight(.medium))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            trailing()
        }
        .padding(.horizontal, 20)
        .frame(minHeight: 62)
        .overlay(alignment: .bottom) { Divider().padding(.leading, 57) }
    }

    private func valueRow(icon: String, title: String, value: String) -> some View {
        detailRow(icon: icon, title: title, subtitle: value) {
            Image(systemName: "chevron.right")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.tertiary)
        }
    }

    private func actionRow(
        icon: String,
        title: String,
        subtitle: String,
        destructive: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 13) {
                Image(systemName: icon)
                    .foregroundStyle(destructive ? Color.red : Color.secondary)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(destructive ? Color.red : Color.primary)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 20)
            .frame(minHeight: 62)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .bottom) { Divider().padding(.leading, 57) }
    }

    private func externalDetailRow(icon: String, title: String, url: String) -> some View {
        Link(destination: URL(string: url)!) {
            HStack(spacing: 13) {
                Image(systemName: icon).foregroundStyle(.secondary).frame(width: 24)
                Text(title).font(.callout.weight(.medium))
                Spacer()
                Image(systemName: "arrow.up.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 20)
            .frame(minHeight: 62)
        }
        .foregroundStyle(.primary)
        .overlay(alignment: .bottom) { Divider().padding(.leading, 57) }
    }

    private func editorGroup(
        title: String,
        description: String,
        firstTitle: String,
        firstText: Binding<String>,
        secondTitle: String,
        secondText: Binding<String>,
        restore: @escaping () -> Void,
        save: @escaping () -> Void
    ) -> some View {
        detailGroup(title) {
            VStack(alignment: .leading, spacing: 12) {
                Text(description).font(.caption).foregroundStyle(.secondary)
                Text(firstTitle).font(.callout.weight(.semibold))
                TextField(firstTitle, text: firstText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(3...7)
                    .padding(11)
                    .background(Color.primary.opacity(0.04))
                    .overlay { Rectangle().stroke(Color.primary.opacity(0.10)) }
                Text(secondTitle).font(.callout.weight(.semibold))
                TextEditor(text: secondText)
                    .font(.system(.caption, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 240)
                    .padding(10)
                    .background(Color.primary.opacity(0.04))
                    .overlay { Rectangle().stroke(Color.primary.opacity(0.10)) }
                HStack {
                    Button("Restore default", action: restore)
                    Spacer()
                    Button("Save", action: save)
                        .buttonStyle(.borderedProminent)
                        .buttonBorderShape(.capsule)
                }
            }
            .padding(20)
        }
    }

    private func indexLink(_ title: String, icon: String, url: String) -> some View {
        Link(destination: URL(string: url)!) {
            HStack(spacing: 12) {
                Image(systemName: icon).frame(width: 22).foregroundStyle(.secondary)
                Text(title).font(.callout.weight(.medium))
                Spacer()
                Image(systemName: "arrow.up.right")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 46)
        }
        .foregroundStyle(.primary)
    }

    private func subtitle(for section: BrieflySettingsSection) -> String {
        switch section {
        case .general: "Color scheme and display"
        case .library: "Storage, refresh, and iCloud"
        case .capture: "Shortcut, imports, and media"
        case .account: "Sign-in and subscription"
        case .personalization: "Your context and brief prompt"
        case .topics: "Reusable library topics"
        case .ai: "Provider, command, and prompt"
        }
    }

    private func detailSubtitle(for section: BrieflySettingsSection) -> String {
        switch section {
        case .general: "Manage how Briefly content is displayed to you."
        case .library: "Manage local storage, refresh, and synchronization."
        case .capture: "Choose how links and documents enter your library."
        case .account: "See account information and manage your membership."
        case .personalization: "Tell Briefly what matters to you."
        case .topics: "Manage the reusable topics applied to saved notes."
        case .ai: "Choose how Briefly processes and summarizes content."
        }
    }
}
#endif

private struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("BrieflyAppearance") private var appearance = "system"
    @AppStorage("BrieflySaveCapturedAudio") private var saveCapturedAudio = false
    #if os(macOS)
    @State private var captureShortcut = CaptureShortcut.load()
    @State private var shortcutRegistered = UserDefaults.standard.bool(
        forKey: "BrieflyCaptureShortcutRegistered"
    )
    #endif
    @Bindable var model: LibraryModel
    @State private var showsChannelBrowser = false
    @State private var appleSignInNonce = ""
    @State private var showsPDFImporter = false
    @State private var settingsQuery = ""
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
                .foregroundStyle(.secondary)
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
            VStack(alignment: .leading, spacing: 0) {
                Text("Settings")
                    .font(.title2.weight(.bold))
                    .padding(.horizontal, 18)
                    .padding(.top, 18)
                    .padding(.bottom, 14)

                HStack(spacing: 9) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Search Settings", text: $settingsQuery)
                        .textFieldStyle(.plain)
                    if !settingsQuery.isEmpty {
                        Button {
                            settingsQuery = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 13)
                .frame(height: 38)
                .background(Color.primary.opacity(0.055), in: Capsule())
                .overlay { Capsule().stroke(Color.primary.opacity(0.09)) }
                .padding(.horizontal, 14)
                .padding(.bottom, 10)

                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(filteredSettingsSections) { section in
                            Button {
                                selectedSection = section
                            } label: {
                                settingsNavigationRow(section)
                            }
                            .buttonStyle(.plain)
                        }

                        Divider().padding(.vertical, 8)

                        externalSettingsRow(
                            "Feedback",
                            icon: "bubble.left.and.bubble.right",
                            destination: "https://www.readbriefly.fyi/feedback"
                        )
                        .padding(.horizontal, 16)
                        externalSettingsRow(
                            "Privacy Policy",
                            icon: "hand.raised",
                            destination: "https://www.readbriefly.fyi/privacy"
                        )
                        .padding(.horizontal, 16)
                        externalSettingsRow(
                            "Terms of Use",
                            icon: "doc.text",
                            destination: "https://www.readbriefly.fyi/terms"
                        )
                        .padding(.horizontal, 16)
                    }
                }
            }
            .background(.ultraThinMaterial.opacity(0.56))
            .overlay { Rectangle().stroke(Color.primary.opacity(0.10)) }
            .navigationSplitViewColumnWidth(min: 370, ideal: 390, max: 410)
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
                        SyncActivityView(model: model)
                            .padding(.vertical, 4)
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
                        Label(
                            model.isSyncing ? "Syncing…" : "Sync with iCloud",
                            systemImage: "arrow.triangle.2.circlepath"
                        )
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
                Section("Media") {
                    Toggle("Save captured YouTube audio", isOn: $saveCapturedAudio)
                    Text("Applies to manual link captures. Podcast episode audio remains streamed from its source.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                    case .account:
                Section("Briefly account") {
                    LabeledContent(
                        "Status",
                        value: model.account.authenticated
                            ? model.account.email ?? "Signed in"
                            : "Signed out"
                    )
                    if model.account.authenticated {
                        LabeledContent(
                            "Membership",
                            value: model.account.entitled == true
                                ? "Active"
                                : "Needs activation"
                        )
                    }
                    HStack {
                        if model.account.authenticated {
                            Button("Sign out", role: .destructive) {
                                Task { await model.signOut() }
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
                    if model.account.authenticated {
                        if model.account.entitled == true {
                            Link(
                                "Manage App Store subscription",
                                destination: URL(string: "https://apps.apple.com/account/subscriptions")!
                            )
                        } else if let product = model.subscriptionProduct {
                            Button("Subscribe — \(product.displayPrice)/month") {
                                Task { await model.purchaseSubscription() }
                            }
                            .disabled(model.isPurchasingSubscription)
                        } else {
                            Text("The subscription is not available from the App Store yet.")
                                .foregroundStyle(.secondary)
                        }
                        Button("Restore purchases") {
                            Task { await model.restoreSubscription() }
                        }
                        .disabled(model.isPurchasingSubscription)
                    } else {
                        SignInWithAppleButton(.signIn) { request in
                            let nonce = randomAppleNonce()
                            appleSignInNonce = nonce
                            request.requestedScopes = [.email]
                            request.nonce = SHA256.hash(data: Data(nonce.utf8))
                                .map { String(format: "%02x", $0) }
                                .joined()
                        } onCompletion: { result in
                            let nonce = appleSignInNonce
                            appleSignInNonce = ""
                            Task { await model.signInWithApple(result, nonce: nonce) }
                        }
                        .signInWithAppleButtonStyle(.black)
                        .frame(maxWidth: 280, minHeight: 42, maxHeight: 42)
                        .accessibilityLabel("Sign in with Apple")
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
                    } else {
                        Text(
                            "Briefly AI via OpenRouter, covered by a zero-data-retention agreement."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    #else
                    Label("Briefly AI", systemImage: "sparkles")
                    Text(
                        "Briefly AI via OpenRouter, covered by a zero-data-retention agreement."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
                .scrollContentBackground(.hidden)
                .background(.ultraThinMaterial.opacity(0.72))
                .navigationTitle((selectedSection ?? .general).title)
                #if os(iOS)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
                #endif
            }
        }
        #if os(macOS)
        .toolbar(removing: .sidebarToggle)
        .toolbar(.hidden, for: .windowToolbar)
        #endif
        #if os(macOS)
        .background(.ultraThinMaterial.opacity(0.48))
        .overlay { Rectangle().stroke(Color.primary.opacity(0.10)) }
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
        .task {
            await model.refreshAccount()
            await model.loadSubscription()
        }
    }

    private var filteredSettingsSections: [BrieflySettingsSection] {
        guard !settingsQuery.isEmpty else { return availableSections }
        return availableSections.filter {
            $0.title.localizedCaseInsensitiveContains(settingsQuery)
        }
    }

    private func settingsNavigationRow(_ section: BrieflySettingsSection) -> some View {
        let selected = selectedSection == section
        return HStack(spacing: 12) {
            Image(systemName: section.icon)
                .frame(width: 22)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(section.title)
                    .font(.callout.weight(.medium))
                Text(settingsSubtitle(section))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 54)
        .background(selected ? Color.primary.opacity(0.055) : .clear)
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(selected ? Color.accentColor : .clear)
                .frame(width: 3)
        }
        .contentShape(Rectangle())
    }

    private func settingsSubtitle(_ section: BrieflySettingsSection) -> String {
        switch section {
        case .general: "Color scheme and display"
        case .library: "Storage, refresh, and iCloud"
        case .capture: "Shortcut, imports, and media"
        case .account: "Sign-in and subscription"
        case .personalization: "Your context and brief prompt"
        case .topics: "Reusable library topics"
        case .ai: "Provider, command, and prompt"
        }
    }
}

private func randomAppleNonce() -> String {
    var bytes = [UInt8](repeating: 0, count: 32)
    guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
        return UUID().uuidString
    }
    return Data(bytes).base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
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

private func compactLabel(_ value: String, maxLength: Int = 28) -> String {
    guard value.count > maxLength else { return value }
    return String(value.prefix(maxLength - 1)).trimmingCharacters(in: .whitespaces) + "…"
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
    dark: (0.018, 0.020, 0.030)
)

private let sidebarBackground = adaptiveColor(
    light: (0.975, 0.973, 0.965),
    dark: (0.026, 0.028, 0.043)
)

private let readerBackground = adaptiveColor(
    light: (0.986, 0.984, 0.976),
    dark: (0.022, 0.024, 0.038)
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
