import SwiftUI
import BrieflyCore

struct LibraryDocument: View {
    @Bindable var model: LibraryModel
    let entry: LibraryEntry
    @Bindable var audioPlayer: NativeAudioPlayer
    @Binding var audioEntry: LibraryEntry?
    @State private var isEditing = false
    @State private var showsSharing = false

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

            ZStack(alignment: .bottom) {
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

            HStack(alignment: .center, spacing: 0) {
                if entry.texts.count > 1 {
                    ReadingDepthStrip(model: model, entry: entry)
                        .frame(height: 44)
                }

                #if os(iOS)
                Spacer()
                #else
                if entry.texts.count > 1 {
                    Divider()
                        .frame(height: 20)
                        .padding(.horizontal, 8)
                }
                #endif

                HStack(spacing: 0) {
                    #if os(macOS)
                    if !usesMobileVoiceBriefControls && !usesMobileItemControls {
                        Button {
                            Task {
                                let variant = model.selection.selectedVariant
                                let text = model.selection.selectedText
                                let playbackID = model.audio.audioPlaybackID(
                                    for: entry,
                                    variant: variant,
                                    text: text
                                )
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
                                            try audioPlayer.appendSegment(
                                                url,
                                                playbackID: playbackID
                                            )
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
                        } label: {
                            if model.audio.isGeneratingSpeech {
                                ProgressView()
                                    .tint(.primary)
                                    .frame(
                                        width: ReaderActionBarMetrics.buttonSize,
                                        height: ReaderActionBarMetrics.buttonSize
                                    )
                            } else {
                                Image(systemName: "play.fill")
                                    .font(ReaderActionBarMetrics.iconFont)
                                    .foregroundStyle(.primary)
                                    .frame(
                                        width: ReaderActionBarMetrics.buttonSize,
                                        height: ReaderActionBarMetrics.buttonSize
                                    )
                                    .contentShape(Circle())
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Play audio")
                        .help("Play audio")
                        .disabled(
                            model.audio.isGeneratingSpeech || model.voiceBriefs.isRunningVoiceBrief ||
                                model.selection.selectedText.isEmpty
                        )
                    }

                    Menu {
                        if model.session.canEdit && !model.navigation.showingTrash {
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
                            .font(ReaderActionBarMetrics.iconFont)
                            .frame(
                                width: ReaderActionBarMetrics.buttonSize,
                                height: ReaderActionBarMetrics.buttonSize
                            )
                            .contentShape(Circle())
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .accessibilityLabel("Document actions")
                    #endif
                }
                #if os(iOS)
                .background(readerBackground)
                .clipShape(
                    .rect(
                        topLeadingRadius: 14,
                        bottomLeadingRadius: 0,
                        bottomTrailingRadius: 0,
                        topTrailingRadius: 0
                    )
                )
                .overlay(alignment: .top) {
                    Rectangle()
                        .fill(.primary.opacity(0.08))
                        .frame(height: 1)
                }
                #endif
            }
            #if os(iOS)
            .padding(.horizontal, 18)
            .padding(.bottom, 8)
            #endif
            #if os(macOS)
            .padding(4)
            .actionBarGlass()
            .padding(.horizontal, 10)
            .padding(.bottom, 10)
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
            if model.session.canEdit && !model.navigation.showingTrash {
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
            if usesMobileVoiceBriefControls || usesMobileItemControls {
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
                                    usesMobileVoiceBriefControls
                                        ? "Share voice brief"
                                        : "Share document",
                                    systemImage: "square.and.arrow.up"
                                )
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
                    }
                    .accessibilityLabel("Document settings")
                }
            }
        }
        #endif
    }

    private var usesMobileVoiceBriefControls: Bool {
        #if os(iOS)
        entry.voiceBriefID != nil
        #else
        false
        #endif
    }

    private var usesMobileItemControls: Bool {
        #if os(iOS)
        entry.voiceBriefID == nil
        #else
        false
        #endif
    }
}
