import BrieflyCore
import Foundation
import Observation

struct LibraryProcessingConfiguration: Sendable {
    let command: String
    let prompt: String
    let usesManagedAI: Bool
}

@MainActor
@Observable
final class LibraryProcessingModel {
    let session: LibrarySession
    let inputService: LibraryInputService

    var isIngesting = false
    var isProcessing = false

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

    @discardableResult
    func capture(_ text: String) async -> String? {
        guard let library = session.library else {
            session.errorMessage = "Open a Briefly library before capturing."
            return nil
        }
        isIngesting = true
        defer { isIngesting = false }
        do {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let url = URL(string: trimmed).flatMap {
                ["http", "https"].contains($0.scheme?.lowercased() ?? "") &&
                    $0.host != nil &&
                    !trimmed.contains(where: \.isWhitespace)
                    ? $0
                    : nil
            }
            session.status = url == nil ? "Capturing text…" : "Extracting the item…"
            let router = NativeItemInputRouter()
            let request = ItemInputRequest(source: url.map(ItemInputSource.url) ?? .text(trimmed))
            let draft = try await router.ingest(request, context: inputService.itemInputContext())
            let id = try await library.captureItem(draft)
            session.status = "Captured"
            return id
        } catch {
            session.errorMessage = error.localizedDescription
            return nil
        }
    }

    func setBrowserIngesting(_ ingesting: Bool) {
        isIngesting = ingesting
        if ingesting {
            session.status = "Extracting the signed-in page…"
        }
    }

    @discardableResult
    func captureWebPage(url: URL, page: SignedInChannelPage) async -> String? {
        guard let library = session.library else {
            session.errorMessage = "Open a Briefly library before saving web pages."
            return nil
        }
        isIngesting = true
        defer { isIngesting = false }
        do {
            let id = try await library.captureItem(ItemDraft(
                inputID: .webPage,
                title: page.title,
                content: page.text,
                sourceURL: url,
                canonicalURL: url,
                faviconData: page.faviconData,
                faviconFileExtension: page.faviconFileExtension
            ))
            session.status = "Saved the signed-in page"
            return id
        } catch {
            session.errorMessage = error.localizedDescription
            return nil
        }
    }

    @discardableResult
    func capturePDF(_ url: URL) async -> String? {
        guard let library = session.library else {
            session.errorMessage = "Choose a local Briefly library before importing a PDF."
            return nil
        }
        isIngesting = true
        defer { isIngesting = false }
        let hasAccess = url.startAccessingSecurityScopedResource()
        defer {
            if hasAccess { url.stopAccessingSecurityScopedResource() }
        }
        do {
            let draft = try await inputService.ingestPDF(url)
            let entryID = try await library.captureItem(draft)
            session.status = "PDF captured"
            return entryID
        } catch {
            session.errorMessage = error.localizedDescription
            return nil
        }
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
            let prompt = try await library.processingPrompt(
                entryID: entryID,
                template: configuration.prompt
            )
            let output: String
            if configuration.usesManagedAI {
                output = try await session.backend.runManagedAI(
                    prompt: prompt,
                    format: "json"
                )
            } else {
                #if os(macOS)
                output = try await runProcessingCommand(
                    configuration.command,
                    prompt: prompt
                )
                #else
                throw LibraryError.processingUnavailable
                #endif
            }
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
