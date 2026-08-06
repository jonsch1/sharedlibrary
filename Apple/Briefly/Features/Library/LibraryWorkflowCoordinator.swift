import BrieflyCore
import Foundation

@MainActor
final class LibrarySyncScheduler {
    enum Request {
        case lifecycle
        case library
    }

    private var pendingSync: Task<Void, Never>?
    private var pendingRequest: Request?
    private var operation: ((Request) async -> Void)?

    func setOperation(_ operation: @escaping (Request) async -> Void) {
        self.operation = operation
    }

    func requestLibrarySync() {
        request(.library)
    }

    func requestLifecycleSync() {
        request(.lifecycle)
    }

    private func request(_ request: Request) {
        if case .library = request {
            pendingRequest = request
        } else if pendingRequest == nil {
            pendingRequest = request
        }
        pendingSync?.cancel()
        pendingSync = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(900))
            guard !Task.isCancelled else { return }
            guard let self, let request = self.pendingRequest else { return }
            self.pendingRequest = nil
            await self.operation?(request)
        }
    }
}

@MainActor
final class LibraryWorkflowCoordinator {
    let session: LibrarySession
    let navigation: LibraryNavigationModel
    let selection: LibrarySelectionModel
    let channels: LibraryChannelModel
    let processing: LibraryProcessingModel
    let account: LibraryAccountModel
    let settings: LibrarySettingsModel
    let audio: LibraryAudioModel
    let lifecycle: LibraryLifecycleModel

    private let syncScheduler: LibrarySyncScheduler

    init(
        session: LibrarySession,
        navigation: LibraryNavigationModel,
        selection: LibrarySelectionModel,
        channels: LibraryChannelModel,
        processing: LibraryProcessingModel,
        account: LibraryAccountModel,
        settings: LibrarySettingsModel,
        audio: LibraryAudioModel,
        lifecycle: LibraryLifecycleModel
    ) {
        let syncScheduler = LibrarySyncScheduler()
        self.session = session
        self.navigation = navigation
        self.selection = selection
        self.channels = channels
        self.processing = processing
        self.account = account
        self.settings = settings
        self.audio = audio
        self.lifecycle = lifecycle
        self.syncScheduler = syncScheduler
        syncScheduler.setOperation { [weak self] request in
            switch request {
            case .lifecycle:
                await self?.lifecycle.sync()
            case .library:
                await self?.sync()
            }
        }
    }

    func start() async {
        guard lifecycle.beginStart() else { return }
        if session.environment.isUITesting {
            do {
                let databaseURL = try session.environment.prepareUITestLibrary()
                await openLibrary(databaseURL: databaseURL)
                await selection.loadSelectedText()
                session.status = "Ready for application tour"
            } catch {
                lifecycle.isReady = true
                session.errorMessage = error.localizedDescription
            }
            return
        }

        audio.beginLocalSpeechPreparation()
        if ProcessInfo.processInfo.arguments.contains("--demo") {
            session.projection = .demo
            session.status = "Showing the sample library"
            let section = selection.selectInitialContent()
            navigation.show(section)
            lifecycle.isReady = true
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

        async let selectedText: Void = selection.loadSelectedText()
        async let accountRefresh: Void = account.refreshAccount()
        if session.library != nil {
            async let cloudSync: Void = sync()
            _ = await (selectedText, accountRefresh, cloudSync)
            _ = await processing.drainProcessingQueue(
                configuration: settings.processingConfiguration
            )
            await runDueChannelChecks()
        } else {
            _ = await (selectedText, accountRefresh)
        }
    }

    func openLibrary(databaseURL: URL) async {
        let opened = await lifecycle.openLibrary(databaseURL: databaseURL)
        guard opened, let library = session.library else {
            channels.libraryChannels = []
            selection.trashEntries = []
            selection.highlightsText = ""
            return
        }
        do {
            try await settings.refreshTopics(from: library)
            let section = selection.selectInitialContent()
            navigation.show(section)
        } catch {
            session.errorMessage = error.localizedDescription
        }
    }

    func refreshLibrary(selecting entryID: String? = nil) async {
        guard let library = session.library else { return }
        do {
            try await lifecycle.refreshSession()
            try await refreshFeatureCaches(from: library)
            await restoreSelection(preferredEntryID: entryID)
            session.status = "Refreshed the local database"
        } catch {
            session.errorMessage = error.localizedDescription
        }
    }

    func sync() async {
        await lifecycle.sync()
        guard let library = session.library else { return }
        do {
            try await refreshFeatureCaches(from: library)
            await restoreSelection()
        } catch {
            session.errorMessage = error.localizedDescription
        }
    }

    func requestSync() {
        syncScheduler.requestLibrarySync()
    }

    func clearError() {
        lifecycle.clearError()
    }

    // MARK: Navigation and selection

    func show(_ section: LibrarySection) async {
        navigation.show(section)
        selection.clear()
        if section == .channels {
            await channels.loadChannels()
        }
    }

    func select(_ id: String, extending: Bool = false) async {
        navigation.showingHighlights = false
        _ = await selection.select(
            id,
            extending: extending,
            includeDeleted: navigation.showingTrash
        )
    }

    func selectVariant(_ variant: LibraryVariant) async {
        await selection.selectVariant(variant, includeDeleted: navigation.showingTrash)
    }

    func selectChannel(_ source: String) {
        navigation.selectChannel(source)
        selection.clear()
    }

    func showChannelSettings(_ source: String) {
        selectChannel(source)
        navigation.showingChannelSettings = true
        Task { await channels.loadChannels() }
    }

    func showChannelDomain(_ domain: String) {
        navigation.showChannelDomain(domain)
        selection.clear()
    }

    func showHighlights() {
        navigation.showHighlights()
        selection.clear()
        Task { await selection.loadHighlights() }
    }

    func showInbox() {
        navigation.showInbox()
        selection.clear()
    }

    func showTrash() {
        navigation.showTrash()
        selection.clear()
        Task { await selection.loadTrash() }
    }

    func showTopic(_ topic: String) async {
        navigation.showTopic(topic)
        selection.clear()
    }

    func navigateBack() {
        if !selection.selectedID.isEmpty {
            selection.clear()
        } else {
            navigation.navigateBack(hasSelection: false)
        }
    }

    func trashSelected() async {
        guard !selection.selectedID.isEmpty else { return }
        await trash(entryID: selection.selectedID)
    }

    func trash(entryID: String) async {
        let count = await selection.trash(entryID: entryID)
        guard count > 0 else { return }
        await refreshLibrary()
        requestSync()
    }

    func saveText(_ text: String, entryID: String, variant: LibraryVariant) async {
        if await selection.saveText(text, entryID: entryID, variant: variant) {
            requestSync()
        }
    }

    func addHighlight(_ text: String) async {
        if await selection.addHighlight(text) { requestSync() }
    }

    func removeHighlight(_ text: String) async {
        if await selection.removeHighlight(text) { requestSync() }
    }

    // MARK: Capture and processing

    func processSelected() async {
        guard !selection.selectedID.isEmpty else { return }
        await enqueueProcessing([selection.selectedID], selectWhenFinished: true)
    }

    func enqueueProcessing(
        _ entryIDs: [String],
        selectWhenFinished: Bool = false
    ) async {
        let results = await processing.enqueueProcessing(
            entryIDs,
            selectWhenFinished: selectWhenFinished,
            configuration: settings.processingConfiguration
        )
        let selectedID = results.compactMap(\.selectedID).last
        await refreshLibrary(selecting: selectedID)
        if !results.isEmpty { requestSync() }
    }

    func capture(_ text: String) async {
        guard let entryID = await processing.capture(text) else { return }
        navigation.activeSection = .items
        await refreshLibrary(selecting: entryID)
        if session.environment.isUITesting {
            session.status = "Captured"
            return
        }
        session.status = "Captured. Preparing summaries…"
        await enqueueProcessing([entryID], selectWhenFinished: true)
    }

    func captureWebPage(url: URL, page: SignedInChannelPage) async {
        guard let entryID = await processing.captureWebPage(url: url, page: page) else { return }
        await refreshLibrary(selecting: entryID)
        session.status = "Saved the signed-in page. Preparing summaries…"
        await enqueueProcessing([entryID], selectWhenFinished: true)
    }

    func capturePDF(_ url: URL) async {
        guard let entryID = await processing.capturePDF(url) else { return }
        await refreshLibrary(selecting: entryID)
        session.status = "PDF captured. Preparing summaries…"
        await enqueueProcessing([entryID], selectWhenFinished: true)
    }

    func setBrowserIngesting(_ ingesting: Bool) {
        processing.setBrowserIngesting(ingesting)
    }

    func streamPlayableAudio(
        for entry: LibraryEntry,
        variant: LibraryVariant,
        text: String,
        segmentReady: (URL) throws -> Void
    ) async -> Bool {
        return await audio.streamPlayableAudio(
            for: entry,
            variant: variant,
            text: text,
            segmentReady: segmentReady
        )
    }

    // MARK: Channels

    func checkSelectedChannel(loadMore: Bool = false) async {
        guard !navigation.selectedChannelSource.isEmpty else { return }
        if loadMore {
            _ = await channels.loadMoreChannel(source: navigation.selectedChannelSource)
        } else {
            _ = await channels.checkChannel(source: navigation.selectedChannelSource)
        }
    }

    func createChannel() async {
        guard let added = await channels.createChannel() else { return }
        navigation.selectedChannelSource = added.source
        navigation.showingChannelSettings = false
        selection.clear()
        requestSync()
    }

    func updateSelectedChannel(
        title: String,
        sources: [String],
        reviewWindow: Int,
        schedule: String
    ) async {
        guard !navigation.selectedChannelSource.isEmpty else { return }
        if await channels.updateChannel(
            source: navigation.selectedChannelSource,
            title: title,
            sources: sources,
            reviewWindow: reviewWindow,
            schedule: schedule
        ) {
            requestSync()
        }
    }

    func removeSelectedChannel() async {
        guard !navigation.selectedChannelSource.isEmpty else { return }
        guard await channels.removeChannel(source: navigation.selectedChannelSource) != nil else { return }
        navigation.selectedChannelSource = ""
        navigation.showingChannelSettings = false
        selection.clear()
        requestSync()
    }

    func runDueChannelChecks() async {
        _ = await channels.runDueChannelChecks()
    }

    // MARK: Settings

    func saveTopics() async {
        if await settings.saveTopics() { requestSync() }
    }

    func renameTopic(_ currentTitle: String, to newTitle: String) async {
        guard let savedTitle = await settings.renameTopic(currentTitle, to: newTitle) else { return }
        if navigation.selectedTopic == currentTitle { navigation.selectedTopic = savedTitle }
        await refreshLibrary()
        requestSync()
    }

    func deleteTopic(_ title: String) async {
        guard await settings.deleteTopic(title) else { return }
        if navigation.selectedTopic == title {
            navigation.showInbox()
            selection.clear()
        }
        await refreshLibrary()
        requestSync()
    }

    private func refreshFeatureCaches(from library: SQLiteLibraryStore) async throws {
        if selection.hasLoadedTrash { try await selection.refreshTrash(from: library) }
        if channels.hasLoadedChannels { try await channels.refreshChannels(from: library) }
        if selection.hasLoadedHighlights { try await selection.refreshHighlights(from: library) }
        try await settings.refreshTopics(from: library)
    }

    private func restoreSelection(preferredEntryID: String? = nil) async {
        if navigation.showingHighlights {
            selection.clear()
            return
        }
        let entryID = preferredEntryID ?? selection.selectedID
        if (session.projection.entries + selection.trashEntries).contains(where: { $0.id == entryID }) {
            await selection.select(entryID, includeDeleted: navigation.showingTrash)
            return
        }

        selection.clear()
        #if os(macOS)
        let hasSelectedChannel = channels.channels.contains {
            $0.source == navigation.selectedChannelSource
        }
        if navigation.selectedChannelSource != "new", !hasSelectedChannel {
            navigation.selectedChannelSource = ""
            navigation.showingChannelSettings = false
        }
        #else
        switch navigation.activeSection {
        case .items:
            break
        case .channels:
            let hasSelectedChannel = channels.channels.contains {
                $0.source == navigation.selectedChannelSource
            }
            if navigation.selectedChannelSource != "new", !hasSelectedChannel {
                navigation.selectedChannelSource = channels.channels.first?.source ?? ""
            }
        }
        #endif
    }
}
