import Foundation
import SwiftUI
import BrieflyCore

#if os(iOS)
struct MobileXFeedScreen: View {
    @Bindable var model: LibraryModel
    let tab: MobilePrimaryTab
    let openEntry: (LibraryEntry) -> Void
    let openChannel: (LibraryChannel) -> Void
    let create: () -> Void
    @State private var showsSearch = false

    private var entries: [LibraryEntry] {
        let candidates: [LibraryEntry]
        switch tab {
        case .home:
            candidates = model.navigation.filteredEntries
        case .channels, .highlights, .settings:
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
            if tab == .channels {
                channelContent
            } else if entries.isEmpty {
                ScrollView {
                    XEmptyState(
                        icon: emptyIcon,
                        title: emptyTitle,
                        message: emptyMessage
                    )
                    .frame(maxWidth: 720, minHeight: 420)
                    .frame(maxWidth: .infinity)
                }
                .scrollIndicators(.hidden)
                .refreshable { await refresh() }
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        let pending = entries.filter { $0.captureRequest.map { $0.state != .ready } ?? false }
                        if !pending.isEmpty {
                            HStack {
                                Text("Inbox").font(.headline)
                                Text("\(pending.count)").foregroundStyle(.secondary)
                                Spacer()
                            }.padding(16)
                            ForEach(pending) { entry in
                                PendingCaptureRow(entry: entry, status: model.captureStatus(for: entry)) {
                                    openEntry(entry)
                                }
                                .modifier(EntryContextMenu(model: model, entry: entry))
                            }
                        }

                        ForEach(entries.filter { $0.captureRequest == nil || $0.captureRequest?.state == .ready }) { entry in
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
        .mobileHeaderBar { floatingHeader }
        .background { BrieflyAtmosphere().ignoresSafeArea() }
        .toolbar(.hidden, for: .navigationBar)
        .animation(.snappy(duration: 0.24), value: showsSearch)
        .onDisappear {
            showsSearch = false
            model.navigation.query = ""
        }
    }

    private var channelContent: some View {
        ChannelCandidateDocument(
            model: model,
            channelID: "",
            showsNavigationHeader: false
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func closeSearch() {
        model.navigation.query = ""
        showsSearch = false
    }

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
                    search: MobileXHeaderAction(
                        icon: "magnifyingglass",
                        label: searchPrompt,
                        identifier: "library.search.open",
                        action: { showsSearch = true }
                    ),
                    primary: MobileXHeaderAction(
                        icon: createIcon,
                        label: createLabel,
                        identifier: createLabel == "Capture" ? "capture.open" : nil,
                        action: create
                    )
                )
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            choices
        }
        .zIndex(10)
    }

    private var choices: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ChoiceChip(title: "All", isSelected: allSelected) {
                    switch tab {
                    case .home: Task { await model.workflows.showTopic("All") }
                    case .channels: model.navigation.selectedChannelSource = ""
                    case .highlights, .settings: break
                    }
                }

                switch tab {
                case .home:
                    ForEach(model.session.projection.documentTopics, id: \.self) { topic in
                        ChoiceChip(title: topic, isSelected: model.navigation.selectedTopic == topic) {
                            Task { await model.workflows.showTopic(topic) }
                        }
                    }
                case .channels:
                    ForEach(model.channels.channels) { channel in
                        ChoiceChip(
                            title: channel.title,
                            isSelected: model.navigation.selectedChannelSource == channel.source
                        ) {
                            openChannel(channel)
                        }
                    }
                case .highlights, .settings:
                    EmptyView()
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 4)
        }
        .defaultScrollAnchor(.leading)
    }

    private func refresh() async {
        switch tab {
        case .home: await model.workflows.sync()
        case .channels:
            if model.channels.selectedChannel(for: model.navigation.selectedChannelSource) != nil {
                await model.workflows.checkSelectedChannel()
            } else {
                await model.workflows.runDueChannelChecks()
            }
        case .highlights, .settings: break
        }
    }

    private var title: String {
        switch tab {
        case .home: "Home"
        case .channels: "Channels"
        case .highlights, .settings: "Highlights"
        }
    }

    private var searchPrompt: String {
        switch tab {
        case .home: "Search Home"
        case .channels: "Search Channels"
        case .highlights, .settings: "Search Highlights"
        }
    }

    private var createLabel: String {
        switch tab {
        case .home: "Capture"
        case .channels: "Manage Channels"
        case .highlights, .settings: "Capture"
        }
    }

    private var createIcon: String {
        tab == .channels ? "slider.horizontal.3" : "plus"
    }

    private var allSelected: Bool {
        switch tab {
        case .home: model.navigation.selectedTopic == "All" || model.navigation.selectedTopic.isEmpty
        case .channels: model.navigation.selectedChannelSource.isEmpty
        case .highlights, .settings: false
        }
    }

    private var emptyIcon: String {
        if !model.navigation.query.isEmpty { return "magnifyingglass" }
        return switch tab {
        case .home: "tray"
        case .channels: "dot.radiowaves.left.and.right"
        case .highlights, .settings: "highlighter"
        }
    }

    private var emptyTitle: String {
        if !model.navigation.query.isEmpty { return "No matches" }
        return switch tab {
        case .home: "Nothing here yet"
        case .channels: "No channels yet"
        case .highlights, .settings: "No highlights yet"
        }
    }

    private var emptyMessage: String {
        if !model.navigation.query.isEmpty { return "Try another search." }
        return switch tab {
        case .home: "Capture a link or note to start your feed."
        case .channels: "Add a channel, then pull to check it for new items."
        case .highlights, .settings: "Select a passage in any item, then choose Highlight."
        }
    }
}

#endif
