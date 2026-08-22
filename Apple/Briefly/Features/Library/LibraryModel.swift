import BrieflyCore
import Foundation
import Observation

enum LibrarySection: String, CaseIterable, Identifiable {
    case items
    case channels

    var id: Self { self }

    var title: String {
        switch self {
        case .items: "Home"
        case .channels: "Channels"
        }
    }

    var icon: String {
        switch self {
        case .items: "house"
        case .channels: "dot.radiowaves.left.and.right"
        }
    }

    var searchPrompt: String {
        switch self {
        case .items: "Search items"
        case .channels: "Search channels"
        }
    }
}

struct ProcessingJobResult: Sendable {
    let entryID: String
    let selectedID: String?
    let succeeded: Bool
}

@MainActor
@Observable
final class LibrarySession {
    let backend = BrieflyBackend.shared
    let environment: AppEnvironment
    var cloud: CloudDocumentSync?
    var library: SQLiteLibraryStore?
    var projection = LibraryProjection.empty
    var status = "Loading library…"
    var errorMessage: String?

    init(environment: AppEnvironment = .current()) {
        self.environment = environment
    }

    var canEdit: Bool { library != nil }

    static var cloudKitAvailable: Bool {
        #if os(macOS)
        let signature = Bundle.main.bundleURL
            .appending(path: "Contents/_CodeSignature/CodeResources")
        #else
        let signature = Bundle.main.bundleURL
            .appending(path: "_CodeSignature/CodeResources")
        #endif
        return FileManager.default.fileExists(atPath: signature.path)
    }
}

@MainActor
@Observable
final class LibraryModel {
    let session: LibrarySession
    var navigation: LibraryNavigationModel
    let selection: LibrarySelectionModel
    let channels: LibraryChannelModel
    let processing: LibraryProcessingModel
    let account: LibraryAccountModel
    var settings: LibrarySettingsModel
    let audio: LibraryAudioModel
    let sharing: LibrarySharingModel
    let lifecycle: LibraryLifecycleModel
    let workflows: LibraryWorkflowCoordinator
    #if os(macOS)
    @ObservationIgnored
    private var agentServer: BrieflyAgentSocketServer?
    #endif

    init(environment: AppEnvironment = .current()) {
        let session = LibrarySession(environment: environment)
        let inputService = LibraryInputService(session: session)
        let selection = LibrarySelectionModel(session: session)
        let navigation = LibraryNavigationModel(session: session)
        let settings = LibrarySettingsModel(session: session)
        let processing = LibraryProcessingModel(session: session, inputService: inputService)
        let channels = LibraryChannelModel(session: session, inputService: inputService)
        let account = LibraryAccountModel(session: session)
        let audio = LibraryAudioModel(session: session)
        let sharing = LibrarySharingModel(session: session)
        let lifecycle = LibraryLifecycleModel(session: session)
        let workflows = LibraryWorkflowCoordinator(
            session: session,
            navigation: navigation,
            selection: selection,
            channels: channels,
            processing: processing,
            account: account,
            settings: settings,
            audio: audio,
            lifecycle: lifecycle
        )

        self.session = session
        self.navigation = navigation
        self.selection = selection
        self.channels = channels
        self.processing = processing
        self.account = account
        self.settings = settings
        self.audio = audio
        self.sharing = sharing
        self.lifecycle = lifecycle
        self.workflows = workflows

        #if os(macOS)
        let agentServer = BrieflyAgentSocketServer { [weak self] call in
            guard let self else {
                return BrieflyAgentReply(error: .unavailable)
            }
            return await self.handleAgentCall(call)
        }
        try? agentServer.start()
        self.agentServer = agentServer
        #endif
    }

    var isWorking: Bool {
        processing.isIngesting || channels.isCheckingChannel || processing.isProcessing ||
            audio.isGeneratingSpeech ||
            audio.isPreparingSpeech || lifecycle.isSyncing || settings.isTestingAI
    }

    var supportsAIProcessing: Bool {
        #if os(macOS)
        true
        #else
        false
        #endif
    }

    var activityStatus: String {
        audio.isPreparingSpeech ? audio.speechPreparationStatus : session.status
    }

    var menuBarActivity: String? {
        if audio.isGeneratingSpeech { return "Creating audio" }
        if audio.isPreparingSpeech { return "Preparing voice" }
        if processing.isProcessing { return "Processing" }
        if processing.isIngesting || channels.isCheckingChannel { return "Ingesting" }
        if lifecycle.isSyncing {
            return lifecycle.syncTotal > 0
                ? "Syncing \(lifecycle.syncCompleted)/\(lifecycle.syncTotal)"
                : "Syncing"
        }
        if settings.isTestingAI { return "Testing" }
        return nil
    }

    var menuBarIcon: String {
        if audio.isGeneratingSpeech || audio.isPreparingSpeech {
            return "waveform"
        }
        if processing.isProcessing || settings.isTestingAI { return "sparkles" }
        if processing.isIngesting || channels.isCheckingChannel {
            return "square.and.arrow.down"
        }
        if lifecycle.isSyncing { return "arrow.triangle.2.circlepath" }
        return "doc.text"
    }

    #if os(macOS)
    private func handleAgentCall(_ call: BrieflyAgentCall) async -> BrieflyAgentReply {
        do {
            let library = try await agentLibrary()
            let agent = BrieflyAgentLibrary(store: library)
            switch call.op {
            case "ingest":
                guard let request = call.ingest else {
                    throw BrieflyAgentFailure.invalid("ingest parameters are required.")
                }
                return BrieflyAgentReply(
                    ingest: try await ingestForAgent(request, in: library)
                )
            case "save":
                guard let request = call.save else {
                    throw BrieflyAgentFailure.invalid("save parameters are required.")
                }
                let result = try await agent.save(request)
                await finishAgentWrite(result)
                return BrieflyAgentReply(save: result)
            case "search":
                guard let request = call.search else {
                    throw BrieflyAgentFailure.invalid("search parameters are required.")
                }
                return BrieflyAgentReply(search: try await agent.search(request))
            case "read":
                guard let request = call.read else {
                    throw BrieflyAgentFailure.invalid("read parameters are required.")
                }
                return BrieflyAgentReply(read: try await agent.read(request))
            default:
                throw BrieflyAgentFailure.invalid("Unknown Briefly agent operation.")
            }
        } catch let failure as BrieflyAgentFailure {
            return BrieflyAgentReply(error: failure)
        } catch {
            return BrieflyAgentReply(error: BrieflyAgentFailure(
                code: "failed",
                message: "Briefly could not complete the request."
            ))
        }
    }

    private func agentLibrary() async throws -> SQLiteLibraryStore {
        for _ in 0..<150 {
            if let library = session.library { return library }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw BrieflyAgentFailure.unavailable
    }

    private func ingestForAgent(
        _ request: BrieflyAgentIngestRequest,
        in library: SQLiteLibraryStore
    ) async throws -> BrieflyAgentWriteResult {
        let value = request.url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            value.count <= 2_048,
            !value.contains(where: \.isWhitespace),
            let url = URL(string: value),
            ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
            url.host != nil,
            url.user == nil,
            url.password == nil
        else {
            throw BrieflyAgentFailure.invalid("url must be an absolute HTTP(S) URL.")
        }

        let draft: ItemDraft
        do {
            draft = try await NativeItemInputRouter().ingest(
                ItemInputRequest(source: .url(url)),
                context: processing.inputService.itemInputContext()
            )
        } catch {
            throw BrieflyAgentFailure(code: "ingest_failed", message: error.localizedDescription)
        }

        let id: String
        do {
            id = try await library.captureItem(draft)
        } catch {
            throw BrieflyAgentFailure(
                code: "ingest_failed",
                message: "Briefly could not save that item."
            )
        }
        let agent = BrieflyAgentLibrary(store: library)
        let result = try await agent.writeResult(id: id)
        if result.status == "processing" {
            try await library.enqueueProcessingJob(entryID: id, selectWhenFinished: false)
        }
        await finishAgentWrite(result)
        return result
    }

    private func finishAgentWrite(_ result: BrieflyAgentWriteResult) async {
        await workflows.refreshLibrary()
        workflows.requestSync()
        if result.status == "processing" {
            Task { @MainActor [weak self] in
                guard let self else { return }
                let completed = await processing.drainProcessingQueue(
                    configuration: settings.processingConfiguration
                )
                if !completed.isEmpty {
                    await workflows.refreshLibrary()
                    workflows.requestSync()
                }
            }
        }
    }
    #endif

}
