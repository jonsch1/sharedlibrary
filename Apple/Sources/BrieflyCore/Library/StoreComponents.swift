import Foundation

/// The composition root for the library application layer. Services depend on
/// focused repositories and on one another only where a workflow genuinely
/// crosses a boundary.
struct LibraryStoreComponents {
    let capture: LibraryCaptureService
    let projection: LibraryProjectionService
    let channelState: LibraryChannelStateRepository
    let channels: LibraryChannelCoordinator
    let content: LibraryContentCoordinator
    let processing: LibraryProcessingCoordinator
    let markdown: LibraryMarkdownImportService

    init(database: SQLiteLibrary, fileManager: FileManager) {
        let documents = SQLiteDocumentRepository(database: database)
        let topics = SQLiteTopicRepository(database: database)
        let channelRepository = SQLiteChannelRepository(database: database)
        let attachments = SQLiteAttachmentRepository(database: database)
        let processingRepository = SQLiteProcessingRepository(database: database)
        let markdownRepository = SQLiteMarkdownRepository(database: database)
        let projection = LibraryProjectionService(
            documents: documents,
            topics: topics,
            channels: channelRepository,
            attachments: attachments
        )
        let channelState = LibraryChannelStateRepository(
            channels: channelRepository
        )
        let channels = LibraryChannelCoordinator(
            channels: channelRepository,
            state: channelState,
            processing: processingRepository
        )
        capture = LibraryCaptureService(
            documents: documents,
            attachments: attachments,
            fileManager: fileManager
        )
        self.projection = projection
        self.channelState = channelState
        self.channels = channels
        content = LibraryContentCoordinator(
            documents: documents,
            topics: topics,
            projection: projection
        )
        processing = LibraryProcessingCoordinator(
            documents: documents,
            topics: topics,
            processing: processingRepository
        )
        markdown = LibraryMarkdownImportService(
            topics: topics,
            markdown: markdownRepository,
            fileManager: fileManager
        )
    }
}
