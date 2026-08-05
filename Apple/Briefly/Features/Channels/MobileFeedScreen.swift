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

#if os(iOS)
struct MobileXFeedScreen: View {
    @Bindable var model: LibraryModel
    let tab: MobilePrimaryTab
    @Binding var showsSettings: Bool
    let openEntry: (LibraryEntry) -> Void
    let openConfiguration: () -> Void
    let create: () -> Void
    @State private var showsSearch = false

    private var entries: [LibraryEntry] {
        let candidates: [LibraryEntry]
        switch tab {
        case .home:
            candidates = model.navigation.filteredEntries
        case .channels:
            if model.navigation.selectedChannelSource.isEmpty {
                var seen = Set<String>()
                candidates = model.channels.channels.flatMap { model.channels.channelEntries(for: $0.source) }
                    .filter { seen.insert($0.id).inserted }
            } else {
                candidates = model.channels.channelEntries(for: model.navigation.selectedChannelSource)
            }
        case .briefs:
            if model.navigation.selectedVoiceBriefID.isEmpty {
                candidates = model.session.projection.voiceBriefDefinitions.flatMap {
                    model.session.projection.episodes(for: $0.id)
                }
            } else {
                candidates = model.session.projection.episodes(for: model.navigation.selectedVoiceBriefID)
            }
        case .library:
            candidates = []
        }
        return candidates
            .filter { $0.matches(model.navigation.query) }
            .sorted {
                ($0.createdAt ?? $0.updatedAt ?? "") >
                    ($1.createdAt ?? $1.updatedAt ?? "")
            }
    }

    var body: some View {
        VStack(spacing: 0) {
            if entries.isEmpty {
                ScrollView {
                    VStack(spacing: 0) {
                        Color.clear
                            .frame(height: floatingHeaderHeight)

                        if tab == .briefs,
                           let brief = model.voiceBriefs.voiceBrief(for: model.navigation.selectedVoiceBriefID) {
                            BriefPreparationPanel(model: model, brief: brief)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 12)
                        }

                        XEmptyState(
                            icon: emptyIcon,
                            title: emptyTitle,
                            message: emptyMessage
                        )
                        .frame(maxWidth: 720, minHeight: 420)
                        .frame(maxWidth: .infinity)
                    }
                }
                .scrollIndicators(.hidden)
                .refreshable { await refresh() }
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        Color.clear
                            .frame(height: floatingHeaderHeight)

                        if tab == .briefs,
                           let brief = model.voiceBriefs.voiceBrief(for: model.navigation.selectedVoiceBriefID) {
                            BriefPreparationPanel(model: model, brief: brief)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 12)
                                .transition(.move(edge: .top).combined(with: .opacity))
                        }

                        ForEach(entries) { entry in
                            FeedEntryRow(entry: entry) {
                                openEntry(entry)
                            }
                            .modifier(EntryContextMenu(model: model, entry: entry))
                        }
                    }
                    .frame(maxWidth: 720)
                    .frame(maxWidth: .infinity)
                    .padding(.bottom, 96)
                }
                .scrollIndicators(.hidden)
                .refreshable { await refresh() }
            }
        }
        .overlay(alignment: .top) { floatingHeader }
        .background(readerBackground.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .animation(.smooth(duration: 0.3), value: model.navigation.selectedVoiceBriefID)
        .animation(.snappy(duration: 0.24), value: showsSearch)
        .onDisappear {
            showsSearch = false
            model.navigation.query = ""
        }
    }

    private func closeSearch() {
        model.navigation.query = ""
        showsSearch = false
    }

    private let floatingHeaderHeight: CGFloat = 116

    private var floatingHeader: some View {
        VStack(spacing: 0) {
            if showsSearch {
                MobileXSearchField(
                    text: $model.navigation.query,
                    prompt: searchPrompt,
                    cancel: closeSearch
                )
                .transition(.move(edge: .top).combined(with: .opacity))
            } else {
                MobileXHeader(
                    title: title,
                    showsLogo: tab == .home,
                    showsSettings: $showsSettings,
                    showsSettingsButton: tab == .home,
                    search: MobileXHeaderAction(
                        icon: "magnifyingglass",
                        label: searchPrompt,
                        identifier: "library.search.open",
                        action: { showsSearch = true }
                    ),
                    primary: MobileXHeaderAction(
                        icon: "plus",
                        label: createLabel,
                        identifier: createLabel == "Capture" ? "capture.open" : nil,
                        action: create
                    ),
                    trailing: configurationAction
                )
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            choices
        }
        .mobileGlass(
            in: RoundedRectangle(cornerRadius: 24, style: .continuous),
            interactive: false
        )
        .padding(.horizontal, 8)
        .padding(.top, 4)
        .zIndex(10)
    }

    private var choices: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                choiceButton("All", selected: allSelected) {
                    switch tab {
                    case .home: Task { await model.workflows.showTopic("All") }
                    case .channels: model.navigation.selectedChannelSource = ""
                    case .briefs: model.navigation.selectedVoiceBriefID = ""
                    case .library: break
                    }
                }

                switch tab {
                case .home:
                    ForEach(model.session.projection.documentTopics, id: \.self) { topic in
                        choiceButton(topic, selected: model.navigation.selectedTopic == topic) {
                            Task { await model.workflows.showTopic(topic) }
                        }
                    }
                case .channels:
                    ForEach(model.channels.channels) { channel in
                        choiceButton(
                            channel.title,
                            selected: model.navigation.selectedChannelSource == channel.source
                        ) {
                            model.workflows.selectChannel(channel.source)
                        }
                    }
                case .briefs:
                    ForEach(model.session.projection.voiceBriefDefinitions, id: \.id) { brief in
                        choiceButton(
                            brief.title,
                            selected: model.navigation.selectedVoiceBriefID == brief.id
                        ) {
                            model.workflows.selectVoiceBrief(brief.id)
                        }
                    }
                case .library:
                    EmptyView()
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)
            .padding(.bottom, 12)
        }
        .defaultScrollAnchor(.leading)
    }

    private func choiceButton(
        _ label: String,
        selected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(label)
                .font(.subheadline.weight(selected ? .semibold : .regular))
                .lineLimit(1)
                .padding(.horizontal, 15)
                .frame(height: 38)
                .background(selected ? Color.primary : Color.primary.opacity(0.06), in: Capsule())
                .foregroundStyle(selected ? Color(uiColor: .systemBackground) : Color.primary)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private var configurationAction: MobileXHeaderAction? {
        switch tab {
        case .channels:
            guard let channel = model.channels.selectedChannel(for: model.navigation.selectedChannelSource) else { return nil }
            return MobileXHeaderAction(icon: "ellipsis", label: "Channel settings") {
                model.workflows.showChannelSettings(channel.source)
                openConfiguration()
            }
        case .briefs:
            guard let brief = model.voiceBriefs.voiceBrief(for: model.navigation.selectedVoiceBriefID) else { return nil }
            return MobileXHeaderAction(icon: "ellipsis", label: "Brief settings") {
                model.workflows.showVoiceBriefSettings(brief.id)
                openConfiguration()
            }
        default:
            return nil
        }
    }

    private func refresh() async {
        switch tab {
        case .home: await model.workflows.refreshLibrary()
        case .channels:
            if model.channels.selectedChannel(for: model.navigation.selectedChannelSource) != nil {
                await model.workflows.checkSelectedChannel()
            } else {
                await model.workflows.runDueChannelChecks()
            }
        case .briefs:
            if model.voiceBriefs.voiceBrief(for: model.navigation.selectedVoiceBriefID) != nil {
                await model.workflows.runSelectedVoiceBrief()
            } else {
                await model.workflows.runDueVoiceBriefs()
            }
        case .library: break
        }
    }

    private var title: String {
        switch tab {
        case .home: "Home"
        case .channels: "Channels"
        case .briefs: "Briefs"
        case .library: "Library"
        }
    }

    private var searchPrompt: String {
        switch tab {
        case .home: "Search Home"
        case .channels: "Search Channels"
        case .briefs: "Search Briefs"
        case .library: "Search Library"
        }
    }

    private var createLabel: String {
        switch tab {
        case .home: "Capture"
        case .channels: "New channel"
        case .briefs: "New brief"
        case .library: "Capture"
        }
    }

    private var allSelected: Bool {
        switch tab {
        case .home: model.navigation.selectedTopic == "All" || model.navigation.selectedTopic.isEmpty
        case .channels: model.navigation.selectedChannelSource.isEmpty
        case .briefs: model.navigation.selectedVoiceBriefID.isEmpty
        case .library: false
        }
    }

    private var emptyIcon: String {
        if !model.navigation.query.isEmpty { return "magnifyingglass" }
        return switch tab {
        case .home: "tray"
        case .channels: "dot.radiowaves.left.and.right"
        case .briefs: "headphones"
        case .library: "bookmark"
        }
    }

    private var emptyTitle: String {
        if !model.navigation.query.isEmpty { return "No matches" }
        return switch tab {
        case .home: "Nothing here yet"
        case .channels: "No channel updates"
        case .briefs: "No generated briefs"
        case .library: "Library is empty"
        }
    }

    private var emptyMessage: String {
        if !model.navigation.query.isEmpty { return "Try another search." }
        return switch tab {
        case .home: "Capture a link or note to start your feed."
        case .channels: "Add a channel, then pull to fetch its latest updates."
        case .briefs: "Create a brief from your channels, then generate an episode."
        case .library: "Highlights and recently deleted notes appear here."
        }
    }
}

#endif
