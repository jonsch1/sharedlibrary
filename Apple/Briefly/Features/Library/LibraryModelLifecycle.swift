import BrieflyCore
import Foundation
import Observation

@MainActor
@Observable
final class LibraryLifecycleModel {
    let session: LibrarySession

    weak var navigation: LibraryNavigationModel?
    weak var selection: LibrarySelectionModel?
    weak var channels: LibraryChannelModel?
    weak var processing: LibraryProcessingModel?
    weak var account: LibraryAccountModel?
    weak var settings: LibrarySettingsModel?
    weak var voiceBriefs: LibraryVoiceBriefModel?
    weak var audio: LibraryAudioModel?

    var started = false
    var isReady = false
    var isSyncing = false
    var syncCompleted = 0
    var syncTotal = 0

    private var pendingSync: Task<Void, Never>?

    init(
        session: LibrarySession,
        navigation: LibraryNavigationModel,
        selection: LibrarySelectionModel,
        channels: LibraryChannelModel,
        processing: LibraryProcessingModel,
        account: LibraryAccountModel,
        settings: LibrarySettingsModel,
        voiceBriefs: LibraryVoiceBriefModel,
        audio: LibraryAudioModel
    ) {
        self.session = session
        install(
            navigation: navigation,
            selection: selection,
            channels: channels,
            processing: processing,
            account: account,
            settings: settings,
            voiceBriefs: voiceBriefs,
            audio: audio
        )
    }

    var runsScheduledWork: Bool { !session.environment.isUITesting }

    func install(
        navigation: LibraryNavigationModel,
        selection: LibrarySelectionModel,
        channels: LibraryChannelModel,
        processing: LibraryProcessingModel,
        account: LibraryAccountModel,
        settings: LibrarySettingsModel,
        voiceBriefs: LibraryVoiceBriefModel,
        audio: LibraryAudioModel
    ) {
        self.navigation = navigation
        self.selection = selection
        self.channels = channels
        self.processing = processing
        self.account = account
        self.settings = settings
        self.voiceBriefs = voiceBriefs
        self.audio = audio
    }

    func start() async {
        guard !started else { return }
        started = true
        if session.environment.isUITesting {
            do {
                await openLibrary(databaseURL: try session.environment.prepareUITestLibrary())
                await selection?.loadSelectedText()
                session.status = "Ready for application tour"
            } catch {
                isReady = true
                session.errorMessage = error.localizedDescription
            }
            return
        }

        audio?.beginLocalSpeechPreparation()
        let usesDemo = ProcessInfo.processInfo.arguments.contains("--demo")
        if usesDemo {
            session.projection = .demo
            session.status = "Showing the sample library"
            selection?.selectInitialContent()
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

        async let selectedText: Void = selection?.loadSelectedText() ?? ()
        async let accountRefresh: Void = account?.refreshAccount() ?? ()
        if session.library != nil {
            async let cloudSync: Void = sync()
            _ = await (selectedText, accountRefresh, cloudSync)
            await processing?.drainProcessingQueue()
            await voiceBriefs?.resumePendingVoiceBriefs()
            await channels?.runDueChannelChecks()
            await voiceBriefs?.runDueVoiceBriefs()
        } else {
            _ = await (selectedText, accountRefresh)
        }
    }

    func openLibrary(databaseURL: URL) async {
        do {
            let next = SQLiteLibraryStore(databaseURL: databaseURL)
            session.projection = try await next.loadLibraryIndex()
            try await settings?.refreshTopics(from: next)
            session.library = next
            session.status = "Opened local SQLite library"
            selection?.selectInitialContent()
            isReady = true
            let database = try await next.documentDatabase()
            session.cloud = !session.environment.isUITesting && LibrarySession.cloudKitAvailable
                ? CloudDocumentSync(
                    store: database,
                    containerIdentifier: "iCloud.fyi.readbriefly"
                )
                : nil
        } catch {
            session.library = nil
            session.cloud = nil
            channels?.libraryChannels = []
            selection?.trashEntries = []
            isReady = true
            session.errorMessage = error.localizedDescription
        }
    }

    func refreshLibrary(selecting entryID: String? = nil) async {
        guard let library = session.library else { return }
        do {
            try await refreshLibraryState(from: library)
            session.status = "Refreshed the local database"
            await selection?.restoreSelection(preferredEntryID: entryID)
        } catch {
            session.errorMessage = error.localizedDescription
        }
    }

    private func refreshLibraryAfterCloudFetch(from library: SQLiteLibraryStore) async throws {
        try await refreshLibraryState(from: library)
        await selection?.restoreSelection()
    }

    private func refreshLibraryState(from library: SQLiteLibraryStore) async throws {
        session.projection = try await library.loadLibraryIndex()
        if selection?.hasLoadedTrash == true {
            try await selection?.refreshTrash(from: library)
        }
        if channels?.hasLoadedChannels == true {
            try await channels?.refreshChannels(from: library)
        }
        if selection?.hasLoadedHighlights == true {
            try await selection?.refreshHighlights(from: library)
        }
        try await settings?.refreshTopics(from: library)
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
            guard let library = session.library else { return }
            guard let cloud = session.cloud else {
                session.status = "Using the local SQLite library"
                return
            }
            guard try await cloud.accountStatus() == .available else {
                throw NativeLibraryError.iCloudUnavailable
            }
            session.status = "Checking iCloud for changes…"
            try await cloud.synchronize(
                onProgress: { [weak self] completed, total in
                    guard let self else { return }
                    syncCompleted = completed
                    syncTotal = total
                    session.status = total > 0
                        ? "Uploading \(completed) of \(total) changes…"
                        : "Finishing iCloud sync…"
                },
                onFetchedChanges: { [weak self] in
                    guard let self else { return }
                    try await refreshLibraryAfterCloudFetch(from: library)
                }
            )
            try await refreshLibraryAfterCloudFetch(from: library)
            session.status = "Sync complete"
        } catch {
            session.errorMessage = error.localizedDescription
            session.status = "Using the last complete offline library"
        }
    }

    func requestSync() {
        pendingSync?.cancel()
        pendingSync = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(900))
            guard !Task.isCancelled else { return }
            await self?.sync()
        }
    }

    func clearError() {
        session.errorMessage = nil
    }
}
