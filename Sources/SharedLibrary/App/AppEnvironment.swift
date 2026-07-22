import Foundation
import AppKit

extension Notification.Name {
    static let libraryDidChange = Notification.Name("SharedLibrary.libraryDidChange")
    static let processingDidStart = Notification.Name("SharedLibrary.processingDidStart")
    static let processingDidFinish = Notification.Name("SharedLibrary.processingDidFinish")
    static let processingDidFail = Notification.Name("SharedLibrary.processingDidFail")
    static let libraryAppearanceDidChange = Notification.Name("SharedLibrary.libraryAppearanceDidChange")
}

@MainActor
final class AppEnvironment: ObservableObject {
    let libraryStore: LibraryStore
    let knowledgeStore: KnowledgeStore
    let extractor: ExtractionService
    let settings: AppSettings
    let processingCoordinator: ProcessingCoordinator
    let gitSyncCoordinator: GitSyncCoordinator
    let sharingStore: SharingStore
    let sharedGitSyncCoordinator: GitSyncCoordinator

    init() {
        settings = AppSettings.shared
        gitSyncCoordinator = GitSyncCoordinator(workspaceURL: settings.workspaceRootURL)
        sharedGitSyncCoordinator = GitSyncCoordinator(workspaceURL: settings.sharedWorkspaceRootURL)
        let sharingStore = SharingStore()
        self.sharingStore = sharingStore
        let libraryStore = LibraryStore()
        self.libraryStore = libraryStore
        let knowledgeStore = KnowledgeStore()
        self.knowledgeStore = knowledgeStore
        extractor = ExtractionService()
        processingCoordinator = ProcessingCoordinator(
            libraryStore: libraryStore,
            knowledgeStore: knowledgeStore,
            settings: settings
        )
        do {
            try settings.ensureWorkspace()
            try sharingStore.ensureSharedWorkspace(
                privateWorkspaceURL: settings.workspaceRootURL,
                sharedWorkspaceURL: settings.sharedWorkspaceRootURL
            )
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
        try sharingStore.validateWorkspaceRoots(
            privateWorkspaceURL: url,
            sharedWorkspaceURL: settings.sharedWorkspaceRootURL
        )
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
        gitSyncCoordinator.setWorkspaceURL(settings.workspaceRootURL)
        objectWillChange.send()
        NotificationCenter.default.post(name: .libraryDidChange, object: nil)
    }

    func setSharedWorkspaceFolder(_ url: URL) throws {
        try sharingStore.ensureSharedWorkspace(
            privateWorkspaceURL: settings.workspaceRootURL,
            sharedWorkspaceURL: url
        )
        settings.sharedWorkspaceRootURL = url
        sharedGitSyncCoordinator.setWorkspaceURL(url)
        objectWillChange.send()
    }
}
