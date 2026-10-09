import Foundation
import SwiftUI
import BrieflyCore

#if os(iOS)
struct MobileLibraryRows: View {
    @Bindable var model: LibraryModel
    let onOpenDetail: () -> Void

    private var notes: [LibraryEntry] {
        model.session.projection.entries.filter {
            $0.isMainLibraryEntry && $0.matches(model.navigation.query)
        }
    }

    private var trashNotes: [LibraryEntry] {
        model.selection.trashEntries.filter { $0.matches(model.navigation.query) }
    }

    private var topics: [(name: String, count: Int)] {
        model.session.projection.documentTopics.compactMap { topic in
            let count = notes.count { $0.topicNames.contains(topic) }
            guard model.navigation.query.isEmpty || count > 0 else { return nil }
            return (name: topic, count: count)
        }
        .sorted {
            $0.count != $1.count
                ? $0.count > $1.count
                : $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    private var channels: [LibraryChannel] {
        model.channels.filteredChannels(query: model.navigation.query).sorted {
            let leftCount = model.channels.channelEntries(for: $0.source).count
            let rightCount = model.channels.channelEntries(for: $1.source).count
            return leftCount != rightCount
                ? leftCount > rightCount
                : $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
    }

    private var itemCollectionCount: Int {
        1 + (model.navigation.query.isEmpty ? 1 : 0) + topics.count +
            (model.navigation.query.isEmpty || !trashNotes.isEmpty ? 1 : 0)
    }

    private var entries: [LibraryEntry] {
        let candidates = switch model.navigation.activeSection {
        case .items:
            model.navigation.filteredEntries(trashEntries: model.selection.trashEntries)
        case .channels:
            model.channels.channelEntries(for: model.navigation.selectedChannelSource)
        }
        return candidates
            .filter { $0.matches(model.navigation.query) }
            .sorted {
                ($0.createdAt ?? $0.updatedAt ?? "") <
                    ($1.createdAt ?? $1.updatedAt ?? "")
            }
    }

    private var emptyTitle: String {
        switch model.navigation.activeSection {
        case .items:
            model.navigation.query.isEmpty
                ? model.navigation.showingTrash
                    ? "Trash is empty"
                    : model.navigation.selectedTopic == "All"
                    ? "No items yet"
                    : "No items in \(model.navigation.selectedTopic)"
                : "No matching items"
        case .channels:
            model.navigation.query.isEmpty ? "No channel items" : "No matching channel items"
        }
    }

    private var kind: MobileEntryKind {
        switch model.navigation.activeSection {
        case .items: .item
        case .channels: .channel
        }
    }

    private var collectionTitle: String {
        switch model.navigation.activeSection {
        case .items:
            model.navigation.showingTrash
                ? "Trash"
                : model.navigation.selectedTopic == "All" ? "Inbox" : model.navigation.selectedTopic
        case .channels:
            model.channels.selectedChannel(for: model.navigation.selectedChannelSource)?.title ?? "Channel"
        }
    }

    var body: some View {
        Group {
            switch model.navigation.activeSection {
            case .items:
                if model.navigation.selectedTopic.isEmpty && !model.navigation.showingTrash {
                    itemCollections
                } else {
                    entryCollection
                }
            case .channels:
                if model.navigation.selectedChannelSource.isEmpty || model.navigation.selectedChannelSource == "new" {
                    channelCollections
                } else {
                    entryCollection
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func collectionScroll<Content: View>(
        @ViewBuilder content: @escaping (CGFloat) -> Content
    ) -> some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 8) {
                    content(geometry.size.height)
                }
                .padding(.horizontal, 8)
                .padding(.top, 8)
                .padding(.bottom, 150)
                .frame(minHeight: geometry.size.height, alignment: .top)
            }
            .defaultScrollAnchor(.bottom)
            .scrollIndicators(.hidden)
        }
    }

    private var itemCollections: some View {
        collectionScroll { height in
            MobileCollectionCard(
                key: "notes:inbox",
                minimumHeight: itemCollectionCount == 1 ? height : nil,
                icon: "tray",
                eyebrow: "LIBRARY",
                title: "Inbox",
                subtitle: "\(notes.count) items"
            ) {
                Task { await model.workflows.showTopic("All") }
            }

            if notes.isEmpty && model.navigation.query.isEmpty {
                MobileCollectionCard(
                    key: "sample:library",
                    icon: "books.vertical",
                    eyebrow: "SAMPLE",
                    title: "Sample items",
                    subtitle: "Add five prepared items"
                ) {
                    Task { await model.workflows.addSampleLibrary() }
                }
            }

            if model.navigation.query.isEmpty {
                MobileCollectionCard(
                    key: "notes:highlights",
                    icon: "highlighter",
                    eyebrow: "LIBRARY",
                    title: "Highlights",
                    subtitle: model.selection.loadedHighlightCount.map { "\($0) highlights" } ?? "Open to load"
                ) {
                    model.workflows.showHighlights()
                    onOpenDetail()
                }
            }

            ForEach(topics, id: \.name) { topic in
                MobileCollectionCard(
                    key: "topic:\(topic.name)",
                    icon: "folder",
                    eyebrow: "TOPIC",
                    title: topic.name,
                    subtitle: "\(topic.count) items"
                ) {
                    Task { await model.workflows.showTopic(topic.name) }
                }
            }

            if model.navigation.query.isEmpty || !trashNotes.isEmpty {
                MobileCollectionCard(
                    key: "notes:trash",
                    icon: "trash",
                    eyebrow: "LIBRARY",
                    title: "Trash",
                    subtitle: model.selection.loadedTrashCount.map { "\($0) items" } ?? "Open to load"
                ) {
                    model.workflows.showTrash()
                }
            }
        }
    }

    private var channelCollections: some View {
        collectionScroll { height in
            if channels.isEmpty {
                SidebarEmpty(
                    icon: "dot.radiowaves.left.and.right",
                    title: model.navigation.query.isEmpty ? "No channels yet" : "No matching channels"
                )
            } else {
                ForEach(channels) { channel in
                    MobileCollectionCard(
                        key: "channel:\(channel.source)",
                        palette: .channel,
                        minimumHeight: channels.count == 1 ? height : nil,
                        icon: channel.kind == .podcast
                            ? "waveform"
                            : "dot.radiowaves.left.and.right",
                        eyebrow: channelDomain(channel.primarySource).uppercased(),
                        title: channel.title,
                        subtitle: "\(model.channels.channelEntries(for: channel.source).count) items",
                        settingsLabel: "Settings for \(channel.title)",
                        settingsAction: {
                            model.workflows.showChannelSettings(channel.source)
                            onOpenDetail()
                        }
                    ) {
                        model.workflows.selectChannel(channel.source)
                    }
                }
            }
        }
    }

    private var entryCollection: some View {
        VStack(spacing: 0) {
            MobileCollectionHeader(title: collectionTitle, count: entries.count) {
                Task { await model.workflows.show(model.navigation.activeSection) }
            }

            if entries.isEmpty {
                SidebarEmpty(icon: "doc.text", title: emptyTitle)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            } else {
                GeometryReader { geometry in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(entries) { entry in
                                entryCard(entry)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.top, 8)
                        .padding(.bottom, 150)
                        .frame(
                            maxWidth: .infinity,
                            minHeight: geometry.size.height,
                            alignment: .top
                        )
                    }
                    .defaultScrollAnchor(.bottom)
                    .scrollIndicators(.hidden)
                }
            }
        }
    }

    @ViewBuilder
    private func entryCard(_ entry: LibraryEntry) -> some View {
        MobileEntryCard(
            entry: entry,
            kind: kind,
            selected: model.selection.selectedIDs.contains(entry.id)
        ) {
            Task {
                await model.workflows.select(entry.id)
                onOpenDetail()
            }
        }
        .modifier(EntryContextMenu(model: model, entry: entry))
    }
}
#endif
