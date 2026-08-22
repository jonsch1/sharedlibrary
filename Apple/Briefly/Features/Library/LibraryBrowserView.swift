import Foundation
import SwiftUI
import BrieflyCore

#if os(macOS)
struct LibraryCardBrowser: View {
    @Bindable var model: LibraryModel

    private var channels: [LibraryChannel] {
        model.channels.filteredChannels(query: model.navigation.query).filter {
            model.navigation.selectedChannelDomain == "All" ||
                channelDomain($0.primarySource) == model.navigation.selectedChannelDomain
        }
    }

    private var count: Int {
        model.navigation.filteredEntries(trashEntries: model.selection.trashEntries).count
    }

    private var feedEntries: [LibraryEntry] {
        model.navigation.filteredEntries(trashEntries: model.selection.trashEntries)
    }

    var body: some View {
        Group {
            if model.navigation.activeSection == .channels {
                VStack(spacing: 0) {
                    feedHeader
                        .frame(maxWidth: 680)
                        .frame(maxWidth: .infinity, alignment: .top)
                    ChannelCandidateDocument(
                        model: model,
                        channelID: "",
                        showsNavigationHeader: false
                    )
                }
            } else {
                ScrollView {
                    if count == 0 {
                        VStack(spacing: 0) {
                            feedHeader
                            XEmptyState(
                                icon: emptyIcon,
                                title: emptyTitle,
                                message: emptyDescription
                            )
                            .frame(minHeight: 360)
                        }
                        .frame(maxWidth: 680)
                        .frame(maxWidth: .infinity, alignment: .top)
                    } else {
                        browserContent
                    }
                }
                .scrollIndicators(.hidden)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.ultraThinMaterial.opacity(0.24))
    }

    @ViewBuilder
    private var browserContent: some View {
        switch model.navigation.activeSection {
        case .items:
            feedColumn(feedEntries)
                .frame(maxWidth: 680)
                .frame(maxWidth: .infinity, alignment: .top)
        case .channels:
            EmptyView()
        }
    }

    private func feedColumn(_ entries: [LibraryEntry]) -> some View {
        LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
            Section {
                ForEach(entries) { entry in
                    let row = FeedEntryRow(
                        entry: entry,
                        action: { Task { await model.workflows.select(entry.id) } }
                    )
                    if model.navigation.showingTrash {
                        row
                    } else {
                        row.modifier(EntryContextMenu(model: model, entry: entry))
                    }
                }
            } header: {
                feedHeader
            }
        }
    }

    private var feedHeader: some View {
        VStack(alignment: .leading, spacing: 0) {
            feedTabs

            Color.clear
                .frame(height: 1)
                .padding(.top, 12)
        }
        #if os(macOS)
        .macLiquidGlass(
            in: Rectangle()
        )
        #else
        .background(.regularMaterial)
        #endif
        .overlay(alignment: .topTrailing) {
            if model.navigation.activeSection != .items {
                feedHeaderAction
                    .padding(.top, 12)
                    .padding(.trailing, 10)
            }
        }
    }

    @ViewBuilder
    private var feedTabs: some View {
        switch model.navigation.activeSection {
        case .items:
            ScrollView(.horizontal) {
                HStack(spacing: 20) {
                    topicTab("All")
                    ForEach(Array(model.session.projection.documentTopics.prefix(7)), id: \.self) {
                        topicTab($0)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, 24)
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
            .padding(.top, 24)
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
        let selected = model.navigation.selectedTopic == topic
        return Button {
            Task { await model.workflows.showTopic(topic) }
        } label: {
            VStack(spacing: 8) {
                Text(topic)
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

    private var emptyTitle: String {
        if !model.navigation.query.isEmpty { return "No matches" }
        return switch model.navigation.activeSection {
        case .items: model.navigation.showingTrash ? "Trash is empty" : "No notes yet"
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
                ? "Notes moved to Trash appear here."
                : "Add a note to start your library."
        case .channels:
            model.navigation.selectedChannelSource.isEmpty
                ? "Add a channel to follow its updates."
                : "Fetch fresh candidates when you are ready."
        }
    }
}

#endif
