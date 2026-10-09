import Foundation
import SwiftUI
import BrieflyCore

#if os(macOS)
extension EnvironmentValues {
    /// Set by ⌘F; the library list focuses its search field and clears the request.
    @Entry var librarySearchFocusRequest: Binding<Bool> = .constant(false)
}

struct LibraryCardBrowser: View {
    @Bindable var model: LibraryModel
    @Environment(\.librarySearchFocusRequest) private var searchFocusRequest
    @FocusState private var searchFocused: Bool
    @State private var topicBeingRenamed: String?
    @State private var renamedTopic = ""
    @State private var topicBeingDeleted: String?

    private var channels: [LibraryChannel] {
        model.channels.filteredChannels(query: model.navigation.query).filter {
            model.navigation.selectedChannelDomain == "All" ||
                channelDomain($0.primarySource) == model.navigation.selectedChannelDomain
        }
    }

    private var feedEntries: [LibraryEntry] {
        model.navigation.filteredEntries(trashEntries: model.selection.trashEntries)
    }

    var body: some View {
        Group {
            if model.navigation.activeSection == .channels {
                ChannelCandidateDocument(
                    model: model,
                    channelID: "",
                    showsNavigationHeader: false
                )
            } else {
                ScrollView {
                    Group {
                        if feedEntries.isEmpty {
                            XEmptyState(
                                icon: emptyIcon,
                                title: emptyTitle,
                                message: emptyDescription,
                                actionTitle: offersSampleLibrary ? "Add sample items" : nil,
                                action: offersSampleLibrary ? {
                                    Task { await model.workflows.addSampleLibrary() }
                                } : nil
                            )
                            .frame(minHeight: 360)
                        } else {
                            feedColumn(feedEntries)
                        }
                    }
                    .frame(maxWidth: 680)
                    .frame(maxWidth: .infinity, alignment: .top)
                }
                .scrollIndicators(.hidden)
            }
        }
        // The search field lives in the bar, outside the scroll content, so typing a
        // query with no matches keeps focus.
        .fadingHeaderBar {
            VStack(spacing: 0) {
                searchField
                feedHeader
            }
            .frame(maxWidth: 680)
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: searchFocusRequest.wrappedValue) {
            guard searchFocusRequest.wrappedValue else { return }
            searchFocused = true
            searchFocusRequest.wrappedValue = false
        }
        .alert("Rename topic", isPresented: renamingTopic) {
            TextField("Topic name", text: $renamedTopic)
            Button("Cancel", role: .cancel) {}
            Button("Rename") {
                guard let topicBeingRenamed else { return }
                Task { await model.workflows.renameTopic(topicBeingRenamed, to: renamedTopic) }
            }
            .disabled(renamedTopic.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .alert("Delete topic?", isPresented: deletingTopic) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                guard let topicBeingDeleted else { return }
                Task { await model.workflows.deleteTopic(topicBeingDeleted) }
            }
        } message: {
            Text("The topic will be removed, but its items will stay in your library.")
        }
    }

    private var searchField: some View {
        HStack(spacing: 9) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField(searchPrompt, text: $model.navigation.query)
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .accessibilityIdentifier("library.search")
            if !model.navigation.query.isEmpty {
                Button {
                    model.navigation.query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                        .frame(width: 32, height: 40)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 13)
        .frame(height: 40)
        .background(Color.primary.opacity(0.055), in: Rectangle())
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 4)
    }

    private var searchPrompt: String {
        if model.navigation.activeSection == .channels { return "Search channels" }
        return model.navigation.showingTrash ? "Search Trash" : "Search your library"
    }

    private var renamingTopic: Binding<Bool> {
        Binding(
            get: { topicBeingRenamed != nil },
            set: { if !$0 { topicBeingRenamed = nil } }
        )
    }

    private var deletingTopic: Binding<Bool> {
        Binding(
            get: { topicBeingDeleted != nil },
            set: { if !$0 { topicBeingDeleted = nil } }
        )
    }

    private func feedColumn(_ entries: [LibraryEntry]) -> some View {
        LazyVStack(spacing: 0) {
            ForEach(entries) { entry in
                let row = FeedEntryRow(
                    entry: entry,
                    action: { Task { await model.workflows.select(entry.id) } }
                )
                if model.navigation.showingTrash {
                    row.modifier(TrashItemContextMenu(model: model, entry: entry))
                } else {
                    row.modifier(EntryContextMenu(model: model, entry: entry))
                }
            }
        }
    }

    private var feedHeader: some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.navigation.showingTrash {
                HStack {
                    Text("Trash").font(.headline)
                    Spacer()
                    EmptyTrashButton(model: model)
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
            } else {
                feedTabs
                    .overlay(alignment: .topTrailing) {
                        if model.navigation.activeSection != .items {
                            feedHeaderAction
                                .padding(.top, 8)
                                .padding(.trailing, 10)
                        }
                    }
            }

            Color.clear
                .frame(height: 1)
                .padding(.top, 12)
        }
    }

    @ViewBuilder
    private var feedTabs: some View {
        switch model.navigation.activeSection {
        case .items:
            ScrollView(.horizontal) {
                HStack(spacing: 20) {
                    selectionTab("All", selected: model.navigation.selectedTopic == "All") {
                        Task { await model.workflows.showTopic("All") }
                    }
                    ForEach(Array(model.session.projection.documentTopics.prefix(7)), id: \.self) {
                        topicTab($0)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, 8)
            }
            .scrollIndicators(.hidden)
        case .channels:
            channelTabs
        }
    }

    @ViewBuilder
    private var feedHeaderAction: some View {
        switch model.navigation.activeSection {
        case .items:
            EmptyView()
        case .channels:
            if let channel = model.channels.selectedChannel(for: model.navigation.selectedChannelSource) {
                Button {
                    model.workflows.showChannelSettings(channel.source)
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(width: 44, height: 44)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .background(opaqueHeaderActionBackground, in: Circle())
                .help("Settings for \(channel.title)")
                .accessibilityLabel("Settings for \(channel.title)")
            }
        }
    }

    private var opaqueHeaderActionBackground: Color {
        Color(nsColor: .windowBackgroundColor)
    }

    private var channelTabs: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 20) {
                selectionTab("All", selected: model.navigation.selectedChannelSource.isEmpty) {
                    model.workflows.selectChannel("")
                }
                ForEach(Array(channels.prefix(7))) { channel in
                    selectionTab(
                        compactLabel(channel.title),
                        selected: model.navigation.selectedChannelSource == channel.source
                    ) {
                        model.workflows.selectChannel(channel.source)
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.trailing, 62)
            .padding(.top, 8)
        }
        .scrollIndicators(.hidden)
    }

    private func selectionTab(
        _ title: String,
        selected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 16, weight: selected ? .semibold : .medium))
                    .foregroundStyle(selected ? .primary : .secondary)
                    .lineLimit(1)
                Rectangle()
                    .fill(selected ? Color.accentColor : .clear)
                    .frame(height: 4)
            }
            .frame(minHeight: 44)
            .padding(.horizontal, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func topicTab(_ topic: String) -> some View {
        selectionTab(topic, selected: model.navigation.selectedTopic == topic) {
            Task { await model.workflows.showTopic(topic) }
        }
        .contextMenu {
            if model.session.canEdit {
                Button("Rename…", systemImage: "pencil") {
                    renamedTopic = topic
                    topicBeingRenamed = topic
                }
                Button("Delete…", systemImage: "trash", role: .destructive) {
                    topicBeingDeleted = topic
                }
            }
        }
    }

    private var emptyTitle: String {
        if !model.navigation.query.isEmpty { return "No matches" }
        return switch model.navigation.activeSection {
        case .items: model.navigation.showingTrash ? "Trash is empty" : "No items yet"
        case .channels:
            model.navigation.selectedChannelSource.isEmpty
                ? "No channels yet"
                : "Nothing waiting for review"
        }
    }

    private var emptyIcon: String {
        switch model.navigation.activeSection {
        case .items: model.navigation.showingTrash ? "trash" : "doc.text"
        case .channels: "dot.radiowaves.left.and.right"
        }
    }

    private var emptyDescription: String {
        if !model.navigation.query.isEmpty { return "Try another search." }
        return switch model.navigation.activeSection {
        case .items:
            model.navigation.showingTrash
                ? "Items moved to Trash appear here."
                : "Capture a link or note to start your library."
        case .channels:
            model.navigation.selectedChannelSource.isEmpty
                ? "Add a channel to follow its updates."
                : "New items from your channels appear here."
        }
    }

    private var offersSampleLibrary: Bool {
        model.navigation.activeSection == .items &&
            !model.navigation.showingTrash &&
            model.navigation.query.isEmpty &&
            model.navigation.selectedTopic == "All" &&
            model.session.projection.entries.isEmpty
    }
}

#endif
