#if os(macOS)
import BrieflyCore
import Foundation
import Observation

struct LibraryProcessingConfiguration: Sendable {
    let prompt: String
    let openRouterAPIKey: String?
    let modelID: String
    let reasoningEffort: String?
    let model: OpenRouterModel?
}

@MainActor
@Observable
final class LibraryProcessingModel {
    let session: LibrarySession
    let inputService: LibraryInputService

    var isProcessing = false
    var onStateChanged: (@MainActor @Sendable () async -> Void)?

    init(session: LibrarySession, inputService: LibraryInputService) {
        self.session = session
        self.inputService = inputService
    }

    func enqueueProcessing(
        _ entryIDs: [String],
        selectWhenFinished: Bool = false,
        configuration: LibraryProcessingConfiguration
    ) async -> [ProcessingJobResult] {
        guard let library = session.library else { return [] }
        do {
            for entryID in entryIDs {
                let document = try await library.getDocument(entryID)
                if var request = document.captureRequest {
                    guard request.hasExtractedSource else { continue }
                    request.state = .summarizing
                    request.error = nil
                    _ = try await library.batch([.init(
                        id: entryID, baseRevision: document.revision, captureRequest: request
                    )])
                }
                try await library.enqueueProcessingJob(
                    entryID: entryID,
                    selectWhenFinished: selectWhenFinished
                )
            }
            return await drainProcessingQueue(
                configuration: configuration
            )
        } catch {
            session.errorMessage = error.localizedDescription
            return []
        }
    }

    func drainProcessingQueue(
        configuration: LibraryProcessingConfiguration
    ) async -> [ProcessingJobResult] {
        guard let library = session.library, !isProcessing else { return [] }
        isProcessing = true
        session.status = "Preparing summaries…"
        defer { isProcessing = false }

        do {
            for id in try await library.pendingCaptureIDs() {
                do {
                    try await library.extractQueuedCapture(
                        id, context: inputService.itemInputContext(),
                        extract: { [inputService] request in
                            try await inputService.captureCoordinator.extractSource(
                                request, context: inputService.itemInputContext()
                            )
                        },
                        onStateChanged: onStateChanged ?? {}
                    )
                } catch {
                    session.errorMessage = error.localizedDescription
                }
            }
        } catch { session.errorMessage = error.localizedDescription }

        var results = [ProcessingJobResult]()
        await withTaskGroup(of: ProcessingJobResult.self) { group in
            var activeTasks = 0

            for _ in 0..<3 {
                guard let job = try? await library.claimNextProcessingJob() else { break }
                activeTasks += 1
                group.addTask { await self.process(job, configuration: configuration) }
            }

            while activeTasks > 0 {
                if Task.isCancelled { group.cancelAll() }
                if let result = await group.next() {
                    results.append(result)
                }
                activeTasks -= 1
                if !Task.isCancelled,
                   let job = try? await library.claimNextProcessingJob()
                {
                    activeTasks += 1
                    group.addTask { await self.process(job, configuration: configuration) }
                }
            }
        }
        session.status = "Summaries ready"
        return results
    }

    private func process(
        _ job: SQLiteProcessingJob,
        configuration: LibraryProcessingConfiguration
    ) async -> ProcessingJobResult {
        guard let library = session.library else {
            return ProcessingJobResult(
                entryID: job.documentID,
                selectedID: nil,
                succeeded: false
            )
        }
        let entryID = job.documentID
        do {
            if try await library.getDocument(entryID).captureRequest?.state == .ready {
                try await library.completeProcessingJob(entryID: entryID)
                return ProcessingJobResult(entryID: entryID, selectedID: nil, succeeded: true)
            }
            let prompt = try await library.processingPrompt(
                entryID: entryID,
                template: configuration.prompt
            )
            guard let apiKey = configuration.openRouterAPIKey, !apiKey.isEmpty else {
                throw BrieflyBackendError.message("Connect to OpenRouter in Settings → AI Processing to create summaries.")
            }
            let output = try await runOpenRouterProcessing(
                prompt: prompt, format: "json", apiKey: apiKey,
                modelID: configuration.modelID, reasoningEffort: configuration.reasoningEffort,
                model: configuration.model
            )
            let suggestion = try ProcessingSuggestion.decode(output)
            let processedID = try await library.applyProcessingSuggestion(
                entryID: entryID,
                suggestion: suggestion
            )
            try await library.completeProcessingJob(entryID: entryID)
            return ProcessingJobResult(
                entryID: entryID,
                selectedID: job.selectWhenFinished ? processedID : nil,
                succeeded: true
            )
        } catch is CancellationError {
            try? await library.enqueueProcessingJob(
                entryID: entryID,
                selectWhenFinished: job.selectWhenFinished
            )
            return ProcessingJobResult(
                entryID: entryID,
                selectedID: nil,
                succeeded: false
            )
        } catch {
            try? await library.failCapture(entryID, error: error.localizedDescription)
            try? await library.failProcessingJob(
                entryID: entryID,
                error: error.localizedDescription
            )
            session.errorMessage = error.localizedDescription
            session.status = "The capture is saved without summaries"
            return ProcessingJobResult(
                entryID: entryID,
                selectedID: nil,
                succeeded: false
            )
        }
    }
}

#endif
