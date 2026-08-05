import AVFoundation
import AuthenticationServices
import BrieflyCore
import CloudKit
import CryptoKit
import Observation
import StoreKit
import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
import Carbon.HIToolbox
#elseif os(iOS)
import BackgroundTasks
import MediaPlayer
import UIKit
#endif

extension LibraryModel {
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
        guard let library else { return }
        do {
            for entryID in entryIDs {
                try await library.enqueueProcessingJob(
                    entryID: entryID,
                    selectWhenFinished: selectWhenFinished
                )
            }
            await drainProcessingQueue(trackingVoiceBriefEntries: trackingVoiceBriefEntries)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func drainProcessingQueue(
        trackingVoiceBriefEntries: Set<String> = []
    ) async {
        guard let library, !isProcessing else { return }
        isProcessing = true
        status = "Preparing summaries…"
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
                            voiceBriefGenerationProgress?.summarizedItemCount += 1
                        } else {
                            voiceBriefGenerationProgress?.failedItemCount += 1
                        }
                        updateContinuedVoiceBriefProgress()
                    }
                }
                activeTasks -= 1
                if !Task.isCancelled,
                   let job = try? await library.claimNextProcessingJob() {
                    activeTasks += 1
                    group.addTask { await self.process(job) }
                }
            }
        }
        isProcessing = false
        await refreshLibrary(selecting: selectedProcessedID)
        status = "Summaries ready"
        requestSync()
    }

    func requestSync() {
        pendingSync?.cancel()
        pendingSync = Task {
            try? await Task.sleep(for: .milliseconds(900))
            guard !Task.isCancelled else { return }
            await sync()
        }
    }

    func retrieveChannel(
        _ library: SQLiteLibraryStore,
        source: String,
        loadMore: Bool = false
    ) async throws -> LibraryChannelRefresh {
        let ingest: @Sendable (LibraryChannelCandidate) async throws -> String = {
            candidate in
            guard let url = URL(string: candidate.url) else {
                throw LibraryError.invalidChannel
            }
            return try await self.ingestURL(
                url,
                in: library,
                candidate: candidate
            )
        }
        let channel = libraryChannels.first { $0.source == source }
        let maximum = loadMore
            ? min(100, (channel?.items.count ?? 0) + (channel?.retrievalCount ?? 5))
            : nil
        return try await library.checkChannelInput(
            source,
            maximumItems: maximum,
            discover: { limit in
                try await NativeChannelInputRouter().enumerate(
                    source: source,
                    maximumItems: limit,
                    context: self.channelInputContext()
                )
            },
            ingest: ingest
        )
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

    func process(_ job: SQLiteProcessingJob) async -> ProcessingJobResult {
        guard let library else {
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
                template: processingPrompt
            )
            let output: String
            if usesManagedAI {
                output = try await backend.runManagedAI(
                    prompt: prompt,
                    format: "json"
                )
            } else {
                #if os(macOS)
                output = try await runProcessingCommand(
                    processingCommand,
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
            errorMessage = error.localizedDescription
            status = "The capture is saved without summaries"
            return ProcessingJobResult(
                entryID: entryID,
                selectedID: nil,
                succeeded: false
            )
        }
    }

}
