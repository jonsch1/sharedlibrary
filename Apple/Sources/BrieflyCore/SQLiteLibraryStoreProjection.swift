import Foundation

extension SQLiteLibraryStore {
    public func loadProjection(includeDeleted: Bool = false) throws -> LibraryProjection {
        let database = try database()
        let (topicNames, attachmentsByDocument, channelSourcesByDocument) =
            try projectionResources(database)
        let entries = projectEntries(
            try database.allDocuments(includeDeleted: includeDeleted),
            topicNames: topicNames,
            attachmentsByDocument: attachmentsByDocument,
            channelSourcesByDocument: channelSourcesByDocument
        )
        return LibraryProjection(
            schemaVersion: librarySchemaVersion,
            generatedAt: Date().iso8601,
            files: [],
            entries: entries,
            voiceBriefs: try readVoiceBriefs()
        )
    }

    public func loadLibraryIndex(includeDeleted: Bool = false) throws -> LibraryProjection {
        let database = try database()
        let (topicNames, attachmentsByDocument, channelSourcesByDocument) =
            try projectionResources(database)
        let entries = projectIndexEntries(
            try database.documentIndex(includeDeleted: includeDeleted),
            topicNames: topicNames,
            attachmentsByDocument: attachmentsByDocument,
            channelSourcesByDocument: channelSourcesByDocument
        )
        return LibraryProjection(
            schemaVersion: librarySchemaVersion,
            generatedAt: Date().iso8601,
            files: [],
            entries: entries,
            voiceBriefs: try readVoiceBriefs()
        )
    }

    public func loadTrash() throws -> [LibraryEntry] {
        let database = try database()
        let (topicNames, attachmentsByDocument, channelSourcesByDocument) =
            try projectionResources(database)
        return projectEntries(
            try database.deletedDocuments(),
            topicNames: topicNames,
            attachmentsByDocument: attachmentsByDocument,
            channelSourcesByDocument: channelSourcesByDocument
        )
    }

    public func loadTrashIndex() throws -> [LibraryEntry] {
        let database = try database()
        let (topicNames, attachmentsByDocument, channelSourcesByDocument) =
            try projectionResources(database)
        return projectIndexEntries(
            try database.deletedDocumentIndex(),
            topicNames: topicNames,
            attachmentsByDocument: attachmentsByDocument,
            channelSourcesByDocument: channelSourcesByDocument
        )
    }

    private func projectionResources(
        _ database: SQLiteLibrary
    ) throws -> (
        [String: String],
        [String: [SQLiteAttachmentMetadata]],
        [String: [String]]
    ) {
        let topicNames = Dictionary(uniqueKeysWithValues: try database.topicDefinitions().map {
            ($0.id, $0.title)
        })
        let attachments = Dictionary(
            grouping: try database.attachmentMetadata(),
            by: \.documentID
        )
        return (topicNames, attachments, try database.documentChannelSources())
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
