import BrieflyCore
import CryptoKit
import Foundation
import Observation

@MainActor
@Observable
final class LibraryProcessingModel {
    let session: LibrarySession
    let navigation: LibraryNavigationModel
    let selection: LibrarySelectionModel
    let settings: LibrarySettingsModel

    weak var lifecycle: LibraryLifecycleModel?
    weak var voiceBriefs: LibraryVoiceBriefModel?

    var isIngesting = false
    var isProcessing = false

    init(
        session: LibrarySession,
        navigation: LibraryNavigationModel,
        selection: LibrarySelectionModel,
        settings: LibrarySettingsModel
    ) {
        self.session = session
        self.navigation = navigation
        self.selection = selection
        self.settings = settings
    }

    func processSelected() async {
        guard !selection.selectedID.isEmpty else { return }
        await enqueueProcessing(selection.selectedID)
    }

    func enqueueProcessing(
        _ entryID: String,
        selectWhenFinished: Bool = true
    ) async {
        await enqueueProcessing([entryID], selectWhenFinished: selectWhenFinished)
    }

    func enqueueProcessing(
        _ entryIDs: [String],
        selectWhenFinished: Bool = false,
        trackingVoiceBriefEntries: Set<String> = []
    ) async {
        guard let library = session.library else { return }
        do {
            for entryID in entryIDs {
                try await library.enqueueProcessingJob(
                    entryID: entryID,
                    selectWhenFinished: selectWhenFinished
                )
            }
            await drainProcessingQueue(trackingVoiceBriefEntries: trackingVoiceBriefEntries)
        } catch {
            session.errorMessage = error.localizedDescription
        }
    }

    func drainProcessingQueue(
        trackingVoiceBriefEntries: Set<String> = []
    ) async {
        guard let library = session.library, !isProcessing else { return }
        isProcessing = true
        session.status = "Preparing summaries…"
        var selectedProcessedID: String?
        await withTaskGroup(of: ProcessingJobResult.self) { group in
            var activeTasks = 0

            for _ in 0..<3 {
                guard let job = try? await library.claimNextProcessingJob() else { break }
                activeTasks += 1
                group.addTask { await self.process(job) }
            }

            while activeTasks > 0 {
                if Task.isCancelled { group.cancelAll() }
                if let result = await group.next() {
                    if let processedID = result.selectedID {
                        selectedProcessedID = processedID
                    }
                    if trackingVoiceBriefEntries.contains(result.entryID) {
                        if result.succeeded {
                            voiceBriefs?.voiceBriefGenerationProgress?.summarizedItemCount += 1
                        } else {
                            voiceBriefs?.voiceBriefGenerationProgress?.failedItemCount += 1
                        }
                        voiceBriefs?.updateContinuedVoiceBriefProgress()
                    }
                }
                activeTasks -= 1
                if !Task.isCancelled,
                   let job = try? await library.claimNextProcessingJob()
                {
                    activeTasks += 1
                    group.addTask { await self.process(job) }
                }
            }
        }
        isProcessing = false
        if let lifecycle {
            await lifecycle.refreshLibrary(selecting: selectedProcessedID)
            lifecycle.requestSync()
        }
        session.status = "Summaries ready"
    }

    func capture(_ text: String) async {
        guard let library = session.library else {
            session.errorMessage = "Open a Briefly library before capturing."
            return
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
            var request = ItemInputRequest(source: url.map(ItemInputSource.url) ?? .text(trimmed))
            request.retainAudio = UserDefaults.standard.bool(forKey: "BrieflySaveCapturedAudio") &&
                router.inputID(for: request) == .youtube
            let draft = try await router.ingest(request, context: itemInputContext())
            let id = try await library.captureItem(draft)
            if let lifecycle {
                await lifecycle.refreshLibrary(selecting: id)
            }
            navigation.activeSection = .items
            if session.environment.isUITesting {
                session.status = "Captured"
                return
            }
            session.status = "Captured. Preparing summaries…"
            isIngesting = false
            await enqueueProcessing(id)
            lifecycle?.requestSync()
        } catch {
            session.errorMessage = error.localizedDescription
        }
    }

    func setBrowserIngesting(_ ingesting: Bool) {
        isIngesting = ingesting
        if ingesting {
            session.status = "Extracting the signed-in page…"
        }
    }

    func captureWebPage(url: URL, page: SignedInChannelPage) async {
        guard let library = session.library else {
            session.errorMessage = "Open a Briefly library before saving web pages."
            return
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
            if let lifecycle {
                await lifecycle.refreshLibrary(selecting: id)
            }
            session.status = "Saved the signed-in page. Preparing summaries…"
            isIngesting = false
            await enqueueProcessing(id)
            lifecycle?.requestSync()
        } catch {
            session.errorMessage = error.localizedDescription
        }
    }

    func capturePDF(_ url: URL) async {
        guard let library = session.library else {
            session.errorMessage = "Choose a local Briefly library before importing a PDF."
            return
        }
        isIngesting = true
        defer { isIngesting = false }
        let hasAccess = url.startAccessingSecurityScopedResource()
        defer {
            if hasAccess { url.stopAccessingSecurityScopedResource() }
        }
        do {
            let draft = try await NativeItemInputRouter().ingest(
                ItemInputRequest(source: .file(url)),
                context: itemInputContext()
            )
            let entryID = try await library.captureItem(draft)
            if let lifecycle {
                await lifecycle.refreshLibrary(selecting: entryID)
            }
            session.status = "PDF captured. Preparing summaries…"
            isIngesting = false
            await enqueueProcessing(entryID)
            lifecycle?.requestSync()
        } catch {
            session.errorMessage = error.localizedDescription
        }
    }

    func ingestURL(
        _ url: URL,
        in library: SQLiteLibraryStore,
        candidate: LibraryChannelCandidate? = nil
    ) async throws -> String {
        let hints = ItemInputHints(
            preferredInput: candidate?.preferredInput,
            title: candidate?.title,
            content: candidate?.content,
            mediaURL: candidate?.mediaURL.flatMap(URL.init(string:)),
            transcriptURL: candidate?.transcriptURL.flatMap(URL.init(string:)),
            transcriptType: candidate?.transcriptType,
            transcriptLanguage: candidate?.transcriptLanguage
        )
        let draft = try await NativeItemInputRouter().ingest(
            ItemInputRequest(source: .url(url), hints: hints),
            context: itemInputContext()
        )
        return try await library.captureItem(draft, asVoiceBriefSource: true)
    }

    func itemInputContext() -> ItemInputContext {
        .init(
            render: { url in
                let page = try await ChannelBrowserSession.shared.extractPage(from: url)
                return RenderedInputPage(
                    title: page.title,
                    content: page.text,
                    sourceURL: url,
                    faviconData: page.faviconData,
                    faviconFileExtension: page.faviconFileExtension
                )
            },
            firecrawl: { try await BrieflyBackend.shared.firecrawl($0) },
            transcribe: { try await BrieflyBackend.shared.transcribe($0) },
            downloadAudio: { try await BrieflyBackend.shared.downloadAudio($0) }
        )
    }

    func channelInputContext() -> ChannelInputContext {
        .init(render: { url, limit in
            let page = try await ChannelBrowserSession.shared.extractPage(from: url)
            let host = url.host?.lowercased() ?? ""
            let isX = host == "x.com" || host.hasSuffix(".x.com") || host.contains("twitter.com")
            if !page.items.isEmpty {
                return ChannelInputBatch(
                    inputID: isX ? .x : .page,
                    title: page.title,
                    kind: .page,
                    items: page.items.prefix(limit).compactMap { item in
                        guard let itemURL = URL(string: item.url) else { return nil }
                        return ChannelItemReference(
                            id: item.id,
                            title: item.title,
                            url: itemURL,
                            publishedAt: item.publishedAt,
                            hints: .init(
                                preferredInput: isX ? .x : .webPage,
                                title: item.title,
                                content: item.content
                            )
                        )
                    }
                )
            }
            let digest = SHA256.hash(data: Data(page.text.utf8))
                .map { String(format: "%02x", $0) }.joined()
            return ChannelInputBatch(
                inputID: isX ? .x : .page,
                title: page.title,
                kind: .page,
                items: [.init(
                    id: digest,
                    title: page.title,
                    url: url,
                    hints: .init(
                        preferredInput: .webPage,
                        title: page.title,
                        content: page.text
                    )
                )]
            )
        })
    }

    private func process(_ job: SQLiteProcessingJob) async -> ProcessingJobResult {
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
                template: settings.processingPrompt
            )
            let output: String
            if settings.usesManagedAI {
                output = try await session.backend.runManagedAI(
                    prompt: prompt,
                    format: "json"
                )
            } else {
                #if os(macOS)
                output = try await runProcessingCommand(
                    settings.processingCommand,
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
