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

struct LibraryDetail: View {
    @Bindable var model: LibraryModel
    @Binding var showsChannelBrowser: Bool
    @Bindable var audioPlayer: NativeAudioPlayer
    @Binding var audioEntry: LibraryEntry?

    var body: some View {
        Group {
            #if os(macOS)
            if model.navigation.showingHighlights {
                HighlightsDocument(model: model)
            } else if let entry = model.selection.selectedEntry {
                LibraryDocument(
                    model: model,
                    entry: entry,
                    audioPlayer: audioPlayer,
                    audioEntry: $audioEntry
                )
            } else if model.navigation.activeSection == .briefs &&
                model.navigation.showingVoiceBriefSettings
            {
                VoiceBriefConfiguration(model: model)
            } else if model.navigation.activeSection == .channels &&
                model.navigation.showingChannelSettings
            {
                ChannelConfiguration(
                    model: model,
                    showsChannelBrowser: $showsChannelBrowser
                )
            } else {
                LibraryCardBrowser(model: model)
            }
            #else
            if model.navigation.showingHighlights {
                HighlightsDocument(model: model)
            } else if let entry = model.selection.selectedEntry {
                LibraryDocument(
                    model: model,
                    entry: entry,
                    audioPlayer: audioPlayer,
                    audioEntry: $audioEntry
                )
            } else if model.navigation.activeSection == .briefs {
                VoiceBriefConfiguration(model: model)
            } else if model.navigation.activeSection == .channels {
                ChannelConfiguration(
                    model: model,
                    showsChannelBrowser: $showsChannelBrowser
                )
            } else if model.navigation.activeSection == .items &&
                model.navigation.filteredEntries(trashEntries: model.selection.trashEntries).isEmpty {
                ContentUnavailableView(
                    model.navigation.query.isEmpty
                        ? model.navigation.selectedTopic == "All"
                            ? "No documents yet"
                            : "No documents in \(model.navigation.selectedTopic)"
                        : "No matching documents",
                    systemImage: model.navigation.query.isEmpty
                        ? "doc.text"
                        : "doc.text.magnifyingglass",
                    description: Text(
                        model.navigation.query.isEmpty
                            ? model.navigation.selectedTopic == "All"
                                ? "Add a document to start your library."
                                : "Choose another topic or add a document."
                            : "Try another search."
                    )
                )
            } else {
                ContentUnavailableView(
                    "No document selected",
                    systemImage: "doc.text",
                    description: Text("Choose a document from the library.")
                )
            }
            #endif
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        #if os(macOS)
        .background {
            ZStack {
                readerBackground.opacity(0.08)
                Rectangle()
                    .fill(.ultraThinMaterial)
                    .opacity(0.08)
            }
        }
        #else
        .background(readerBackground.ignoresSafeArea())
        #endif
    }

}
