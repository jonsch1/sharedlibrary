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
    func show(_ section: LibrarySection) async {
        activeSection = section
        showingHighlights = false
        showingTrash = false
        query = ""
        clearEntrySelection()
        switch section {
        case .items:
            #if os(iOS)
            selectedTopic = ""
            #else
            selectedTopic = "All"
            #endif
        case .channels:
            selectedChannelDomain = "All"
            selectedChannelSource = ""
            showingChannelSettings = false
            await loadChannels()
        case .briefs:
            selectedVoiceBriefID = ""
            showingVoiceBriefSettings = false
        }
    }

    func select(_ id: String, extending: Bool = false) async {
        showingHighlights = false
        if extending {
            if selectedIDs.remove(id) != nil {
                if selectedID == id {
                    selectedID = selectedEntryIDs(fallback: "").last ?? ""
                }
            } else {
                selectedIDs.insert(id)
                selectedID = id
            }
        } else {
            selectedID = id
            selectedIDs = id.isEmpty ? [] : [id]
        }
        guard let entry = selectedEntry else {
            selectedText = ""
            return
        }
        if let voiceBriefID = entry.voiceBriefID, !selectedVoiceBriefID.isEmpty {
            selectedVoiceBriefID = voiceBriefID
        }
        selectedVariant = entry.preferredVariant
        await loadSelectedText()
    }

    func selectedEntryIDs(fallback: String) -> [String] {
        let ids = !fallback.isEmpty && !selectedIDs.contains(fallback)
            ? Set([fallback])
            : selectedIDs
        return projection.entries.compactMap { ids.contains($0.id) ? $0.id : nil }
    }

    func selectionCount(for entryID: String) -> Int {
        selectedIDs.contains(entryID) ? selectedIDs.count : 1
    }

    func selectVoiceBrief(_ id: String) {
        showingHighlights = false
        showingTrash = false
        showingVoiceBriefSettings = false
        clearEntrySelection()
        selectedVoiceBriefID = id
    }

    func selectChannel(_ source: String) {
        showingHighlights = false
        showingTrash = false
        showingChannelSettings = false
        clearEntrySelection()
        selectedChannelSource = source
    }

    func showVoiceBriefSettings(_ id: String) {
        selectVoiceBrief(id)
        showingVoiceBriefSettings = true
        Task { await loadChannels() }
    }

    func showChannelSettings(_ source: String) {
        selectChannel(source)
        showingChannelSettings = true
        Task { await loadChannels() }
    }

    func showChannelDomain(_ domain: String) {
        selectedChannelDomain = domain
        selectedChannelSource = ""
        showingChannelSettings = false
        clearEntrySelection()
    }

    func navigateBack() {
        if !selectedID.isEmpty {
            clearEntrySelection()
        } else if activeSection == .channels {
            selectedChannelSource = ""
            showingChannelSettings = false
        } else if activeSection == .briefs {
            if showingVoiceBriefSettings {
                showingVoiceBriefSettings = false
                if selectedVoiceBriefID == "new" {
                    selectedVoiceBriefID = ""
                }
            } else {
                selectedVoiceBriefID = ""
            }
        }
    }

    func clearEntrySelection() {
        selectedID = ""
        selectedIDs = []
        selectedText = ""
    }

    func selectVariant(_ variant: LibraryVariant) async {
        selectedVariant = variant
        await loadSelectedText()
    }

    func sync() async {
        guard !isSyncing else { return }
        isSyncing = true
        syncCompleted = 0
        syncTotal = 0
        defer {
            isSyncing = false
            syncCompleted = 0
            syncTotal = 0
        }
        do {
            guard let library else { return }
            guard let cloud else {
                status = "Using the local SQLite library"
                return
            }
            guard try await cloud.accountStatus() == .available else {
                throw NativeLibraryError.iCloudUnavailable
            }
            status = "Checking iCloud for changes…"
            try await cloud.synchronize(
                onProgress: { [weak self] completed, total in
                    guard let self else { return }
                    syncCompleted = completed
                    syncTotal = total
                    status = total > 0
                        ? "Uploading \(completed) of \(total) changes…"
                        : "Finishing iCloud sync…"
                },
                onFetchedChanges: { [weak self] in
                    guard let self else { return }
                    try await refreshLibraryAfterCloudFetch(from: library)
                }
            )
            try await refreshLibraryAfterCloudFetch(from: library)
            status = "Sync complete"
        } catch {
            errorMessage = error.localizedDescription
            status = "Using the last complete offline library"
        }
    }

    func refreshLibraryAfterCloudFetch(from library: SQLiteLibraryStore) async throws {
        projection = try await library.loadLibraryIndex()
        if hasLoadedTrash { try await refreshTrash(from: library) }
        if hasLoadedChannels { try await refreshChannels(from: library) }
        if hasLoadedHighlights { try await refreshHighlights(from: library) }
        topicsText = try await library.topicDefinitions()
            .map { "\($0.id): \($0.title)" }
            .joined(separator: "\n")
        await restoreSelection()
    }

    func clearError() {
        errorMessage = nil
    }

}
