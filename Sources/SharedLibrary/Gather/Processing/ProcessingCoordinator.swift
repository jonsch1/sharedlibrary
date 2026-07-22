import Foundation

@MainActor
final class ProcessingCoordinator {
    private let libraryStore: LibraryStore
    private let knowledgeStore: KnowledgeStore
    private let settings: AppSettings
    private let service: ProcessingService
    private var processingPaths: Set<String> = []
    private var bulkTask: Task<Void, Never>?

    init(
        libraryStore: LibraryStore,
        knowledgeStore: KnowledgeStore,
        settings: AppSettings = .shared,
        service: ProcessingService = ProcessingService()
    ) {
        self.libraryStore = libraryStore
        self.knowledgeStore = knowledgeStore
        self.settings = settings
        self.service = service
    }

    func isProcessing(_ record: KnowledgeRecord) -> Bool {
        processingPaths.contains(record.fileURL.standardizedFileURL.path)
    }

    func process(record: KnowledgeRecord, workspaceRootURL: URL) {
        let sourcePath = record.fileURL.standardizedFileURL.path
        guard processingPaths.insert(sourcePath).inserted else { return }

        Task {
            await processAndPublish(record: record, workspaceRootURL: workspaceRootURL)
            processingPaths.remove(sourcePath)
        }
    }

    func process(item: LibraryItem, workspaceRootURL: URL) {
        guard item.type != "image", let fileURL = item.fileURL else { return }
        process(
            record: KnowledgeRecord(
                id: "source:\(fileURL.standardizedFileURL.path)",
                captureID: item.id,
                typeID: "source",
                title: item.title,
                excerpt: String(item.content.prefix(180)),
                topicIDs: item.topics,
                tags: item.tags,
                sourceURL: item.url,
                fileURL: fileURL.standardizedFileURL,
                createdAt: item.createdAtDate,
                updatedAt: item.updatedAtDate,
                reviewedAt: item.reviewedAtDate
            ),
            workspaceRootURL: workspaceRootURL
        )
    }

    func organizeUncategorizedCaptures(workspaceRootURL: URL) {
        startBulkProcessing(workspaceRootURL: workspaceRootURL, uncategorizedOnly: true)
    }

    func reorganizeAllCaptures(workspaceRootURL: URL) {
        startBulkProcessing(workspaceRootURL: workspaceRootURL, uncategorizedOnly: false)
    }

    private func startBulkProcessing(
        workspaceRootURL: URL,
        uncategorizedOnly: Bool
    ) {
        guard bulkTask == nil else { return }

        bulkTask = Task {
            defer { bulkTask = nil }

            let records: [KnowledgeRecord]
            do {
                records = try knowledgeStore
                    .snapshot(workspaceRootURL: workspaceRootURL)
                    .records
                    .filter {
                        $0.typeID == "source"
                            && (!uncategorizedOnly || $0.topicIDs.isEmpty)
                    }
            } catch {
                publishFailure(sourceTitle: "Library", error: error)
                return
            }

            for record in records {
                guard !Task.isCancelled else { return }
                let sourcePath = record.fileURL.standardizedFileURL.path
                guard processingPaths.insert(sourcePath).inserted else { continue }
                await processAndPublish(record: record, workspaceRootURL: workspaceRootURL)
                processingPaths.remove(sourcePath)
            }
        }
    }

    private func processAndPublish(record: KnowledgeRecord, workspaceRootURL: URL) async {
        NotificationCenter.default.post(
            name: .processingDidStart,
            object: nil,
            userInfo: ["sourceTitle": record.title]
        )

        do {
            let availableTopics = try knowledgeStore
                .snapshot(workspaceRootURL: workspaceRootURL)
                .topics
            let suggestion = try await service.suggest(
                for: record,
                availableTopics: availableTopics,
                promptTemplate: settings.processingPrompt
            )
            try Task.checkCancellation()

            let taxonomyURL = workspaceRootURL.appendingPathComponent("topics.md")
            let topic = try TaxonomyStore().ensureTopic(
                named: suggestion.topicName,
                at: taxonomyURL
            )
            let newURL = try libraryStore.processSource(
                at: record.fileURL,
                workspaceRootURL: workspaceRootURL,
                suggestedFilename: suggestion.shortFilename,
                summaries: suggestion.summaries,
                topicID: topic.id
            )

            NotificationCenter.default.post(
                name: .processingDidFinish,
                object: nil,
                userInfo: [
                    "sourceTitle": record.title,
                    "sourcePath": record.fileURL.standardizedFileURL.path,
                    "processedPath": newURL.standardizedFileURL.path,
                    "topicName": topic.title
                ]
            )
            NotificationCenter.default.post(name: .libraryDidChange, object: nil)
        } catch is CancellationError {
            return
        } catch {
            publishFailure(sourceTitle: record.title, error: error)
        }
    }

    private func publishFailure(sourceTitle: String, error: Error) {
        NotificationCenter.default.post(
            name: .processingDidFail,
            object: nil,
            userInfo: [
                "sourceTitle": sourceTitle,
                "message": error.localizedDescription
            ]
        )
    }
}
