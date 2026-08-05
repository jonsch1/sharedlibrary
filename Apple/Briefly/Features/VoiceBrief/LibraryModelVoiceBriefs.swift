import BrieflyCore
import Observation
#if os(iOS)
import BackgroundTasks
#endif

@MainActor
@Observable
final class LibraryVoiceBriefModel {
    private static let continuedVoiceBriefTaskPrefix = "fyi.readbriefly.voice-brief"

    let session: LibrarySession
    weak var navigation: LibraryNavigationModel?
    weak var selection: LibrarySelectionModel?
    weak var channels: LibraryChannelModel?
    weak var processing: LibraryProcessingModel?
    weak var lifecycle: LibraryLifecycleModel?
    weak var audio: LibraryAudioModel?

    var isRunningVoiceBrief = false
    var voiceBriefGenerationProgress: VoiceBriefGenerationProgress?

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
        processing: LibraryProcessingModel
    ) {
        self.session = session
        self.navigation = navigation
        self.selection = selection
        self.channels = channels
        self.processing = processing
    }

    var selectedVoiceBrief: LibraryVoiceBrief? {
        guard let id = navigation?.selectedVoiceBriefID, !id.isEmpty else { return nil }
        return session.projection.voiceBriefDefinitions.first { $0.id == id }
    }

    func checkSelectedVoiceBriefChannels() async {
        guard
            let library = session.library,
            let brief = selectedVoiceBrief,
            !isRunningVoiceBrief
        else { return }
        isRunningVoiceBrief = true
        defer { isRunningVoiceBrief = false }
        do {
            session.status = "Checking \(brief.sources.count) " +
                (brief.sources.count == 1 ? "channel…" : "channels…")
            var newEntryIDs = [String]()
            var channelErrors = [String]()
            for source in brief.sources {
                do {
                    let result = try await channels?.retrieveChannel(library, source: source)
                    newEntryIDs += result?.newEntryIDs ?? []
                    if let error = result?.channel.error { channelErrors.append(error) }
                } catch {
                    channelErrors.append(error.localizedDescription)
                }
            }
            session.projection = try await library.loadLibraryIndex()
            try await channels?.refreshChannels(from: library)
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
        guard let brief = selectedVoiceBrief else { return }
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
            !isRunningVoiceBrief,
            audio?.isGeneratingSpeech != true
        else { return }
        guard let pending = try? await library.pendingVoiceBriefIDs() else { return }
        for id in pending {
            guard let brief = session.projection.voiceBriefDefinitions.first(where: { $0.id == id })
            else { continue }
            await generateVoiceBrief(brief, selectEpisode: false, reportErrors: false)
        }
    }

    func runDueVoiceBriefs() async {
        guard
            let library = session.library,
            !isRunningVoiceBrief,
            audio?.isGeneratingSpeech != true
        else { return }
        do {
            let due = try await library.dueVoiceBriefIDs()
            for id in due {
                guard let brief = session.projection.voiceBriefDefinitions.first(where: { $0.id == id })
                else { continue }
                try await library.markVoiceBriefAttempt(id: id)
                try await library.queueVoiceBriefRun(id: id)
                await generateVoiceBrief(brief, selectEpisode: false, reportErrors: false)
            }
        } catch {
            session.status = "Scheduled voice briefs will retry later"
        }
    }

    @discardableResult
    func generateVoiceBrief(
        _ brief: LibraryVoiceBrief,
        selectEpisode: Bool,
        reportErrors: Bool,
        runAlreadyClaimed: Bool = false
    ) async -> Bool {
        guard let library = session.library else { return false }
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
            session.status = "Fetching channels for \(brief.title)…"
            var newEntryIDs = [String]()
            for source in brief.sources {
                do {
                    newEntryIDs += try await channels?.retrieveChannel(
                        library,
                        source: source
                    ).newEntryIDs ?? []
                } catch {
                    // A failed channel should not hide progress from the channels that succeeded.
                }
                if Task.isCancelled { throw CancellationError() }
                voiceBriefGenerationProgress?.checkedChannelCount += 1
                voiceBriefGenerationProgress?.retrievedItemCount = newEntryIDs.count
                updateContinuedVoiceBriefProgress()
            }
            session.projection = try await library.loadLibraryIndex()
            try await channels?.refreshChannels(from: library)
            voiceBriefGenerationProgress?.phase = .summarizing
            updateContinuedVoiceBriefProgress()
            await processing?.enqueueProcessing(
                newEntryIDs,
                trackingVoiceBriefEntries: Set(newEntryIDs)
            )
            try Task.checkCancellation()
            voiceBriefGenerationProgress?.phase = .assembling
            updateContinuedVoiceBriefProgress()
            session.status = "Assembling short and detailed versions of \(brief.title)…"
            let episode = try await library.runVoiceBrief(id: brief.id)
            session.projection = try await library.loadLibraryIndex()
            try await channels?.refreshChannels(from: library)
            if selectEpisode {
                navigation?.selectedVoiceBriefID = brief.id
                await selection?.select(episode.entryID)
            }
            session.status = "Brief ready"
            completeContinuedVoiceBriefProgress()
            lifecycle?.requestSync()
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

    @discardableResult
    func saveVoiceBrief(_ draft: LibraryVoiceBriefDraft) async -> String? {
        guard let library = session.library else {
            session.errorMessage = "Open a Briefly library before editing voice briefs."
            return nil
        }
        do {
            let id = try await library.saveVoiceBrief(draft)
            session.projection = try await library.loadLibraryIndex()
            try await channels?.refreshChannels(from: library)
            navigation?.activeSection = .briefs
            selection?.clear()
            navigation?.selectedVoiceBriefID = id
            session.status = "Voice brief saved"
            lifecycle?.requestSync()
            return id
        } catch {
            session.errorMessage = error.localizedDescription
            return nil
        }
    }

    func trashSelectedVoiceBrief() async {
        guard
            let library = session.library,
            let id = navigation?.selectedVoiceBriefID,
            !id.isEmpty,
            id != "new"
        else { return }
        do {
            try await library.moveVoiceBriefToTrash(id: id)
            session.projection = try await library.loadLibraryIndex()
            try await channels?.refreshChannels(from: library)
            navigation?.selectedVoiceBriefID = ""
            navigation?.showingVoiceBriefSettings = false
            selection?.clear()
            session.status = "Voice brief moved to Trash"
            lifecycle?.requestSync()
        } catch {
            session.errorMessage = error.localizedDescription
        }
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
            isRunningVoiceBrief = true
            voiceBriefGenerationProgress = VoiceBriefGenerationProgress(
                voiceBriefID: brief.id,
                totalChannelCount: brief.sources.count
            )
            session.status = "Waiting to prepare \(brief.title)…"
            try scheduler.submit(request)
            return true
        } catch {
            isRunningVoiceBrief = false
            voiceBriefGenerationProgress = nil
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

    private func completeContinuedVoiceBriefProgress() {
        #if os(iOS)
        guard #available(iOS 26.0, *),
              let task = continuedVoiceBriefTask as? BGContinuedProcessingTask
        else { return }
        task.progress.completedUnitCount = task.progress.totalUnitCount
        task.updateTitle("Brief ready", subtitle: "Short and detailed versions are ready")
        #endif
    }
}
