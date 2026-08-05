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
    func selectInitialContent() {
        showingHighlights = false
        showingTrash = false
        #if os(macOS)
        activeSection = .items
        selectedTopic = "All"
        selectedChannelDomain = "All"
        selectedChannelSource = ""
        selectedVoiceBriefID = ""
        showingChannelSettings = false
        showingVoiceBriefSettings = false
        clearEntrySelection()
        #else
        if projection.voiceBriefDefinitions.contains(where: {
            !projection.episodes(for: $0.id).isEmpty
        }) {
            activeSection = .briefs
            selectedVoiceBriefID = ""
            selectedID = ""
            selectedIDs = []
            selectedText = ""
        } else {
            activeSection = .items
            selectedID = projection.entries.first(where: \.isMainLibraryEntry)?.id ?? ""
            selectedIDs = selectedID.isEmpty ? [] : [selectedID]
            selectedVariant = selectedEntry?.preferredVariant ?? .concise
            selectedText = ""
        }
        #endif
    }

    func restoreSelection(preferredEntryID: String? = nil) async {
        if showingHighlights {
            clearEntrySelection()
            return
        }
        let entryID = preferredEntryID ?? selectedID
        if (projection.entries + trashEntries).contains(where: { $0.id == entryID }) {
            await select(entryID)
            return
        }

        clearEntrySelection()
        #if os(macOS)
        if selectedChannelSource != "new" &&
            !channels.contains(where: { $0.source == selectedChannelSource })
        {
            selectedChannelSource = ""
            showingChannelSettings = false
        }
        if selectedVoiceBriefID != "new" &&
            !projection.voiceBriefDefinitions.contains(where: {
                $0.id == selectedVoiceBriefID
            })
        {
            selectedVoiceBriefID = ""
            showingVoiceBriefSettings = false
        }
        #else
        switch activeSection {
        case .items:
            break
        case .channels:
            if selectedChannelSource != "new" &&
                !channels.contains(where: { $0.source == selectedChannelSource })
            {
                selectedChannelSource = channels.first?.source ?? ""
            }
        case .briefs:
            if selectedVoiceBriefID != "new" &&
                !projection.voiceBriefDefinitions.contains(where: {
                    $0.id == selectedVoiceBriefID
                })
            {
                selectedVoiceBriefID = projection.voiceBriefDefinitions.first?.id ?? ""
            }
        }
        #endif
    }

    func refreshTrash(from store: SQLiteLibraryStore) async throws {
        trashEntries = try await store.loadTrashIndex().filter(\.isMainLibraryEntry)
        hasLoadedTrash = true
    }

    func loadTrash() async {
        guard let library, !hasLoadedTrash else { return }
        do {
            try await refreshTrash(from: library)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func refreshChannels(from store: SQLiteLibraryStore) async throws {
        libraryChannels = try await store.loadChannels()
        hasLoadedChannels = true
    }

    func loadChannels() async {
        guard let library, !hasLoadedChannels else { return }
        do {
            try await refreshChannels(from: library)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func refreshHighlights(from store: SQLiteLibraryStore) async throws {
        highlightsText = try await store.loadHighlights()
        hasLoadedHighlights = true
    }

    func loadSelectedText() async {
        guard
            let entry = selectedEntry,
            let reference = entry.text(for: selectedVariant)
        else {
            selectedText = ""
            return
        }
        guard let library else {
            selectedText = reference.text ?? ""
            return
        }
        let entryID = entry.id
        let variant = selectedVariant
        isLoadingText = true
        defer { isLoadingText = false }
        do {
            let document = try await library.getDocument(
                entryID,
                includeDeleted: showingTrash
            )
            guard selectedID == entryID, selectedVariant == variant else { return }
            selectedText = document.texts[variant] ?? ""
            await loadHighlights()
        } catch {
            errorMessage = error.localizedDescription
            selectedText = ""
        }
    }

    func loadHighlights() async {
        guard let library, !hasLoadedHighlights else { return }
        do {
            try await refreshHighlights(from: library)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
