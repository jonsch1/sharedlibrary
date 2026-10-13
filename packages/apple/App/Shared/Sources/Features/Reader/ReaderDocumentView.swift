import SwiftUI
import BrieflyCore

struct LibraryDocument: View {
    @Bindable var model: LibraryModel
    let entry: LibraryEntry
    @Bindable var audioPlayer: NativeAudioPlayer
    @Binding var audioEntry: LibraryEntry?
    @State private var isEditing = false
    @State private var showsSharing = false

    private var availableVariants: [LibraryVariant] {
        let variants = Set(entry.texts.map(\.variant))
        return LibraryVariant.allCases.filter(variants.contains)
    }

    #if os(macOS)
    private var regenerateHelp: String {
        model.settings.isProcessingConfigured
            ? "Create new summaries for this item."
            : "Connect OpenRouter in Settings to create summaries."
    }
    #endif

    #if os(macOS)
    private var macBackBar: some View {
        HStack(spacing: 12) {
            Button {
                Task { await model.workflows.select("") }
            } label: {
                Image(systemName: "arrow.left")
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .contentShape(Circle())
            // Esc leaves the item unless it is being edited; ⌘[ is a menu command.
            .keyboardShortcut(isEditing ? nil : KeyboardShortcut(.escape, modifiers: []))
            .accessibilityLabel("Back")
            .help("Back (Esc)")

            Spacer()
        }
        .padding(.horizontal, 14)
        .frame(height: 56)
        .fadingBarBackground()
        .readingColumn()
    }
    #endif

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                ZStack {
                    if model.selection.isLoadingText {
                        XLoadingState(
                            title: "Loading item",
                            message: "Fetching the saved item and its summaries."
                        )
                        #if os(macOS)
                        .readingColumn()
                        #endif
                    } else if model.selection.selectedText.isEmpty && !model.session.canEdit {
                        XEmptyState(
                            icon: "icloud.slash",
                            title: "Item unavailable",
                            message: "Sync the library to download this item."
                        )
                        #if os(macOS)
                        .readingColumn()
                        #endif
                    } else {
                        DocumentEditor(
                            model: model,
                            entryID: entry.id,
                            variant: model.selection.selectedVariant,
                            sourceText: model.selection.selectedText,
                            highlightedPassages: highlightedPassages(
                                in: model.selection.highlightsText
                            ),
                            isEditing: isEditing
                        )
                        .accessibilityIdentifier("reader.editor")
                        #if os(iOS)
                        .environment(\.readerHeading, ReaderHeading(entry: entry))
                        #endif
                        #if os(macOS)
                        .environment(\.macReaderHeading, MacReaderHeading(entry: entry) { topic in
                            Task { await model.workflows.showTopic(topic) }
                        })
                        #endif
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .id("\(entry.id):\(model.selection.selectedVariant.rawValue)")
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .layoutPriority(1)
                .scrollContentEdgeFade()
                #if os(macOS)
                // The back bar floats over the text, which scrolls under a soft fade.
                .overlay(alignment: .top) { macBackBar }
                #endif

                HStack(alignment: .center, spacing: 0) {
                    #if os(iOS)
                    ReadingDepthPicker(model: model, entry: entry)
                    Spacer(minLength: 12)
                    MobileReaderPlayButton(
                        model: model,
                        entry: entry,
                        audioPlayer: audioPlayer,
                        audioEntry: $audioEntry
                    )
                    #else
                    ForEach(availableVariants, id: \.self) { variant in
                        ReadingDepthButton(
                            model: model,
                            variant: variant
                        )
                    }

                    MacAudioPlayButton(
                        model: model,
                        entry: entry,
                        audioPlayer: audioPlayer,
                        audioEntry: $audioEntry
                    )
                    .frame(width: ReaderActionBarMetrics.moreSlot)

                    Menu {
                        if model.session.canEdit && model.supportsAIProcessing && !model.navigation.showingTrash {
                            Button {
                                isEditing.toggle()
                            } label: {
                                Label(
                                    isEditing ? "Finish editing" : "Edit item",
                                    systemImage: isEditing ? "checkmark" : "pencil"
                                )
                            }
                        }
                        if let source = entry.sourceURL, let url = URL(string: source) {
                            Link(destination: url) {
                                Label("Open original source", systemImage: "arrow.up.right")
                            }
                        }
                        if !model.navigation.showingTrash && entry.origin != .shared {
                            Button {
                                showsSharing = true
                            } label: {
                                Label("Share item", systemImage: "square.and.arrow.up")
                            }
                        }
                        if model.session.canEdit && !model.navigation.showingTrash {
                            Divider()
                            Button("Regenerate summaries", systemImage: "arrow.clockwise") {
                                Task { await model.workflows.processSelected() }
                            }
                            .disabled(model.isProcessing || !model.settings.isProcessingConfigured)
                            .help(regenerateHelp)
                            Button("Move to Trash", systemImage: "trash", role: .destructive) {
                                Task { await model.workflows.trashSelected() }
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 22, weight: .medium))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .contentShape(Rectangle())
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .frame(width: ReaderActionBarMetrics.moreSlot)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .accessibilityLabel("More")
                    #endif
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                #if os(iOS)
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
                .fadingBarBackground(.bottom)
                #endif
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                #if os(iOS)
                .frame(height: 64)
                #else
                .frame(height: 52)
                #endif
                #if os(macOS)
                .fadingBarBackground(.bottom)
                .readingColumn()
                #endif
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // On macOS this spans the full content area so the text view's scroller sits at
        // the window edge; the text, bars, and states keep to the reading column.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: entry.id) {
            isEditing = false
        }
        #if os(macOS)
        .contextMenu {
            if model.session.canEdit && model.supportsAIProcessing && !model.navigation.showingTrash {
                Button("Regenerate summaries") {
                    Task { await model.workflows.processSelected() }
                }
                .disabled(model.isProcessing || !model.settings.isProcessingConfigured)
                .help(regenerateHelp)
                Divider()
                Button("Move to Trash", role: .destructive) {
                    Task { await model.workflows.trashSelected() }
                }
            }
        }
        #endif
        .sheet(isPresented: $showsSharing) {
            ShareDocumentView(model: model, entry: entry)
        }
        #if os(iOS)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    if let source = entry.sourceURL, let url = URL(string: source) {
                        Link(destination: url) {
                            Label("Open original source", systemImage: "arrow.up.right")
                        }
                    }
                    if entry.origin != .shared {
                        Button {
                            showsSharing = true
                        } label: {
                            Label(
                                "Share item",
                                systemImage: "square.and.arrow.up"
                            )
                        }
                    }
                    if model.session.canEdit && !model.navigation.showingTrash {
                        Divider()
                        Button("Move to Trash", systemImage: "trash", role: .destructive) {
                            Task { await model.workflows.trashSelected() }
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .accessibilityLabel("More")
            }
        }
        #endif
    }

}

#if os(macOS)
/// Plays the open item from the reader action bar. While any item's audio is
/// loaded it reopens the player instead, so playback stays reachable.
struct MacAudioPlayButton: View {
    @Bindable var model: LibraryModel
    let entry: LibraryEntry
    @Bindable var audioPlayer: NativeAudioPlayer
    @Binding var audioEntry: LibraryEntry?

    var body: some View {
        Button(action: primaryAction) {
            ZStack {
                Circle()
                    .fill(Color.accentColor)

                if model.audio.isGeneratingSpeech && currentEntry == nil {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                } else if audioPlayer.isPlaying {
                    Image(systemName: "waveform")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .symbolEffect(.variableColor.iterative, options: .repeating)
                } else {
                    Image(systemName: "play.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
            .frame(width: 36, height: 36)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(currentEntry == nil ? "Play audio" : "Open audio player")
        .accessibilityIdentifier("reader.play")
        .help(currentEntry == nil ? "Play audio" : "Open audio player")
        .disabled(model.audio.isGeneratingSpeech && currentEntry == nil || noPlayableText)
    }

    private var currentEntry: LibraryEntry? {
        guard let id = audioPlayer.currentEntryID else { return nil }
        return model.session.projection.entries.first { $0.id == id }
            ?? (id == entry.id ? entry : nil)
    }

    private var noPlayableText: Bool {
        currentEntry == nil && model.selection.selectedText.isEmpty && entry.excerpt.isEmpty
    }

    private func primaryAction() {
        if let currentEntry {
            audioEntry = currentEntry
            return
        }

        let variant = model.selection.selectedVariant
        let text = model.selection.selectedText.isEmpty
            ? entry.text(for: variant)?.text ?? entry.excerpt
            : model.selection.selectedText
        Task {
            await audioPlayer.play(entry, variant: variant, text: text, model: model) {
                audioEntry = entry
            }
        }
    }
}
#endif

@MainActor
extension NativeAudioPlayer {
    /// Plays `entry`, generating speech segments when no cached audio exists.
    /// `open` runs once playback has started so the caller can show the player.
    func play(
        _ entry: LibraryEntry,
        variant: LibraryVariant,
        text: String,
        model: LibraryModel,
        open: @escaping () -> Void
    ) async {
        let playbackID = model.audio.audioPlaybackID(for: entry, variant: variant, text: text)
        do {
            let shouldGenerate = try startStream(
                entryID: entry.id,
                title: entry.title,
                playbackID: playbackID,
                positionID: "\(entry.id):\(variant.rawValue)"
            )
            guard shouldGenerate else {
                open()
                return
            }
            var startedPlayback = false
            _ = await model.workflows.streamPlayableAudio(for: entry, variant: variant, text: text) { url in
                try self.appendSegment(url, playbackID: playbackID)
                if !startedPlayback {
                    startedPlayback = true
                    open()
                }
            }
            finishStream(playbackID: playbackID)
            if !startedPlayback { stop() }
        } catch {
            model.session.errorMessage = error.localizedDescription
            stop()
        }
    }
}
