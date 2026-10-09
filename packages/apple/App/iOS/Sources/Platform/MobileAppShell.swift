import BrieflyCore

import SwiftUI

#if os(iOS)
/// A screen pushed onto one tab's navigation stack. Routes carry enough to
/// reselect their content, because every tab shares one `LibraryModel` selection.
enum MobileRoute: Hashable {
    case entry(String)
    case channel(String)
    case channelSettings(String)
    case trash
}

struct MobileXAppShell: View {
    @Bindable var model: LibraryModel
    @Binding var showsCaptureComposer: Bool
    @Bindable var audioPlayer: NativeAudioPlayer
    @Binding var audioEntry: LibraryEntry?
    @AppStorage("BrieflyMobileTab") private var selectedTab = MobilePrimaryTab.home
    @State private var paths: [MobilePrimaryTab: [MobileRoute]] = [:]
    @State private var variants: [MobilePrimaryTab: LibraryVariant] = [:]
    @State private var homeTopic = ""
    @State private var settingsPath: [BrieflySettingsSection] = []

    var body: some View {
        TabView(selection: $selectedTab) {
            mobileStack(.home) {
                feedScreen(.home)
                    .overlay(alignment: .bottomTrailing) { nowPlayingButton }
            }
            .tabItem { Label("Home", systemImage: "house") }
            .tag(MobilePrimaryTab.home)

            mobileStack(.channels) {
                feedScreen(.channels)
            }
            .tabItem { Label("Channels", systemImage: "dot.radiowaves.left.and.right") }
            .tag(MobilePrimaryTab.channels)

            mobileStack(.highlights) {
                MobileXHighlightsScreen(model: model, openTrash: openTrash)
                    .overlay(alignment: .bottomTrailing) { nowPlayingButton }
            }
            .tabItem { Label("Highlights", systemImage: "highlighter") }
            .tag(MobilePrimaryTab.highlights)

            SettingsView(model: model, path: $settingsPath)
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(MobilePrimaryTab.settings)
                .accessibilityIdentifier("settings.open")
        }
        .tint(Color.accentColor)
        .onChange(of: selectedTab) { previousTab, tab in
            remember(previousTab)
            model.navigation.query = ""
            Task { await restore(tab) }
        }
        .task { await restore(selectedTab) }
    }

    private func mobileStack<Root: View>(
        _ tab: MobilePrimaryTab,
        @ViewBuilder root: () -> Root
    ) -> some View {
        NavigationStack(path: path(tab)) {
            root()
                .navigationDestination(for: MobileRoute.self) { route in
                    switch route {
                    case .trash:
                        MobileXTrashScreen(model: model, openEntry: openEntry)
                    case .entry, .channel, .channelSettings:
                        MobileXDetail(
                            model: model,
                            audioPlayer: audioPlayer,
                            audioEntry: $audioEntry
                        )
                    }
                }
        }
        .onChange(of: paths[tab, default: []]) { previous, current in
            // Popping (back button or edge swipe) returns the shared model to
            // whatever the new top of this stack shows.
            guard tab == selectedTab, current.count < previous.count else { return }
            Task { await restore(tab) }
        }
    }

    private func feedScreen(_ tab: MobilePrimaryTab) -> some View {
        MobileXFeedScreen(
            model: model,
            tab: tab,
            openEntry: openEntry,
            openChannel: { channel in
                model.workflows.selectChannel(channel.source)
                push(.channel(channel.source))
            },
            create: primaryCreate
        )
    }

    private func path(_ tab: MobilePrimaryTab) -> Binding<[MobileRoute]> {
        Binding(
            get: { paths[tab, default: []] },
            set: { paths[tab] = $0 }
        )
    }

    private func push(_ route: MobileRoute) {
        paths[selectedTab, default: []].append(route)
    }

    private func openEntry(_ entry: LibraryEntry) {
        Task {
            if selectedTab == .home {
                model.navigation.activeSection = .items
            }
            await model.workflows.select(entry.id)
            push(.entry(entry.id))
        }
    }

    private func openTrash() {
        model.workflows.showTrash()
        push(.trash)
    }

    private func primaryCreate() {
        switch selectedTab {
        case .home, .highlights, .settings:
            showsCaptureComposer = true
        case .channels:
            model.workflows.showChannelSettings("new")
            push(.channelSettings("new"))
        }
    }

    /// Captures the parts of the shared model that the other tabs overwrite.
    private func remember(_ tab: MobilePrimaryTab) {
        if tab == .home {
            homeTopic = model.navigation.selectedTopic
        }
        variants[tab] = model.selection.selectedVariant
    }

    /// Points the shared model at the top of `tab`'s stack.
    private func restore(_ tab: MobilePrimaryTab) async {
        switch tab {
        case .home:
            model.navigation.activeSection = .items
            await model.workflows.showTopic(homeTopic)
        case .channels:
            await model.workflows.show(.channels)
        case .highlights:
            if paths[tab, default: []].contains(.trash) {
                model.workflows.showTrash()
            } else {
                model.workflows.showHighlights()
            }
        case .settings:
            return
        }

        // Read the stack only after the section switch: a screen pushed while it was
        // loading would otherwise be reset by it and never reselected.
        guard tab == selectedTab else { return }
        switch paths[tab, default: []].last {
        case .entry(let id):
            await model.workflows.select(id)
            if let variant = variants[tab],
               variant != model.selection.selectedVariant,
               model.selection.selectedEntry?.text(for: variant) != nil {
                await model.workflows.selectVariant(variant)
            }
        case .channel(let source):
            model.workflows.selectChannel(source)
        case .channelSettings(let source):
            model.workflows.showChannelSettings(source)
        case .trash, nil:
            break
        }
    }

    @ViewBuilder
    private var nowPlayingButton: some View {
        if let playingEntry {
            Button {
                audioEntry = playingEntry
            } label: {
                ZStack {
                    Circle().fill(Color.accentColor)
                    Image(systemName: audioPlayer.isPlaying ? "waveform" : "play.fill")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.white)
                        .symbolEffect(
                            .variableColor.iterative,
                            options: .repeating,
                            isActive: audioPlayer.isPlaying
                        )
                }
                .frame(width: 56, height: 56)
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .shadow(color: .black.opacity(0.18), radius: 10, y: 5)
            .padding(18)
            .accessibilityLabel("Open audio player")
        }
    }

    private var playingEntry: LibraryEntry? {
        guard let id = audioPlayer.currentEntryID else { return nil }
        return model.session.projection.entries.first { $0.id == id }
    }
}

#endif
