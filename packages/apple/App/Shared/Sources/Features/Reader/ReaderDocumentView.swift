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

    var body: some View {
        VStack(spacing: 0) {
            #if os(macOS)
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

                Spacer()
            }
            .padding(.horizontal, 14)
            .frame(height: 56)
            .background(.regularMaterial)
            #endif

            VStack(spacing: 0) {
                ZStack {
            if model.selection.isLoadingText {
                XLoadingState(
                    title: "Loading post",
                    message: "Fetching the saved document and its reading variants."
                )
            } else if model.selection.selectedText.isEmpty && !model.session.canEdit {
                XEmptyState(
                    icon: "icloud.slash",
                    title: "Document unavailable",
                    message: "Sync the library to download this document."
                )
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
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .id("\(entry.id):\(model.selection.selectedVariant.rawValue)")
                }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .layoutPriority(1)

                HStack(alignment: .center, spacing: 0) {
                    #if os(iOS)
                    Spacer(minLength: 0)
                    ReadingDepthPicker(model: model, entry: entry)
                        .padding(.horizontal, 12)
                    #else
                    ForEach(availableVariants, id: \.self) { variant in
                        ReadingDepthButton(
                            model: model,
                            variant: variant
                        )
                    }

                    Menu {
                        if model.session.canEdit && model.supportsAIProcessing && !model.navigation.showingTrash {
                            Button {
                                isEditing.toggle()
                            } label: {
                                Label(
                                    isEditing ? "Finish editing" : "Edit document",
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
                                Label("Share document", systemImage: "square.and.arrow.up")
                            }
                        }
                        if model.session.canEdit && !model.navigation.showingTrash {
                            Divider()
                            Button("Regenerate summaries", systemImage: "arrow.clockwise") {
                                Task { await model.workflows.processSelected() }
                            }
                            .disabled(model.processing.isProcessing)
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
                .background(readerBackground)
                .clipShape(Rectangle())
                .overlay(alignment: .top) {
                    Rectangle()
                        .fill(.primary.opacity(0.08))
                        .frame(height: 1)
                }
                #endif
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            #if os(iOS)
            .frame(height: 64)
            #else
            .frame(height: 52)
            #endif
            #if os(macOS)
            .background(.regularMaterial)
            #endif
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        #if os(macOS)
        .frame(maxWidth: 680)
        .frame(maxWidth: .infinity, alignment: .top)
        .background(.ultraThinMaterial.opacity(0.64))
        #else
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        #endif
        .onChange(of: entry.id) {
            isEditing = false
        }
        .contextMenu {
            if model.session.canEdit && model.supportsAIProcessing && !model.navigation.showingTrash {
                Button("Regenerate summaries") {
                    Task { await model.workflows.processSelected() }
                }
                .disabled(model.processing.isProcessing)
                Divider()
                Button("Move to Trash", role: .destructive) {
                    Task { await model.workflows.trashSelected() }
                }
            }
        }
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
                                    "Share document",
                                    systemImage: "square.and.arrow.up"
                                )
                            }
                        }
                        if model.session.canEdit && model.supportsAIProcessing && !model.navigation.showingTrash {
                            Divider()
                            Button("Regenerate summaries", systemImage: "arrow.clockwise") {
                                Task { await model.workflows.processSelected() }
                            }
                            .disabled(model.processing.isProcessing)
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
struct MacAudioPlayButton: View {
    @Bindable var model: LibraryModel
    let entry: LibraryEntry?
    @Bindable var audioPlayer: NativeAudioPlayer
    @Binding var audioEntry: LibraryEntry?

    var body: some View {
        Button(action: primaryAction) {
            ZStack {
                Circle()
                    .fill(Color.accentColor)

                if model.audio.isGeneratingSpeech {
                    ProgressView()
                        .tint(.white)
                } else if audioPlayer.isPlaying {
                    Image(systemName: "waveform")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(.white)
                        .symbolEffect(.variableColor.iterative, options: .repeating)
                } else {
                    Image(systemName: "play.fill")
                        .font(.system(size: 21, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
            .frame(width: 58, height: 58)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .shadow(color: .black.opacity(0.20), radius: 10, y: 5)
        .accessibilityLabel(audioPlayer.isPlaying ? "Open audio player" : "Play audio")
        .help(audioPlayer.isPlaying ? "Open audio player" : "Play audio")
        .disabled(model.audio.isGeneratingSpeech && currentEntry == nil || noPlayableText)
    }

    private var currentEntry: LibraryEntry? {
        guard let id = audioPlayer.currentEntryID else { return nil }
        return model.session.projection.entries.first { $0.id == id }
            ?? (id == entry?.id ? entry : nil)
    }

    private var noPlayableText: Bool {
        guard currentEntry == nil, let entry else { return false }
        return model.selection.selectedID == entry.id
            ? model.selection.selectedText.isEmpty && entry.excerpt.isEmpty
            : (entry.text(for: model.selection.selectedVariant)?.text ?? entry.excerpt).isEmpty
    }

    private func primaryAction() {
        if let currentEntry {
            audioEntry = currentEntry
            return
        }

        guard let entry else { return }
        let variant = model.selection.selectedVariant
        let text = model.selection.selectedID == entry.id && !model.selection.selectedText.isEmpty
            ? model.selection.selectedText
            : entry.text(for: variant)?.text ?? entry.excerpt
        let playbackID = model.audio.audioPlaybackID(
            for: entry,
            variant: variant,
            text: text
        )

        Task {
            do {
                let shouldGenerate = try audioPlayer.startStream(
                    entryID: entry.id,
                    title: entry.title,
                    playbackID: playbackID,
                    positionID: "\(entry.id):\(variant.rawValue)"
                )
                if shouldGenerate {
                    var startedPlayback = false
                    _ = await model.workflows.streamPlayableAudio(
                        for: entry,
                        variant: variant,
                        text: text,
                    ) { url in
                        try audioPlayer.appendSegment(url, playbackID: playbackID)
                        if !startedPlayback {
                            startedPlayback = true
                            audioEntry = entry
                        }
                    }
                    audioPlayer.finishStream(playbackID: playbackID)
                    if !startedPlayback { audioPlayer.stop() }
                } else {
                    audioEntry = entry
                }
            } catch {
                model.session.errorMessage = error.localizedDescription
                audioPlayer.stop()
            }
        }
    }
}
#endif
