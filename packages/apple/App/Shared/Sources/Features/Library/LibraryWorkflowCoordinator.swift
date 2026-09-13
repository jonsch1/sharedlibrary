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
            self.pendingSync = nil
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
    let capture: LibraryCaptureModel
    #if os(macOS)
    let processing: LibraryProcessingModel
    #endif
    let account: LibraryAccountModel
    let settings: LibrarySettingsModel
    let audio: LibraryAudioModel
    let lifecycle: LibraryLifecycleModel

    private let syncScheduler: LibrarySyncScheduler
    private var acceptedChannelSummaryTask: Task<Void, Never>?
    private var acceptedChannelSummaryRequested = false
    private var isImportingSharedCaptures = false
    private var textWrites = [String: (id: UUID, task: Task<Void, Never>)]()

    init(
        session: LibrarySession,
        navigation: LibraryNavigationModel,
        selection: LibrarySelectionModel,
        channels: LibraryChannelModel,
        capture: LibraryCaptureModel,
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
        self.capture = capture
        #if os(macOS)
        self.processing = LibraryProcessingModel(session: session, inputService: capture.inputService)
        #endif
        self.account = account
        self.settings = settings
        self.audio = audio
        self.lifecycle = lifecycle
        self.syncScheduler = syncScheduler
        #if os(macOS)
        processing.onStateChanged = { [weak lifecycle] in
            try? await lifecycle?.refreshSession()
            await lifecycle?.sync()
        }
        #endif
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
        if account.account.reviewAccess == true {
            do {
                let databaseURL = try session.environment.prepareAppReviewLibrary()
                await openLibrary(databaseURL: databaseURL, cloudSyncEnabled: false)
                await selection.loadSelectedText()
                session.status = "Showing the App Review sample library"
            } catch {
                lifecycle.isReady = true
                session.errorMessage = error.localizedDescription
            }
            return
        }

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
            await importPendingSharedCaptures()
            await runDueChannelChecks()
        } else {
            _ = await (selectedText, accountRefresh)
        }
    }

    func openLibrary(databaseURL: URL, cloudSyncEnabled: Bool = true) async {
        let opened = await lifecycle.openLibrary(
            databaseURL: databaseURL,
            cloudSyncEnabled: cloudSyncEnabled
        )
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

    func addSampleLibrary() async {
        guard let library = session.library else { return }
        do {
            let database = try await library.documentDatabase()
            guard try database.isEmpty() else { return }
            try session.environment.seedSampleLibrary(database)
            try await lifecycle.refreshSession()
            try await channels.refreshChannels(from: library)
            session.status = "Sample items added"
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
        #if os(macOS)
        if !processing.isProcessing {
            _ = await processing.drainProcessingQueue(configuration: settings.processingConfiguration)
            await lifecycle.sync()
        }
        #endif
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

    func permanentlyDelete(entryID: String) async {
        guard let library = session.library else { return }
        do {
            try await library.permanentlyDelete([entryID])
            if selection.selectedID == entryID { selection.clear() }
            await refreshLibrary()
            requestSync()
        } catch { session.errorMessage = error.localizedDescription }
    }

    func emptyTrash() async {
        guard let library = session.library else { return }
        do {
            try await library.emptyTrash()
            if navigation.showingTrash { selection.clear() }
            await refreshLibrary()
            requestSync()
        } catch { session.errorMessage = error.localizedDescription }
    }

    func saveText(_ text: String, entryID: String, variant: LibraryVariant) async {
        let key = "\(entryID):\(variant.rawValue)"
        let previous = textWrites[key]?.task
        let id = UUID()
        let task = Task {
            await previous?.value
            if await selection.saveText(text, entryID: entryID, variant: variant) {
                requestSync()
            }
        }
        textWrites[key] = (id, task)
        await task.value
        if textWrites[key]?.id == id {
            textWrites.removeValue(forKey: key)
        }
    }

    func addHighlight(_ text: String) async {
        if await selection.addHighlight(text) { requestSync() }
    }

    func removeHighlight(_ text: String) async {
        if await selection.removeHighlight(text) { requestSync() }
    }

    // MARK: Capture and processing

    func importPendingSharedCaptures(retryFailed: Bool = false) async {
        #if os(iOS)
        guard session.library != nil,
              account.account.reviewAccess != true,
              !session.environment.isUITesting,
              !ProcessInfo.processInfo.arguments.contains("--demo"),
              !isImportingSharedCaptures else { return }
        isImportingSharedCaptures = true
        defer { isImportingSharedCaptures = false }

        do {
            let inbox = try SharedCaptureInbox()
            try inbox.recoverInterruptedClaims()
            if retryFailed { try inbox.retryFailedCaptures() }
            let initialCount = try inbox.pendingCaptures().count
            guard initialCount > 0 else { return }

            var importedIDs = [String]()
            var failedCount = 0
            var attemptedIDs = Set<UUID>()
            for _ in 0..<initialCount {
                guard let capture = try inbox.claimNext(excluding: attemptedIDs) else { break }
                attemptedIDs.insert(capture.id)
                do {
                    let request = try inbox.inputRequest(for: capture)
                    let entryID = try await session.library!.queueCapture(
                        request, captureID: capture.captureID, createdAt: capture.createdAt
                    )
                    try inbox.complete(capture)
                    importedIDs.append(entryID)
                } catch {
                    failedCount += 1
                    try? inbox.release(capture, error: error)
                }
            }

            if !importedIDs.isEmpty {
                navigation.activeSection = .items
                await refreshLibrary(selecting: importedIDs.last)
                session.status = importedIDs.count == 1
                    ? "Imported a shared item"
                    : "Imported \(importedIDs.count) shared items"
                requestSync()
            }
            if failedCount > 0 {
                let message = failedCount == 1
                    ? "A shared item could not be imported. Briefly will retry it next time."
                    : "\(failedCount) shared items could not be imported. Briefly will retry them next time."
                session.errorMessage = try inbox.failedCaptures().isEmpty
                    ? message
                    : "Some shared items still could not be imported. Retry them in Settings → Library & Sync."
            }
        } catch {
            session.errorMessage = error.localizedDescription
        }
        #endif
    }

    #if os(macOS)
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

    #endif

    func capture(_ text: String, useNative: Bool = false, onCaptured: (() -> Void)? = nil) async {
        session.customCaptureFailure = nil
        clearError()
        guard let entryID = await capture.capture(text, useNative: useNative) else { return }
        onCaptured?()
        navigation.activeSection = .items
        await finishCapturedItem(entryID)
    }

    private func finishCapturedItem(_ entryID: String) async {
        await refreshLibrary(selecting: entryID)
        requestSync()
        session.status = "Saved to inbox"
        #if os(macOS)
        if let library = session.library,
           let result = try? await BrieflyAgentLibrary(store: library).writeResult(id: entryID),
           result.status == "processing" {
            session.status = "Captured. Preparing summaries…"
            await enqueueProcessing([entryID], selectWhenFinished: true)
        }
        #endif
    }

    func captureFile(_ url: URL, onCaptured: (() -> Void)? = nil) async {
        guard let entryID = await capture.captureFile(url) else { return }
        onCaptured?()
        await refreshLibrary(selecting: entryID)
        #if os(macOS)
        session.status = "File saved. Preparing summaries…"
        await enqueueProcessing([entryID], selectWhenFinished: true)
        #else
        session.status = "Saved to inbox"
        requestSync()
        #endif
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

    func retryCapture(_ id: String) async {
        do {
            try await session.library?.retryCapture(id)
            await refreshLibrary()
            requestSync()
        } catch { session.errorMessage = error.localizedDescription }
    }

    // MARK: Channels

    func checkSelectedChannel(loadMore: Bool = false) async {
        #if os(macOS)
        guard !navigation.selectedChannelSource.isEmpty else { return }
        if loadMore {
            _ = await channels.loadMoreChannel(source: navigation.selectedChannelSource)
        } else {
            _ = await channels.checkChannel(source: navigation.selectedChannelSource)
        }
        #else
        await sync()
        #endif
    }

    func checkAllChannels(loadMore: Bool = false) async {
        await channels.checkAllChannels(loadMore: loadMore)
    }

    func createChannel() async {
        guard let added = await channels.createChannel() else { return }
        navigation.selectedChannelSource = added.source
        navigation.showingChannelSettings = true
        selection.clear()
        requestSync()
    }

    func updateSelectedChannel(
        title: String,
        sources: [String],
        reviewWindow: Int
    ) async {
        guard !navigation.selectedChannelSource.isEmpty else { return }
        if await channels.updateChannel(
            source: navigation.selectedChannelSource,
            title: title,
            sources: sources,
            reviewWindow: reviewWindow
        ) {
            requestSync()
        }
    }

    func removeSelectedChannel() async {
        guard !navigation.selectedChannelSource.isEmpty else { return }
        guard await channels.removeChannel(source: navigation.selectedChannelSource) != nil else { return }
        navigation.selectedChannelSource = channels.channels.first?.source ?? "new"
        navigation.showingChannelSettings = true
        selection.clear()
        requestSync()
    }

    func runDueChannelChecks() async {
        #if os(macOS)
        _ = await channels.runDueChannelChecks()
        #endif
    }

    func finishAcceptedChannelItems(_ entryIDs: [String]) async {
        guard !entryIDs.isEmpty else { return }
        acceptedChannelSummaryRequested = true
        guard acceptedChannelSummaryTask == nil else { return }
        acceptedChannelSummaryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            #if os(macOS)
            while self.acceptedChannelSummaryRequested {
                self.acceptedChannelSummaryRequested = false
                _ = await self.processing.drainProcessingQueue(
                    configuration: self.settings.processingConfiguration
                )
            }
            #endif
            await self.refreshLibrary()
            self.requestSync()
            self.acceptedChannelSummaryTask = nil
        }
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
        if await selection.restoreSelection(
            preferredEntryID: entryID,
            includeDeleted: navigation.showingTrash
        ) {
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
