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
    @discardableResult
    func generateVoiceBrief(
        _ brief: LibraryVoiceBrief,
        selectEpisode: Bool,
        reportErrors: Bool,
        runAlreadyClaimed: Bool = false
    ) async -> Bool {
        guard let library else { return false }
        if runAlreadyClaimed {
            guard isRunningVoiceBrief else { return false }
        } else {
            guard !isRunningVoiceBrief else { return false }
            isRunningVoiceBrief = true
        }
        voiceBriefGenerationProgress = VoiceBriefGenerationProgress(
            voiceBriefID: brief.id,
            totalChannelCount: brief.sources.count
        )
        updateContinuedVoiceBriefProgress()
        defer {
            isRunningVoiceBrief = false
            voiceBriefGenerationProgress = nil
        }
        do {
            status = "Fetching channels for \(brief.title)…"
            var newEntryIDs = [String]()
            for source in brief.sources {
                do {
                    newEntryIDs += try await retrieveChannel(
                        library,
                        source: source
                    ).newEntryIDs
                } catch {
                    // A failed channel should not hide progress from the channels that succeeded.
                }
                if Task.isCancelled { throw CancellationError() }
                voiceBriefGenerationProgress?.checkedChannelCount += 1
                voiceBriefGenerationProgress?.retrievedItemCount = newEntryIDs.count
                updateContinuedVoiceBriefProgress()
            }
            projection = try await library.loadLibraryIndex()
            try await refreshChannels(from: library)
            voiceBriefGenerationProgress?.phase = .summarizing
            updateContinuedVoiceBriefProgress()
            await enqueueProcessing(
                newEntryIDs,
                trackingVoiceBriefEntries: Set(newEntryIDs)
            )
            try Task.checkCancellation()
            voiceBriefGenerationProgress?.phase = .assembling
            updateContinuedVoiceBriefProgress()
            status = "Assembling short and detailed versions of \(brief.title)…"
            let episode = try await library.runVoiceBrief(id: brief.id)
            projection = try await library.loadLibraryIndex()
            try await refreshChannels(from: library)
            if selectEpisode {
                selectedVoiceBriefID = brief.id
                await select(episode.entryID)
            }
            status = "Brief ready"
            completeContinuedVoiceBriefProgress()
            requestSync()
            return true
        } catch is CancellationError {
            status = "Brief preparation will resume when you try again"
            return false
        } catch {
            if reportErrors {
                errorMessage = error.localizedDescription
            } else {
                status = "\(brief.title): \(error.localizedDescription)"
            }
            return false
        }
    }

    #if os(iOS)
    @available(iOS 26.0, *)
    func submitContinuedVoiceBrief(_ brief: LibraryVoiceBrief) -> Bool {
        let identifier = Self.continuedVoiceBriefTaskPrefix + "." + UUID().uuidString
        let scheduler = BGTaskScheduler.shared
        let registered = scheduler.register(
            forTaskWithIdentifier: identifier,
            using: nil
        ) { [weak self] task in
            guard let task = task as? BGContinuedProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            Task { @MainActor [weak self] in
                self?.startContinuedVoiceBrief(task, brief: brief)
            }
        }
        guard registered else { return false }

        let request = BGContinuedProcessingTaskRequest(
            identifier: identifier,
            title: "Preparing \(brief.title)",
            subtitle: "Waiting to gather channel items"
        )
        request.strategy = .queue
        do {
            isRunningVoiceBrief = true
            voiceBriefGenerationProgress = VoiceBriefGenerationProgress(
                voiceBriefID: brief.id,
                totalChannelCount: brief.sources.count
            )
            status = "Waiting to prepare \(brief.title)…"
            try scheduler.submit(request)
            return true
        } catch {
            isRunningVoiceBrief = false
            voiceBriefGenerationProgress = nil
            return false
        }
    }

    @available(iOS 26.0, *)
    func startContinuedVoiceBrief(
        _ task: BGContinuedProcessingTask,
        brief: LibraryVoiceBrief
    ) {
        continuedVoiceBriefTask = task
        task.progress.totalUnitCount = 1_000
        task.progress.completedUnitCount = 0
        updateContinuedVoiceBriefProgress()
        task.expirationHandler = { [weak self] in
            Task { @MainActor [weak self] in
                try? await self?.library?.cancelVoiceBriefRun(id: brief.id)
                self?.continuedVoiceBriefWork?.cancel()
            }
        }

        continuedVoiceBriefWork = Task { @MainActor [weak self] in
            guard let self else {
                task.setTaskCompleted(success: false)
                return
            }
            let succeeded = await generateVoiceBrief(
                brief,
                selectEpisode: true,
                reportErrors: true,
                runAlreadyClaimed: true
            )
            task.setTaskCompleted(success: succeeded)
            continuedVoiceBriefTask = nil
            continuedVoiceBriefWork = nil
        }
    }
    #endif

    func updateContinuedVoiceBriefProgress() {
        #if os(iOS)
        guard #available(iOS 26.0, *),
              let task = continuedVoiceBriefTask as? BGContinuedProcessingTask,
              let progress = voiceBriefGenerationProgress
        else { return }

        let completed: Int64
        let subtitle: String
        switch progress.phase {
        case .retrieving:
            let total = max(1, progress.totalChannelCount)
            completed = Int64(200 * progress.checkedChannelCount / total)
            subtitle = "Checked \(progress.checkedChannelCount) of " +
                "\(progress.totalChannelCount) channels · " +
                "\(progress.retrievedItemCount) new items"
        case .summarizing:
            let processed = progress.summarizedItemCount + progress.failedItemCount
            let total = max(1, progress.retrievedItemCount)
            completed = 200 + Int64(600 * processed / total)
            subtitle = progress.retrievedItemCount == 0
                ? "No new items to summarize"
                : "Summarized \(processed) of \(progress.retrievedItemCount) items"
        case .assembling:
            completed = 850
            subtitle = "Writing short and detailed versions"
        }
        task.progress.completedUnitCount = completed
        task.updateTitle("Preparing your brief", subtitle: subtitle)
        #endif
    }

    func completeContinuedVoiceBriefProgress() {
        #if os(iOS)
        guard #available(iOS 26.0, *),
              let task = continuedVoiceBriefTask as? BGContinuedProcessingTask
        else { return }
        task.progress.completedUnitCount = task.progress.totalUnitCount
        task.updateTitle("Brief ready", subtitle: "Short and detailed versions are ready")
        #endif
    }

}
