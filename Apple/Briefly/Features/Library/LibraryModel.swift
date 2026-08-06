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

struct BrieflyActivity: Identifiable {
    let id = UUID()
    let icon: String
    let title: String
    let detail: String
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
    }

    var isWorking: Bool {
        processing.isIngesting || channels.isCheckingChannel || processing.isProcessing ||
            audio.isGeneratingSpeech ||
            audio.isPreparingSpeech || lifecycle.isSyncing || settings.isTestingAI
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

    var activeActivities: [BrieflyActivity] {
        var activities = [BrieflyActivity]()
        if audio.isGeneratingSpeech {
            activities.append(.init(icon: "waveform", title: "Creating audio", detail: session.status))
        }
        if audio.isPreparingSpeech {
            activities.append(.init(
                icon: "waveform",
                title: "Preparing voice",
                detail: audio.speechPreparationStatus
            ))
        }
        if processing.isProcessing {
            activities.append(.init(
                icon: "sparkles",
                title: "Preparing summaries",
                detail: session.status
            ))
        }
        if processing.isIngesting || channels.isCheckingChannel {
            activities.append(.init(
                icon: "square.and.arrow.down",
                title: "Gathering items",
                detail: session.status
            ))
        }
        if lifecycle.isSyncing {
            let detail = lifecycle.syncTotal > 0
                ? "Uploading \(lifecycle.syncCompleted) of \(lifecycle.syncTotal) changes"
                : session.status
            activities.append(.init(icon: "icloud", title: "Syncing", detail: detail))
        }
        if settings.isTestingAI {
            activities.append(.init(
                icon: "checkmark.bubble",
                title: "Testing AI",
                detail: session.status
            ))
        }
        return activities
    }
}
