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
                    Task { await model.selection.select("") }
                } label: {
                    Image(systemName: "arrow.left")
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .contentShape(Circle())

                Spacer()
                Menu {
                    Button("Regenerate summaries", systemImage: "arrow.clockwise") {
                        Task { await model.processing.processSelected() }
                    }
                    .disabled(model.processing.isProcessing)
                    Button("Move to Trash", systemImage: "trash", role: .destructive) {
                        Task { await model.navigation.trashSelected() }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
            .padding(.horizontal, 14)
            .frame(height: 56)
            .background(.regularMaterial)
            Divider()
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

            HStack(alignment: .bottom, spacing: 0) {
                if entry.texts.count > 1 {
                    HStack(spacing: 0) {
                        ForEach(entry.texts.map(\.variant), id: \.self) { variant in
                            Button {
                                Task { await model.selection.selectVariant(variant) }
                            } label: {
                                ReadingDepthIcon(variant: variant)
                                    .frame(width: 44, height: 44)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(
                                model.selection.selectedVariant == variant
                                    ? Color.accentColor
                                    : Color.primary
                            )
                            .background(
                                model.selection.selectedVariant == variant
                                    ? Color.accentColor.opacity(0.12)
                                    : Color.clear
                            )
                            .accessibilityLabel(
                                variant == .source ? "Original" : variant.title
                            )
                            .accessibilityIdentifier("reader.depth.\(variant.rawValue)")
                            .accessibilityAddTraits(
                                model.selection.selectedVariant == variant ? .isSelected : []
                            )
                            .help(variant == .source ? "Original" : variant.title)
                        }
                    }
                    #if os(iOS)
                    .padding(4)
                    .mobileGlass(in: Capsule())
                    #endif
                }

                #if os(iOS)
                Spacer()
                #else
                Spacer(minLength: 12)
                #endif

                HStack(spacing: 0) {
                    #if os(macOS)
                    if model.session.canEdit && !model.navigation.showingTrash {
                        Button {
                            isEditing.toggle()
                        } label: {
                            Image(systemName: isEditing ? "checkmark" : "pencil")
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(isEditing ? Color.accentColor : Color.primary)
                        .background(
                            isEditing ? Color.accentColor.opacity(0.12) : Color.clear
                        )
                        .accessibilityLabel(
                            isEditing ? "Finish editing" : "Edit document"
                        )
                        .help(isEditing ? "Finish editing" : "Edit document")

                    }
                    #endif

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
                                        _ = await model.audio.streamPlayableAudio(
                                            for: entry,
                                            variant: variant,
                                            text: text
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
                                    .tint(.white)
                                    .frame(width: 44, height: 44)
                                    .background(Color.accentColor, in: Circle())
                            } else {
                                Image(systemName: "play.fill")
                                    .font(.system(size: 17, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .frame(width: 44, height: 44)
                                    .background(Color.accentColor, in: Circle())
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

                    if !usesMobileVoiceBriefControls && !usesMobileItemControls,
                       let source = entry.sourceURL, let url = URL(string: source) {
                        Link(destination: url) {
                            Image(systemName: "arrow.up.right")
                                .frame(width: 44, height: 44)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Open original source")
                    }

                    if !model.navigation.showingTrash &&
                        entry.origin != .shared &&
                        !usesMobileVoiceBriefControls &&
                        !usesMobileItemControls
                    {
                        Button {
                            showsSharing = true
                        } label: {
                            Image(systemName: "square.and.arrow.up")
                                .frame(width: 44, height: 44)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Share document")
                    }
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
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity)
            .frame(height: 58)
            .background(.regularMaterial)
            .overlay(alignment: .top) { Divider() }
            .frame(maxWidth: .infinity, alignment: .bottom)
            #endif
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        #if os(macOS)
        .frame(maxWidth: 680)
        .frame(maxWidth: .infinity, alignment: .top)
        .background(.ultraThinMaterial.opacity(0.64))
        .overlay { Rectangle().stroke(Color.primary.opacity(0.10)) }
        #else
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        #endif
        .onChange(of: entry.id) {
            isEditing = false
        }
        .contextMenu {
            if model.session.canEdit && !model.navigation.showingTrash {
                Button("Regenerate summaries") {
                    Task { await model.processing.processSelected() }
                }
                .disabled(model.processing.isProcessing)
                Divider()
                Button("Move to Trash", role: .destructive) {
                    Task { await model.navigation.trashSelected() }
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
                                Task { await model.processing.processSelected() }
                            }
                            .disabled(model.processing.isProcessing)
                            Button("Move to Trash", systemImage: "trash", role: .destructive) {
                                Task { await model.navigation.trashSelected() }
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
