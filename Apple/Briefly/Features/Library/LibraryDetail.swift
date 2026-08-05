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
            if model.showingHighlights {
                HighlightsDocument(model: model)
            } else if let entry = model.selectedEntry {
                LibraryDocument(
                    model: model,
                    entry: entry,
                    audioPlayer: audioPlayer,
                    audioEntry: $audioEntry
                )
            } else if model.activeSection == .briefs &&
                model.showingVoiceBriefSettings
            {
                VoiceBriefConfiguration(model: model)
            } else if model.activeSection == .channels &&
                model.showingChannelSettings
            {
                ChannelConfiguration(
                    model: model,
                    showsChannelBrowser: $showsChannelBrowser
                )
            } else {
                LibraryCardBrowser(model: model)
            }
            #else
            if model.showingHighlights {
                HighlightsDocument(model: model)
            } else if let entry = model.selectedEntry {
                LibraryDocument(
                    model: model,
                    entry: entry,
                    audioPlayer: audioPlayer,
                    audioEntry: $audioEntry
                )
            } else if model.activeSection == .briefs {
                VoiceBriefConfiguration(model: model)
            } else if model.activeSection == .channels {
                ChannelConfiguration(
                    model: model,
                    showsChannelBrowser: $showsChannelBrowser
                )
            } else if model.activeSection == .items && model.filteredEntries.isEmpty {
                ContentUnavailableView(
                    model.query.isEmpty
                        ? model.selectedTopic == "All"
                            ? "No documents yet"
                            : "No documents in \(model.selectedTopic)"
                        : "No matching documents",
                    systemImage: model.query.isEmpty
                        ? "doc.text"
                        : "doc.text.magnifyingglass",
                    description: Text(
                        model.query.isEmpty
                            ? model.selectedTopic == "All"
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
