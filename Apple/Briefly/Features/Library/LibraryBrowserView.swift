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
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if model.navigation.activeSection == .channels {
                    browserContent
                } else if count == 0 {
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
            .padding(.horizontal, 0)
            .padding(.top, 0)
            .padding(.bottom, 80)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.hidden)
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
            VStack(spacing: 16) {
                feedHeader
                if channels.isEmpty {
                    XEmptyState(
                        icon: emptyIcon,
                        title: emptyTitle,
                        message: emptyDescription
                    )
                    .frame(minHeight: 360)
                } else {
                    channelIndex
                }
            }
            .frame(maxWidth: 680)
            .frame(maxWidth: .infinity, alignment: .top)
        }
    }

    private var channelIndex: some View {
        LazyVStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Channels")
                        .font(.title2.weight(.bold))
                    Text("Sources you follow")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(channels.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(18)
            .background(.regularMaterial)

            Divider()

            ForEach(channels) { channel in
                HStack(spacing: 13) {
                    Image(
                        systemName: channel.kind == .podcast
                            ? "waveform"
                            : "dot.radiowaves.left.and.right"
                    )
                    .font(.system(size: 18, weight: .medium))
                    .frame(width: 42, height: 42)
                    .background(Color.primary.opacity(0.06), in: Circle())

                    VStack(alignment: .leading, spacing: 3) {
                        Text(channel.title)
                            .font(.callout.weight(.semibold))
                            .lineLimit(1)
                        Text(channelDomain(channel.primarySource))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Text("\(channel.items.count) pending review")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 12)

                    Button {
                        model.workflows.showChannelSettings(channel.source)
                    } label: {
                        Image(systemName: "ellipsis")
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Settings for \(channel.title)")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 13)
                .contentShape(Rectangle())
                .onTapGesture { model.workflows.selectChannel(channel.source) }
                .overlay(alignment: .bottom) { Divider().padding(.leading, 70) }
            }
        }
        .background(.ultraThinMaterial.opacity(0.64))
        .overlay { Rectangle().stroke(Color.primary.opacity(0.10)) }
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
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
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
            } else {
                Button {
                    model.navigation.query = ""
                    model.workflows.showChannelSettings("new")
                } label: {
                    Image(systemName: "plus")
                        .frame(width: 44, height: 44)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .background(opaqueHeaderActionBackground, in: Circle())
                .help("New channel")
                .accessibilityLabel("New channel")
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
                Capsule()
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
                Capsule()
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
