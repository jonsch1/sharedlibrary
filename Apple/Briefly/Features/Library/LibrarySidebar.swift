import SwiftUI
import BrieflyCore
#if os(macOS)
import AppKit
#endif

struct LibrarySidebar: View {
    @Bindable var model: LibraryModel
    @Binding var showsSettings: Bool
    @Bindable var audioPlayer: NativeAudioPlayer
    @Binding var audioEntry: LibraryEntry?
    var onOpenDetail: () -> Void = {}

    var body: some View {
        VStack(spacing: 0) {
            #if os(macOS)
            Color.clear
            .frame(height: 45)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            #endif

            #if os(macOS)
            HStack {
                BrieflyLogo()
                Spacer()
            }
            .padding(.horizontal, 20)
            .frame(height: 54)
            #endif

            #if os(iOS)
            MobileLibraryRows(model: model, onOpenDetail: onOpenDetail)
            #else
            ScrollView {
                xSidebarNavigation
            }
            .scrollIndicators(.hidden)
            #endif

            #if os(macOS)
            sidebarFooter
                .padding(14)
            #endif
        }
        #if os(macOS)
        .background {
            ZStack {
                sidebarBackground.opacity(0.22)
                Rectangle()
                    .fill(.thinMaterial)
                    .opacity(0.72)
            }
            .ignoresSafeArea()
        }
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(.white.opacity(0.07))
                .frame(width: 1)
                .ignoresSafeArea()
        }
        #else
        .background { BrieflyAtmosphere().ignoresSafeArea() }
        #endif
    }

    #if os(macOS)
    private var xSidebarNavigation: some View {
        LazyVStack(alignment: .leading, spacing: 4) {
            ForEach(LibrarySection.allCases) { section in
                Button {
                    Task { await model.workflows.show(section) }
                } label: {
                    xSidebarRow(
                        icon: section.icon,
                        title: section.title,
                        selected: model.navigation.activeSection == section
                    )
                }
                .accessibilityAddTraits(
                    model.navigation.activeSection == section ? .isSelected : []
                )
                .help(section.title)
            }

            if model.navigation.activeSection == .items {
                Divider()
                    .padding(.vertical, 10)
                    .padding(.horizontal, 8)

                Button(action: model.workflows.showInbox) {
                    xSidebarRow(
                        icon: "tray",
                        title: "Inbox",
                        selected: model.navigation.selectedTopic == "All" &&
                            !model.navigation.showingHighlights && !model.navigation.showingTrash
                    )
                }
                Button(action: model.workflows.showHighlights) {
                    xSidebarRow(
                        icon: "highlighter",
                        title: "Highlights",
                        selected: model.navigation.showingHighlights
                    )
                }
                Button(action: model.workflows.showTrash) {
                    xSidebarRow(
                        icon: "trash",
                        title: "Trash",
                        selected: model.navigation.showingTrash
                    )
                }
            }

            if model.navigation.activeSection != .items {
                Button {
                    model.navigation.query = ""
                    model.workflows.showChannelSettings("new")
                } label: {
                    Label(
                        "New channel",
                        systemImage: "plus"
                    )
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .frame(height: 42)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .padding(.top, 14)
                .padding(.horizontal, 4)
            } else {
                Button {
                    let text = NSPasteboard.general.string(forType: .string) ?? ""
                    Task { await model.workflows.capture(text) }
                } label: {
                    Label("Capture", systemImage: "plus")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .frame(height: 42)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .padding(.top, 14)
                .padding(.horizontal, 4)
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 14)
        .padding(.top, 8)
    }

    private var sidebarFooter: some View {
        VStack(spacing: 4) {
            if let playingEntry {
                Button {
                    audioEntry = playingEntry
                } label: {
                    xSidebarRow(icon: "waveform", title: "Now playing", selected: false)
                }
                .symbolEffect(.variableColor.iterative, options: .repeating)
            }

            Button {
                showsSettings = true
            } label: {
                xSidebarRow(icon: "gearshape", title: "Settings", selected: false)
            }
            .help("Settings")
        }
        .buttonStyle(.plain)
    }

    private var playingEntry: LibraryEntry? {
        guard
            audioPlayer.isPlaying,
            let id = audioPlayer.currentEntryID
        else { return nil }
        return model.session.projection.entries.first { $0.id == id }
    }

    private func xSidebarRow(
        icon: String,
        title: String,
        selected: Bool
    ) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 19, weight: selected ? .semibold : .regular))
                .frame(width: 24)
            Text(title)
                .font(.system(size: 17, weight: selected ? .bold : .medium))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .foregroundStyle(selected ? Color.primary : Color.primary.opacity(0.82))
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, minHeight: 46, alignment: .leading)
        .contentShape(Rectangle())
    }
    #endif
}
