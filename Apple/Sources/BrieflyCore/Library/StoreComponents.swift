import Foundation

/// The composition root for the library application layer. Services depend on
/// focused repositories and on one another only where a workflow genuinely
/// crosses a boundary.
struct LibraryStoreComponents {
    let repositories: SQLiteLibraryRepositories
    let capture: LibraryCaptureService
    let projection: LibraryProjectionService
    let channelState: LibraryChannelStateRepository
    let channels: LibraryChannelCoordinator
    let voiceBriefs: LibraryVoiceBriefCoordinator
    let content: LibraryContentCoordinator
    let processing: LibraryProcessingCoordinator
    let markdown: LibraryMarkdownImportService

    init(database: SQLiteLibrary, fileManager: FileManager) {
        let repositories = SQLiteLibraryRepositories(database: database)
        let projection = LibraryProjectionService(repositories: repositories)
        let channelState = LibraryChannelStateRepository(repositories: repositories)
        let channels = LibraryChannelCoordinator(
            repositories: repositories,
            state: channelState,
            projection: projection
        )
        self.repositories = repositories
        capture = LibraryCaptureService(repositories: repositories, fileManager: fileManager)
        self.projection = projection
        self.channelState = channelState
        self.channels = channels
        voiceBriefs = LibraryVoiceBriefCoordinator(
            repositories: repositories,
            state: channelState,
            projection: projection,
            channels: channels
        )
        content = LibraryContentCoordinator(
            repositories: repositories,
            channelState: channelState,
            projection: projection
        )
        processing = LibraryProcessingCoordinator(repositories: repositories)
        markdown = LibraryMarkdownImportService(
            repositories: repositories,
            channelState: channelState,
            fileManager: fileManager
        )
    }
}
