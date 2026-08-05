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
struct MobileLibraryRows: View {
    @Bindable var model: LibraryModel
    let onOpenDetail: () -> Void

    private var notes: [LibraryEntry] {
        model.projection.entries.filter {
            $0.isMainLibraryEntry && $0.matches(model.query)
        }
    }

    private var trashNotes: [LibraryEntry] {
        model.trashEntries.filter { $0.matches(model.query) }
    }

    private var topics: [(name: String, count: Int)] {
        model.projection.documentTopics.compactMap { topic in
            let count = notes.count { $0.topicNames.contains(topic) }
            guard model.query.isEmpty || count > 0 else { return nil }
            return (name: topic, count: count)
        }
        .sorted {
            $0.count != $1.count
                ? $0.count > $1.count
                : $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    private var channels: [LibraryChannel] {
        model.filteredChannels.sorted {
            let leftCount = model.channelEntries(for: $0.source).count
            let rightCount = model.channelEntries(for: $1.source).count
            return leftCount != rightCount
                ? leftCount > rightCount
                : $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
    }

    private var briefs: [LibraryVoiceBrief] {
        let query = model.query.trimmingCharacters(in: .whitespacesAndNewlines)
        let matching = model.projection.voiceBriefDefinitions.filter { brief in
            guard !query.isEmpty else { return true }
            return brief.title.localizedCaseInsensitiveContains(query) ||
                model.projection.episodes(for: brief.id).contains { $0.matches(query) }
        }
        return matching.sorted {
            let leftCount = model.projection.episodes(for: $0.id).count
            let rightCount = model.projection.episodes(for: $1.id).count
            return leftCount != rightCount
                ? leftCount > rightCount
                : $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
    }

    private var itemCollectionCount: Int {
        1 + (model.query.isEmpty ? 1 : 0) + topics.count +
            (model.query.isEmpty || !trashNotes.isEmpty ? 1 : 0)
    }

    private var entries: [LibraryEntry] {
        let candidates = switch model.activeSection {
        case .items:
            model.filteredEntries
        case .channels:
            model.channelEntries(for: model.selectedChannelSource)
        case .briefs:
            model.projection.episodes(for: model.selectedVoiceBriefID)
        }
        return candidates
            .filter { $0.matches(model.query) }
            .sorted {
                ($0.createdAt ?? $0.updatedAt ?? "") <
                    ($1.createdAt ?? $1.updatedAt ?? "")
            }
    }

    private var emptyTitle: String {
        switch model.activeSection {
        case .items:
            model.query.isEmpty
                ? model.showingTrash
                    ? "Trash is empty"
                    : model.selectedTopic == "All"
                    ? "No documents yet"
                    : "No documents in \(model.selectedTopic)"
                : "No matching documents"
        case .channels:
            model.query.isEmpty ? "No channel items" : "No matching channel items"
        case .briefs:
            model.query.isEmpty ? "No voice briefs" : "No matching voice briefs"
        }
    }

    private var kind: MobileEntryKind {
        switch model.activeSection {
        case .items: .item
        case .channels: .channel
        case .briefs: .brief
        }
    }

    private var collectionTitle: String {
        switch model.activeSection {
        case .items:
            model.showingTrash
                ? "Trash"
                : model.selectedTopic == "All" ? "Inbox" : model.selectedTopic
        case .channels:
            model.selectedChannel?.title ?? "Channel"
        case .briefs:
            model.selectedVoiceBrief?.title ?? "Voice Brief"
        }
    }

    var body: some View {
        Group {
            switch model.activeSection {
            case .items:
                if model.selectedTopic.isEmpty && !model.showingTrash {
                    itemCollections
                } else {
                    entryCollection
                }
            case .channels:
                if model.selectedChannelSource.isEmpty || model.selectedChannelSource == "new" {
                    channelCollections
                } else {
                    entryCollection
                }
            case .briefs:
                if model.selectedVoiceBriefID.isEmpty || model.selectedVoiceBriefID == "new" {
                    briefCollections
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
                subtitle: "\(notes.count) notes"
            ) {
                Task { await model.showTopic("All") }
            }

            if model.query.isEmpty {
                MobileCollectionCard(
                    key: "notes:highlights",
                    icon: "highlighter",
                    eyebrow: "LIBRARY",
                    title: "Highlights",
                    subtitle: model.loadedHighlightCount.map { "\($0) highlights" } ?? "Open to load"
                ) {
                    model.showHighlights()
                    onOpenDetail()
                }
            }

            ForEach(topics, id: \.name) { topic in
                MobileCollectionCard(
                    key: "topic:\(topic.name)",
                    icon: "folder",
                    eyebrow: "TOPIC",
                    title: topic.name,
                    subtitle: "\(topic.count) notes"
                ) {
                    Task { await model.showTopic(topic.name) }
                }
            }

            if model.query.isEmpty || !trashNotes.isEmpty {
                MobileCollectionCard(
                    key: "notes:trash",
                    icon: "trash",
                    eyebrow: "LIBRARY",
                    title: "Trash",
                    subtitle: model.loadedTrashCount.map { "\($0) notes" } ?? "Open to load"
                ) {
                    model.showTrash()
                }
            }
        }
    }

    private var channelCollections: some View {
        collectionScroll { height in
            if channels.isEmpty {
                SidebarEmpty(
                    icon: "dot.radiowaves.left.and.right",
                    title: model.query.isEmpty ? "No channels yet" : "No matching channels"
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
                        subtitle: "\(model.channelEntries(for: channel.source).count) notes",
                        settingsLabel: "Settings for \(channel.title)",
                        settingsAction: {
                            model.showChannelSettings(channel.source)
                            onOpenDetail()
                        }
                    ) {
                        model.selectChannel(channel.source)
                    }
                }
            }
        }
    }

    private var briefCollections: some View {
        collectionScroll { height in
            if briefs.isEmpty {
                SidebarEmpty(
                    icon: "headphones",
                    title: model.query.isEmpty ? "No voice briefs yet" : "No matching voice briefs"
                )
            } else {
                ForEach(briefs, id: \.id) { brief in
                    MobileCollectionCard(
                        key: "brief:\(brief.id)",
                        palette: .brief,
                        minimumHeight: briefs.count == 1 ? height : nil,
                        icon: "headphones",
                        eyebrow: "VOICE BRIEF",
                        title: brief.title,
                        subtitle: "\(model.projection.episodes(for: brief.id).count) episodes",
                        settingsLabel: "Settings for \(brief.title)",
                        settingsAction: {
                            model.showVoiceBriefSettings(brief.id)
                            onOpenDetail()
                        }
                    ) {
                        model.selectVoiceBrief(brief.id)
                    }
                }
            }
        }
    }

    private var entryCollection: some View {
        VStack(spacing: 0) {
            MobileCollectionHeader(title: collectionTitle, count: entries.count) {
                Task { await model.show(model.activeSection) }
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
            selected: model.selectedIDs.contains(entry.id)
        ) {
            Task {
                await model.select(entry.id)
                onOpenDetail()
            }
        }
        .modifier(EntryContextMenu(model: model, entry: entry))
    }
}
#endif
