import BrieflyCore
import Foundation
import Observation
#if os(iOS)
import BackgroundTasks
#endif

@MainActor
final class LibraryVoiceBriefWorkflow {
    private static let continuedVoiceBriefTaskPrefix = "fyi.readbriefly.voice-brief"

    let session: LibrarySession
    let navigation: LibraryNavigationModel
    let selection: LibrarySelectionModel
    let channels: LibraryChannelModel
    let processing: LibraryProcessingModel
    let settings: LibrarySettingsModel
    let voiceBriefs: LibraryVoiceBriefModel
    let audio: LibraryAudioModel
    let lifecycle: LibraryLifecycleModel

    private var pendingSync: Task<Void, Never>?

    #if os(iOS)
    @ObservationIgnored
    private var continuedVoiceBriefTask: AnyObject?
    @ObservationIgnored
    private var continuedVoiceBriefWork: Task<Void, Never>?
    #endif

    init(
        session: LibrarySession,
        navigation: LibraryNavigationModel,
        selection: LibrarySelectionModel,
        channels: LibraryChannelModel,
        processing: LibraryProcessingModel,
        settings: LibrarySettingsModel,
        voiceBriefs: LibraryVoiceBriefModel,
        audio: LibraryAudioModel,
        lifecycle: LibraryLifecycleModel
    ) {
        self.session = session
        self.navigation = navigation
        self.selection = selection
        self.channels = channels
        self.processing = processing
        self.settings = settings
        self.voiceBriefs = voiceBriefs
        self.audio = audio
        self.lifecycle = lifecycle
    }

    private var processingConfiguration: LibraryProcessingConfiguration {
        LibraryProcessingConfiguration(
            command: settings.processingCommand,
            prompt: settings.processingPrompt,
            usesManagedAI: settings.usesManagedAI
        )
    }

    func checkSelectedVoiceBriefChannels() async {
        guard
            let library = session.library,
            let brief = voiceBriefs.voiceBrief(for: navigation.selectedVoiceBriefID),
            !voiceBriefs.isRunningVoiceBrief
        else { return }
        voiceBriefs.isRunningVoiceBrief = true
        defer { voiceBriefs.isRunningVoiceBrief = false }
        do {
            session.status = "Checking \(brief.sources.count) " +
                (brief.sources.count == 1 ? "channel…" : "channels…")
            var newEntryIDs = [String]()
            var channelErrors = [String]()
            for source in brief.sources {
                do {
                    let result = try await channels.retrieveChannel(library, source: source)
                    newEntryIDs += result.newEntryIDs
                    if let error = result.channel.error { channelErrors.append(error) }
                } catch {
                    channelErrors.append(error.localizedDescription)
                }
            }
            session.projection = try await library.loadLibraryIndex()
            try await channels.refreshChannels(from: library)
            session.status = newEntryIDs.isEmpty
                ? "Channels checked. No new items."
                : "Prepared \(newEntryIDs.count) new " +
                    (newEntryIDs.count == 1 ? "item" : "items")
            if let error = channelErrors.first { session.errorMessage = error }
        } catch {
            session.errorMessage = error.localizedDescription
        }
    }

    func runSelectedVoiceBrief() async {
        guard let brief = voiceBriefs.voiceBrief(for: navigation.selectedVoiceBriefID) else { return }
        do {
            try await session.library?.queueVoiceBriefRun(id: brief.id)
        } catch {
            session.errorMessage = error.localizedDescription
            return
        }
        #if os(iOS)
        if #available(iOS 26.0, *), submitContinuedVoiceBrief(brief) {
            return
        }
        #endif
        await generateVoiceBrief(brief, selectEpisode: true, reportErrors: true)
    }

    func resumePendingVoiceBriefs() async {
        guard
            let library = session.library,
            !voiceBriefs.isRunningVoiceBrief,
            !audio.isGeneratingSpeech
        else { return }
        guard let pending = try? await library.pendingVoiceBriefIDs() else { return }
        for id in pending {
            guard let brief = voiceBriefs.voiceBrief(for: id) else { continue }
            await generateVoiceBrief(brief, selectEpisode: false, reportErrors: false)
        }
    }

    func runDueVoiceBriefs() async {
        guard
            let library = session.library,
            !voiceBriefs.isRunningVoiceBrief,
            !audio.isGeneratingSpeech
        else { return }
        do {
            let due = try await library.dueVoiceBriefIDs()
            for id in due {
                guard let brief = voiceBriefs.voiceBrief(for: id) else { continue }
                try await library.markVoiceBriefAttempt(id: id)
                try await library.queueVoiceBriefRun(id: id)
                await generateVoiceBrief(brief, selectEpisode: false, reportErrors: false)
            }
        } catch {
            session.status = "Scheduled voice briefs will retry later"
        }
    }

    @discardableResult
    func saveVoiceBrief(_ draft: LibraryVoiceBriefDraft) async -> String? {
        guard let library = session.library else {
            session.errorMessage = "Open a Briefly library before editing voice briefs."
            return nil
        }
        do {
            let id = try await library.saveVoiceBrief(draft)
            session.projection = try await library.loadLibraryIndex()
            try await channels.refreshChannels(from: library)
            navigation.activeSection = .briefs
            selection.clear()
            navigation.selectedVoiceBriefID = id
            session.status = "Voice brief saved"
            requestSync()
            return id
        } catch {
            session.errorMessage = error.localizedDescription
            return nil
        }
    }

    func trashSelectedVoiceBrief() async {
        guard
            let library = session.library,
            !navigation.selectedVoiceBriefID.isEmpty,
            navigation.selectedVoiceBriefID != "new"
        else { return }
        let id = navigation.selectedVoiceBriefID
        do {
            try await library.moveVoiceBriefToTrash(id: id)
            session.projection = try await library.loadLibraryIndex()
            try await channels.refreshChannels(from: library)
            navigation.selectedVoiceBriefID = ""
            navigation.showingVoiceBriefSettings = false
            selection.clear()
            session.status = "Voice brief moved to Trash"
            requestSync()
        } catch {
            session.errorMessage = error.localizedDescription
        }
    }

    @discardableResult
    private func generateVoiceBrief(
        _ brief: LibraryVoiceBrief,
        selectEpisode: Bool,
        reportErrors: Bool,
        runAlreadyClaimed: Bool = false
    ) async -> Bool {
        guard let library = session.library else { return false }
        if runAlreadyClaimed {
            guard voiceBriefs.isRunningVoiceBrief else { return false }
        } else {
            guard voiceBriefs.beginGeneration(for: brief) else { return false }
        }
        defer { voiceBriefs.finishGeneration() }
        updateContinuedVoiceBriefProgress()
        do {
            session.status = "Fetching channels for \(brief.title)…"
            var newEntryIDs = [String]()
            for source in brief.sources {
                do {
                    newEntryIDs += try await channels.retrieveChannel(
                        library,
                        source: source
                    ).newEntryIDs
                } catch {
                    // A failed channel should not hide progress from the channels that succeeded.
                }
                if Task.isCancelled { throw CancellationError() }
                voiceBriefs.voiceBriefGenerationProgress?.checkedChannelCount += 1
                voiceBriefs.voiceBriefGenerationProgress?.retrievedItemCount = newEntryIDs.count
                updateContinuedVoiceBriefProgress()
            }
            session.projection = try await library.loadLibraryIndex()
            try await channels.refreshChannels(from: library)
            voiceBriefs.voiceBriefGenerationProgress?.phase = .summarizing
            updateContinuedVoiceBriefProgress()
            let results = await processing.enqueueProcessing(
                newEntryIDs,
                configuration: processingConfiguration
            )
            for result in results where newEntryIDs.contains(result.entryID) {
                if result.succeeded {
                    voiceBriefs.voiceBriefGenerationProgress?.summarizedItemCount += 1
                } else {
                    voiceBriefs.voiceBriefGenerationProgress?.failedItemCount += 1
                }
                updateContinuedVoiceBriefProgress()
            }
            try Task.checkCancellation()
            voiceBriefs.voiceBriefGenerationProgress?.phase = .assembling
            updateContinuedVoiceBriefProgress()
            session.status = "Assembling short and detailed versions of \(brief.title)…"
            let episode = try await library.runVoiceBrief(id: brief.id)
            session.projection = try await library.loadLibraryIndex()
            try await channels.refreshChannels(from: library)
            if selectEpisode {
                navigation.selectedVoiceBriefID = brief.id
                await selection.select(episode.entryID)
            }
            session.status = "Brief ready"
            #if os(iOS)
            if #available(iOS 26.0, *) {
                completeContinuedVoiceBriefProgress()
            }
            #else
            completeContinuedVoiceBriefProgress()
            #endif
            requestSync()
            return true
        } catch is CancellationError {
            session.status = "Brief preparation will resume when you try again"
            return false
        } catch {
            if reportErrors {
                session.errorMessage = error.localizedDescription
            } else {
                session.status = "\(brief.title): \(error.localizedDescription)"
            }
            return false
        }
    }

    private func requestSync() {
        pendingSync?.cancel()
        pendingSync = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(900))
            guard !Task.isCancelled else { return }
            await self?.lifecycle.sync()
        }
    }

    func updateContinuedVoiceBriefProgress() {
        #if os(iOS)
        guard #available(iOS 26.0, *),
              let task = continuedVoiceBriefTask as? BGContinuedProcessingTask,
              let progress = voiceBriefs.voiceBriefGenerationProgress
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

    #if os(iOS)
    @available(iOS 26.0, *)
    private func submitContinuedVoiceBrief(_ brief: LibraryVoiceBrief) -> Bool {
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
            guard voiceBriefs.beginGeneration(for: brief) else { return false }
            session.status = "Waiting to prepare \(brief.title)…"
            try scheduler.submit(request)
            return true
        } catch {
            voiceBriefs.finishGeneration()
            return false
        }
    }

    @available(iOS 26.0, *)
    private func startContinuedVoiceBrief(
        _ task: BGContinuedProcessingTask,
        brief: LibraryVoiceBrief
    ) {
        continuedVoiceBriefTask = task
        task.progress.totalUnitCount = 1_000
        task.progress.completedUnitCount = 0
        updateContinuedVoiceBriefProgress()
        task.expirationHandler = { [weak self] in
            Task { @MainActor [weak self] in
                try? await self?.session.library?.cancelVoiceBriefRun(id: brief.id)
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

    @available(iOS 26.0, *)
    private func completeContinuedVoiceBriefProgress() {
        guard let task = continuedVoiceBriefTask as? BGContinuedProcessingTask else { return }
        task.progress.completedUnitCount = task.progress.totalUnitCount
        task.updateTitle("Brief ready", subtitle: "Short and detailed versions are ready")
    }
    #else
    private func completeContinuedVoiceBriefProgress() {}
    #endif
}
