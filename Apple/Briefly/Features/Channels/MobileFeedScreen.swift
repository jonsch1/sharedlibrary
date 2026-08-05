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
            candidates = model.filteredEntries
        case .channels:
            if model.selectedChannelSource.isEmpty {
                var seen = Set<String>()
                candidates = model.channels.flatMap { model.channelEntries(for: $0.source) }
                    .filter { seen.insert($0.id).inserted }
            } else {
                candidates = model.channelEntries(for: model.selectedChannelSource)
            }
        case .briefs:
            if model.selectedVoiceBriefID.isEmpty {
                candidates = model.projection.voiceBriefDefinitions.flatMap {
                    model.projection.episodes(for: $0.id)
                }
            } else {
                candidates = model.projection.episodes(for: model.selectedVoiceBriefID)
            }
        case .library:
            candidates = []
        }
        return candidates
            .filter { $0.matches(model.query) }
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

                        if tab == .briefs, let brief = model.selectedVoiceBrief {
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

                        if tab == .briefs, let brief = model.selectedVoiceBrief {
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
        .animation(.smooth(duration: 0.3), value: model.selectedVoiceBriefID)
        .animation(.snappy(duration: 0.24), value: showsSearch)
        .onDisappear {
            showsSearch = false
            model.query = ""
        }
    }

    private func closeSearch() {
        model.query = ""
        showsSearch = false
    }

    private let floatingHeaderHeight: CGFloat = 116

    private var floatingHeader: some View {
        VStack(spacing: 0) {
            if showsSearch {
                MobileXSearchField(
                    text: $model.query,
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
                    case .home: Task { await model.showTopic("All") }
                    case .channels: model.selectedChannelSource = ""
                    case .briefs: model.selectedVoiceBriefID = ""
                    case .library: break
                    }
                }

                switch tab {
                case .home:
                    ForEach(model.projection.documentTopics, id: \.self) { topic in
                        choiceButton(topic, selected: model.selectedTopic == topic) {
                            Task { await model.showTopic(topic) }
                        }
                    }
                case .channels:
                    ForEach(model.channels) { channel in
                        choiceButton(
                            channel.title,
                            selected: model.selectedChannelSource == channel.source
                        ) {
                            model.selectChannel(channel.source)
                        }
                    }
                case .briefs:
                    ForEach(model.projection.voiceBriefDefinitions, id: \.id) { brief in
                        choiceButton(
                            brief.title,
                            selected: model.selectedVoiceBriefID == brief.id
                        ) {
                            model.selectVoiceBrief(brief.id)
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
            guard let channel = model.selectedChannel else { return nil }
            return MobileXHeaderAction(icon: "ellipsis", label: "Channel settings") {
                model.showChannelSettings(channel.source)
                openConfiguration()
            }
        case .briefs:
            guard let brief = model.selectedVoiceBrief else { return nil }
            return MobileXHeaderAction(icon: "ellipsis", label: "Brief settings") {
                model.showVoiceBriefSettings(brief.id)
                openConfiguration()
            }
        default:
            return nil
        }
    }

    private func refresh() async {
        switch tab {
        case .home: await model.refreshLibrary()
        case .channels:
            if model.selectedChannel != nil { await model.checkSelectedChannel() }
            else { await model.runDueChannelChecks() }
        case .briefs:
            if model.selectedVoiceBrief != nil { await model.runSelectedVoiceBrief() }
            else { await model.runDueVoiceBriefs() }
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
        case .home: model.selectedTopic == "All" || model.selectedTopic.isEmpty
        case .channels: model.selectedChannelSource.isEmpty
        case .briefs: model.selectedVoiceBriefID.isEmpty
        case .library: false
        }
    }

    private var emptyIcon: String {
        if !model.query.isEmpty { return "magnifyingglass" }
        return switch tab {
        case .home: "tray"
        case .channels: "dot.radiowaves.left.and.right"
        case .briefs: "headphones"
        case .library: "bookmark"
        }
    }

    private var emptyTitle: String {
        if !model.query.isEmpty { return "No matches" }
        return switch tab {
        case .home: "Nothing here yet"
        case .channels: "No channel updates"
        case .briefs: "No generated briefs"
        case .library: "Library is empty"
        }
    }

    private var emptyMessage: String {
        if !model.query.isEmpty { return "Try another search." }
        return switch tab {
        case .home: "Capture a link or note to start your feed."
        case .channels: "Add a channel, then pull to fetch its latest updates."
        case .briefs: "Create a brief from your channels, then generate an episode."
        case .library: "Highlights and recently deleted notes appear here."
        }
    }
}

#endif
