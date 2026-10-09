import SwiftUI
import BrieflyCore

struct LibraryDetail: View {
    @Bindable var model: LibraryModel
    @Bindable var audioPlayer: NativeAudioPlayer
    @Binding var audioEntry: LibraryEntry?

    var body: some View {
        Group {
            #if os(macOS)
            if model.navigation.showingHighlights {
                HighlightsDocument(model: model)
            } else if let entry = model.selection.selectedEntry,
                      let request = entry.captureRequest, request.state != .ready {
                PendingCaptureView(model: model, entry: entry)
            } else if let entry = model.selection.selectedEntry {
                LibraryDocument(
                    model: model,
                    entry: entry,
                    audioPlayer: audioPlayer,
                    audioEntry: $audioEntry
                )
            } else if model.navigation.activeSection == .channels &&
                model.navigation.showingChannelSettings
            {
                ChannelConfiguration(model: model)
            } else if model.navigation.activeSection == .channels,
                let channel = model.channels.selectedChannel(
                    for: model.navigation.selectedChannelSource
                )
            {
                ChannelCandidateDocument(
                    model: model,
                    channelID: channel.source,
                    fallbackChannel: channel
                )
            } else {
                LibraryCardBrowser(model: model)
            }
            #else
            if model.navigation.showingHighlights {
                HighlightsDocument(model: model)
            } else if let entry = model.selection.selectedEntry,
                      let request = entry.captureRequest, request.state != .ready {
                PendingCaptureView(model: model, entry: entry)
            } else if let entry = model.selection.selectedEntry {
                LibraryDocument(
                    model: model,
                    entry: entry,
                    audioPlayer: audioPlayer,
                    audioEntry: $audioEntry
                )
            } else if model.navigation.activeSection == .channels &&
                model.navigation.showingChannelSettings
            {
                ChannelConfiguration(model: model)
            } else if model.navigation.activeSection == .channels,
                let channel = model.channels.selectedChannel(
                    for: model.navigation.selectedChannelSource
                )
            {
                ChannelCandidateDocument(
                    model: model,
                    channelID: channel.source,
                    fallbackChannel: channel
                )
            } else if model.navigation.activeSection == .channels {
                ContentUnavailableView(
                    "No channel selected",
                    systemImage: "dot.radiowaves.left.and.right",
                    description: Text("Choose a channel to review its candidates.")
                )
            } else if model.navigation.activeSection == .items &&
                model.navigation.filteredEntries(trashEntries: model.selection.trashEntries).isEmpty {
                ContentUnavailableView(
                    model.navigation.query.isEmpty
                        ? model.navigation.selectedTopic == "All"
                            ? "No items yet"
                            : "No items in \(model.navigation.selectedTopic)"
                        : "No matching items",
                    systemImage: model.navigation.query.isEmpty
                        ? "doc.text"
                        : "doc.text.magnifyingglass",
                    description: Text(
                        model.navigation.query.isEmpty
                            ? model.navigation.selectedTopic == "All"
                                ? "Capture a link or note to start your library."
                                : "Choose another topic or capture something new."
                            : "Try another search."
                    )
                )
            } else {
                ContentUnavailableView(
                    "No item selected",
                    systemImage: "doc.text",
                    description: Text("Choose an item from the library.")
                )
            }
            #endif
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        #if os(iOS)
        .background { BrieflyAtmosphere().ignoresSafeArea() }
        #endif
    }

}
