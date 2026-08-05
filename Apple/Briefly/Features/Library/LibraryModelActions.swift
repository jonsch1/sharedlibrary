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
    func showHighlights() {
        activeSection = .items
        selectedID = ""
        selectedIDs = []
        selectedText = ""
        showingTrash = false
        showingHighlights = true
        Task { await loadHighlights() }
    }

    func showInbox() {
        activeSection = .items
        selectedTopic = "All"
        showingHighlights = false
        showingTrash = false
        clearEntrySelection()
    }

    func showTrash() {
        activeSection = .items
        selectedTopic = "All"
        showingHighlights = false
        showingTrash = true
        clearEntrySelection()
        Task { await loadTrash() }
    }

    func showTopic(_ topic: String) async {
        selectedTopic = topic
        showingHighlights = false
        showingTrash = false
        clearEntrySelection()
    }

    func trashSelected() async {
        await trash(entryID: selectedID)
    }

    func trash(entryID: String) async {
        guard let library else { return }
        let ids = selectedEntryIDs(fallback: entryID)
        guard !ids.isEmpty else { return }
        do {
            for id in ids {
                try await library.moveToTrash(entryID: id)
            }
            selectedID = ""
            selectedIDs = []
            await refreshLibrary()
            status = ids.count == 1
                ? "The document and its summaries were moved to Trash"
                : "\(ids.count) documents and their summaries were moved to Trash"
            requestSync()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @discardableResult
    func saveVoiceBrief(_ draft: LibraryVoiceBriefDraft) async -> String? {
        guard let library else {
            errorMessage = "Open a Briefly library before editing voice briefs."
            return nil
        }
        do {
            let id = try await library.saveVoiceBrief(draft)
            projection = try await library.loadLibraryIndex()
            try await refreshChannels(from: library)
            activeSection = .briefs
            selectedID = ""
            selectedIDs = []
            selectedVoiceBriefID = id
            status = "Voice brief saved"
            requestSync()
            return id
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func trashSelectedVoiceBrief() async {
        guard
            let library,
            !selectedVoiceBriefID.isEmpty,
            selectedVoiceBriefID != "new"
        else {
            return
        }
        do {
            try await library.moveVoiceBriefToTrash(id: selectedVoiceBriefID)
            projection = try await library.loadLibraryIndex()
            try await refreshChannels(from: library)
            selectedVoiceBriefID = ""
            showingVoiceBriefSettings = false
            selectedID = ""
            selectedIDs = []
            status = "Voice brief moved to Trash"
            requestSync()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

}
