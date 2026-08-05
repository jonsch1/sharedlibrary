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
    func stageChannelSource(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let candidate = if trimmed.contains("://") { trimmed } else { "https://\(trimmed)" }
        guard let url = URL(string: candidate), ["http", "https"].contains(url.scheme) else {
            errorMessage = LibraryError.invalidChannel.localizedDescription
            return
        }
        let normalized = url.absoluteString
        guard !newChannelSources.contains(normalized) else { return }
        newChannelSources.append(normalized)
    }

    func removeStagedChannelSource(_ source: String) {
        newChannelSources.removeAll { $0 == source }
    }

    func addChannel(_ source: String) async {
        stageChannelSource(source)
        await createChannel()
    }

    func createChannel() async {
        guard let library else {
            errorMessage = "Open a Briefly library before adding channels."
            return
        }
        guard !newChannelSources.isEmpty else { return }
        do {
            let groupID = try await library.addChannel(newChannelSources)
            try await refreshChannels(from: library)
            guard let added = libraryChannels.first(where: { $0.source == groupID }) else {
                throw LibraryError.missingChannel
            }
            selectedChannelSource = added.source
            newChannelSources = []
            showingChannelSettings = false
            status = added.sources.count == 1
                ? "Channel added"
                : "Channel added with \(added.sources.count) sources"
            requestSync()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func updateSelectedChannel(
        title: String,
        sources: [String],
        retrievalCount: Int,
        autoSummarize: Bool,
        schedule: String
    ) async {
        guard let library, let channel = selectedChannel else { return }
        do {
            try await library.updateChannelGroup(
                channel.source,
                title: title,
                sources: sources,
                retrievalCount: retrievalCount,
                autoSummarize: autoSummarize,
                schedule: schedule
            )
            try await refreshChannels(from: library)
            status = "Channel settings saved"
            requestSync()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func checkSelectedChannel(loadMore: Bool = false) async {
        guard
            let library,
            let channel = selectedChannel,
            !isCheckingChannel
        else {
            return
        }
        isCheckingChannel = true
        status = loadMore ? "Loading more from \(channel.title)…" : "Checking \(channel.title)…"
        defer { isCheckingChannel = false }
        do {
            var newEntryIDs = [String]()
            var lastError: Error?
            for source in channel.sources {
                do {
                    let result = try await retrieveChannel(
                        library,
                        source: source,
                        loadMore: loadMore
                    )
                    newEntryIDs.append(contentsOf: result.newEntryIDs)
                } catch {
                    lastError = error
                }
            }
            projection = try await library.loadLibraryIndex()
            try await refreshChannels(from: library)
            selectedChannelSource = channel.source
            if let lastError {
                errorMessage = lastError.localizedDescription
                status = newEntryIDs.isEmpty
                    ? "Channel check failed."
                    : "Gathered \(newEntryIDs.count) items; some sources failed and will retry."
            } else {
                status = newEntryIDs.isEmpty
                    ? "Channel checked. No new items."
                    : "Gathered \(newEntryIDs.count) new " +
                        (newEntryIDs.count == 1 ? "item" : "items")
            }
            if channel.autoSummarize {
                await enqueueProcessing(newEntryIDs)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func removeSelectedChannel() async {
        guard let library, let channel = selectedChannel else { return }
        do {
            let deletedItemCount = try await library.removeChannelGroup(channel.source)
            projection = try await library.loadLibraryIndex()
            try await refreshChannels(from: library)
            selectedChannelSource = ""
            showingChannelSettings = false
            selectedID = ""
            selectedIDs = []
            status = deletedItemCount == 1
                ? "Channel removed and 1 downloaded item deleted"
                : "Channel removed and \(deletedItemCount) downloaded items deleted"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func checkSelectedVoiceBriefChannels() async {
        guard
            let library,
            let brief = selectedVoiceBrief,
            !isRunningVoiceBrief
        else {
            return
        }
        isRunningVoiceBrief = true
        defer { isRunningVoiceBrief = false }
        do {
            status = "Checking \(brief.sources.count) " +
                (brief.sources.count == 1 ? "channel…" : "channels…")
            var newEntryIDs = [String]()
            var channelErrors = [String]()
            for source in brief.sources {
                do {
                    let result = try await retrieveChannel(library, source: source)
                    newEntryIDs += result.newEntryIDs
                    if let error = result.channel.error { channelErrors.append(error) }
                } catch {
                    channelErrors.append(error.localizedDescription)
                }
            }
            projection = try await library.loadLibraryIndex()
            try await refreshChannels(from: library)
            status = newEntryIDs.isEmpty
                ? "Channels checked. No new items."
                : "Prepared \(newEntryIDs.count) new " +
                    (newEntryIDs.count == 1 ? "item" : "items")
            if let error = channelErrors.first { errorMessage = error }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func runSelectedVoiceBrief() async {
        guard let brief = selectedVoiceBrief else { return }
        do {
            try await library?.queueVoiceBriefRun(id: brief.id)
        } catch {
            errorMessage = error.localizedDescription
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
        guard let library, !isRunningVoiceBrief, !isGeneratingSpeech else { return }
        guard let pending = try? await library.pendingVoiceBriefIDs() else { return }
        for id in pending {
            guard let brief = projection.voiceBriefDefinitions.first(where: { $0.id == id }) else {
                continue
            }
            await generateVoiceBrief(brief, selectEpisode: false, reportErrors: false)
        }
    }

    func runDueVoiceBriefs() async {
        guard let library, !isRunningVoiceBrief, !isGeneratingSpeech else { return }
        do {
            let due = try await library.dueVoiceBriefIDs()
            for id in due {
                guard let brief = projection.voiceBriefDefinitions.first(where: {
                    $0.id == id
                }) else {
                    continue
                }
                try await library.markVoiceBriefAttempt(id: id)
                try await library.queueVoiceBriefRun(id: id)
                await generateVoiceBrief(
                    brief,
                    selectEpisode: false,
                    reportErrors: false
                )
            }
        } catch {
            status = "Scheduled voice briefs will retry later"
        }
    }

    func runDueChannelChecks() async {
        guard let library, !isCheckingChannel, !isRunningVoiceBrief else { return }
        guard let due = try? await library.dueChannelSources(), !due.isEmpty else { return }
        isCheckingChannel = true
        defer { isCheckingChannel = false }
        var newEntryIDs = [String]()
        for source in due {
            do {
                newEntryIDs += try await retrieveChannel(
                    library,
                    source: source
                ).newEntryIDs
            } catch {
                continue
            }
        }
        projection = (try? await library.loadLibraryIndex()) ?? projection
        try? await refreshChannels(from: library)
        let autoSummarizeIDs = Set(libraryChannels.filter(\.autoSummarize).flatMap(\.entryIDs))
        await enqueueProcessing(newEntryIDs.filter(autoSummarizeIDs.contains))
        if !newEntryIDs.isEmpty { requestSync() }
    }

}
