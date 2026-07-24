import Foundation
import AppKit

extension Notification.Name {
    static let libraryDidChange = Notification.Name("SharedLibrary.libraryDidChange")
    static let processingDidStart = Notification.Name("SharedLibrary.processingDidStart")
    static let processingDidFinish = Notification.Name("SharedLibrary.processingDidFinish")
    static let processingDidFail = Notification.Name("SharedLibrary.processingDidFail")
    static let libraryAppearanceDidChange = Notification.Name("SharedLibrary.libraryAppearanceDidChange")
    static let workspaceDidSynchronize = Notification.Name("SharedLibrary.workspaceDidSynchronize")
    static let sharedInboxDidChange = Notification.Name("SharedLibrary.sharedInboxDidChange")
}

@MainActor
final class AppEnvironment: ObservableObject {
    let libraryStore: LibraryStore
    let knowledgeStore: KnowledgeStore
    let extractor: ExtractionService
    let settings: AppSettings
    let processingCoordinator: ProcessingCoordinator
    let googleDriveAuthorization: GoogleDriveAuthorizationCoordinator
    let googleDriveMediaStore: GoogleDriveMediaStore
    let sharingStore: SharingStore
    let peopleStore: PeopleStore
    let googleDriveLibraryPublisher: GoogleDriveLibraryPublisher

    init() {
        settings = AppSettings.shared
        googleDriveAuthorization = GoogleDriveAuthorizationCoordinator()
        let googleDriveMediaStore = GoogleDriveMediaStore()
        self.googleDriveMediaStore = googleDriveMediaStore
        peopleStore = PeopleStore(
            sharedWorkspaceURL: settings.sharedWorkspaceRootURL,
            settings: settings
        )
        let sharingStore = SharingStore()
        self.sharingStore = sharingStore
        let libraryStore = LibraryStore()
        self.libraryStore = libraryStore
        let knowledgeStore = KnowledgeStore()
        self.knowledgeStore = knowledgeStore
        googleDriveLibraryPublisher = GoogleDriveLibraryPublisher(
            settings: settings,
            knowledgeStore: knowledgeStore,
            sharingStore: sharingStore,
            driveStore: googleDriveMediaStore
        )
        extractor = ExtractionService()
        processingCoordinator = ProcessingCoordinator(
            libraryStore: libraryStore,
            knowledgeStore: knowledgeStore,
            settings: settings
        )
        do {
            try settings.ensureWorkspace()
            try libraryStore.migrateLegacyClusterMetadata(
                workspaceRootURL: settings.workspaceRootURL
            )
            let shouldReorganizeExistingCaptures = try libraryStore.preparePromptTopicMigration(
                workspaceRootURL: settings.workspaceRootURL
            )
            if shouldReorganizeExistingCaptures {
                processingCoordinator.organizeUncategorizedCaptures(
                    workspaceRootURL: settings.workspaceRootURL
                )
            }
        } catch {
            fatalError("Failed to open workspace: \(error)")
        }
    }

    func setWorkspaceFolder(_ url: URL) throws {
        settings.workspaceRootURL = url
        try settings.ensureWorkspace()
        try libraryStore.migrateLegacyClusterMetadata(workspaceRootURL: settings.workspaceRootURL)
        let shouldReorganizeExistingCaptures = try libraryStore.preparePromptTopicMigration(
            workspaceRootURL: settings.workspaceRootURL
        )
        if shouldReorganizeExistingCaptures {
            processingCoordinator.organizeUncategorizedCaptures(
                workspaceRootURL: settings.workspaceRootURL
            )
        }
        googleDriveLibraryPublisher.requestAutomaticUpdate(reason: "the changed personal workspace")
        objectWillChange.send()
        NotificationCenter.default.post(name: .libraryDidChange, object: nil)
    }

    func setSharedWorkspaceFolder(_ url: URL) throws {
        try sharingStore.ensureSharedWorkspace(
            privateWorkspaceURL: settings.workspaceRootURL,
            sharedWorkspaceURL: url
        )
        settings.sharedWorkspaceRootURL = url
        peopleStore.setSharedWorkspaceURL(url)
        googleDriveLibraryPublisher.requestAutomaticUpdate(reason: "the changed shared workspace")
        objectWillChange.send()
    }
}
