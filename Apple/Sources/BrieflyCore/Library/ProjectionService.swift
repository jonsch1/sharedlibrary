import Foundation

struct LibraryProjectionService {
    let repositories: SQLiteLibraryRepositories

    init(repositories: SQLiteLibraryRepositories) {
        self.repositories = repositories
    }

    func loadProjection(includeDeleted: Bool = false) throws -> LibraryProjection {
        let (topicNames, attachmentsByDocument, channelSourcesByDocument) =
            try projectionResources()
        let entries = projectEntries(
            try repositories.documents.all(includeDeleted: includeDeleted),
            topicNames: topicNames,
            attachmentsByDocument: attachmentsByDocument,
            channelSourcesByDocument: channelSourcesByDocument
        )
        return LibraryProjection(
            schemaVersion: librarySchemaVersion,
            generatedAt: Date().iso8601,
            files: [],
            entries: entries,
            voiceBriefs: try repositories.documents.voiceBriefs()
        )
    }

    func loadLibraryIndex(includeDeleted: Bool = false) throws -> LibraryProjection {
        let (topicNames, attachmentsByDocument, channelSourcesByDocument) =
            try projectionResources()
        let entries = projectIndexEntries(
            try repositories.documents.index(includeDeleted: includeDeleted),
            topicNames: topicNames,
            attachmentsByDocument: attachmentsByDocument,
            channelSourcesByDocument: channelSourcesByDocument
        )
        return LibraryProjection(
            schemaVersion: librarySchemaVersion,
            generatedAt: Date().iso8601,
            files: [],
            entries: entries,
            voiceBriefs: try repositories.documents.voiceBriefs()
        )
    }

    func loadTrash() throws -> [LibraryEntry] {
        let (topicNames, attachmentsByDocument, channelSourcesByDocument) =
            try projectionResources()
        return projectEntries(
            try repositories.documents.deleted(),
            topicNames: topicNames,
            attachmentsByDocument: attachmentsByDocument,
            channelSourcesByDocument: channelSourcesByDocument
        )
    }

    func loadTrashIndex() throws -> [LibraryEntry] {
        let (topicNames, attachmentsByDocument, channelSourcesByDocument) =
            try projectionResources()
        return projectIndexEntries(
            try repositories.documents.deletedIndex(),
            topicNames: topicNames,
            attachmentsByDocument: attachmentsByDocument,
            channelSourcesByDocument: channelSourcesByDocument
        )
    }

    private func projectionResources() throws -> (
        [String: String],
        [String: [SQLiteAttachmentMetadata]],
        [String: [String]]
    ) {
        let topicNames = Dictionary(uniqueKeysWithValues: try repositories.documents.topics().map {
            ($0.id, $0.title)
        })
        let attachments = Dictionary(
            grouping: try repositories.attachments.metadata(),
            by: \.documentID
        )
        return (topicNames, attachments, try repositories.documents.channelSourcesByDocument())
    }

    private func projectEntries(
        _ documents: [SQLiteDocument],
        topicNames: [String: String],
        attachmentsByDocument: [String: [SQLiteAttachmentMetadata]],
        channelSourcesByDocument: [String: [String]]
    ) -> [LibraryEntry] {
        documents.map { document in
            let references: [LibraryText] = LibraryVariant.allCases.compactMap { variant in
                guard let text = document.texts[variant] else { return nil }
                return LibraryText(variant: variant, text: text)
            }
            let excerptBody = references.first {
                $0.variant == .concise || $0.variant == .detailed
            }?.text ?? document.texts[.source] ?? ""
            return projectEntry(
                document,
                references: references,
                excerptText: libraryExcerpt(excerptBody),
                topicNames: topicNames,
                attachments: attachmentsByDocument[document.id] ?? [],
                channelSources: channelSourcesByDocument[document.id] ?? []
            )
        }
    }

    private func projectIndexEntries(
        _ entries: [SQLiteDocumentIndex],
        topicNames: [String: String],
        attachmentsByDocument: [String: [SQLiteAttachmentMetadata]],
        channelSourcesByDocument: [String: [String]]
    ) -> [LibraryEntry] {
        entries.map { entry in
            let variants = Set(entry.variants)
            let references = LibraryVariant.allCases.compactMap { variant in
                variants.contains(variant) ? LibraryText(variant: variant) : nil
            }
            return projectEntry(
                entry.document,
                references: references,
                excerptText: entry.excerpt,
                topicNames: topicNames,
                attachments: attachmentsByDocument[entry.document.id] ?? [],
                channelSources: channelSourcesByDocument[entry.document.id] ?? []
            )
        }
    }

    private func projectEntry(
        _ document: SQLiteDocument,
        references: [LibraryText],
        excerptText: String,
        topicNames: [String: String],
        attachments: [SQLiteAttachmentMetadata],
        channelSources: [String]
    ) -> LibraryEntry {
        let audio = attachments.contains { $0.kind == "audio" }
        let favicon = attachments.first { $0.kind == "favicon" }
        return LibraryEntry(
            id: document.id,
            captureID: document.captureID,
            entryType: document.type,
            voiceBriefID: document.voiceBriefID,
            title: document.title,
            excerpt: excerptText,
            topicIDs: document.topicIDs,
            topicNames: document.topicIDs.map {
                topicNames[$0] ?? titleize($0)
            },
            tags: document.tags,
            sourceURL: document.sourceURL,
            mediaURL: document.mediaURL,
            faviconFile: favicon.map {
                "\(document.captureID).\(fileExtension(for: $0.mimeType))"
            },
            audio: nil,
            favicon: nil,
            sourceIDs: document.sourceIDs,
            sourceURLs: document.sourceURLs,
            channelSources: channelSources,
            hasAudio: audio,
            createdAt: document.createdAt.iso8601,
            updatedAt: document.updatedAt.iso8601,
            reviewedAt: nil,
            origin: .personal,
            sharedByUsername: nil,
            sharedByDisplayName: nil,
            inboxReferenceID: nil,
            texts: references
        )
    }

}
