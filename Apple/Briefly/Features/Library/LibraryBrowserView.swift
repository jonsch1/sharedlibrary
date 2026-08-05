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

#if os(macOS)
struct LibraryCardBrowser: View {
    @Bindable var model: LibraryModel

    private var channels: [LibraryChannel] {
        model.filteredChannels.filter {
            model.selectedChannelDomain == "All" ||
                channelDomain($0.primarySource) == model.selectedChannelDomain
        }
    }

    private var channelEntries: [LibraryEntry] {
        guard !model.selectedChannelSource.isEmpty else { return [] }
        return model.channelEntries(for: model.selectedChannelSource).filter {
            $0.matches(model.query)
        }
    }

    private var allChannelEntries: [LibraryEntry] {
        var seen = Set<String>()
        return channels
            .flatMap { model.channelEntries(for: $0.source) }
            .filter { seen.insert($0.id).inserted && $0.matches(model.query) }
            .sorted {
                ($0.createdAt ?? $0.updatedAt ?? "") >
                    ($1.createdAt ?? $1.updatedAt ?? "")
            }
    }

    private var voiceBriefEntries: [LibraryEntry] {
        model.projection.entries.filter {
            $0.entryType == "voice_brief_episode" &&
                (model.selectedVoiceBriefID.isEmpty ||
                    $0.voiceBriefID == model.selectedVoiceBriefID) &&
                $0.matches(model.query)
        }
        .sorted {
            ($0.createdAt ?? $0.updatedAt ?? "") >
                ($1.createdAt ?? $1.updatedAt ?? "")
        }
    }

    private var count: Int {
        switch model.activeSection {
        case .items: model.filteredEntries.count
        case .channels:
            model.selectedChannelSource.isEmpty ? allChannelEntries.count : channelEntries.count
        case .briefs:
            voiceBriefEntries.count
        }
    }

    private var feedEntries: [LibraryEntry]? {
        switch model.activeSection {
        case .items:
            model.filteredEntries
        case .channels:
            model.selectedChannelSource.isEmpty ? allChannelEntries : channelEntries
        case .briefs:
            voiceBriefEntries
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
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
        if let feedEntries {
            feedColumn(feedEntries)
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
                        Text("\(model.channelEntries(for: channel.source).count) saved notes")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 12)

                    Button {
                        model.showChannelSettings(channel.source)
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
                .onTapGesture { model.selectChannel(channel.source) }
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
                        action: { Task { await model.select(entry.id) } }
                    )
                    if model.showingTrash {
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

            if model.activeSection == .briefs, let brief = model.selectedVoiceBrief {
                briefRefreshPrompt(brief)
                    .padding(.horizontal, 14)
                    .padding(.top, 12)
            }

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
            if model.activeSection != .items {
                feedHeaderAction
                    .padding(.top, 12)
                    .padding(.trailing, 10)
            }
        }
    }

    @ViewBuilder
    private var feedTabs: some View {
        switch model.activeSection {
        case .items:
            ScrollView(.horizontal) {
                HStack(spacing: 20) {
                    topicTab("All")
                    ForEach(Array(model.projection.documentTopics.prefix(7)), id: \.self) {
                        topicTab($0)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, 24)
            }
            .scrollIndicators(.hidden)
        case .channels:
            channelTabs
        case .briefs:
            briefTabs
        }
    }

    @ViewBuilder
    private var feedHeaderAction: some View {
        switch model.activeSection {
        case .items:
            EmptyView()
        case .channels:
            if let channel = model.selectedChannel {
                Button {
                    model.showChannelSettings(channel.source)
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
                    model.query = ""
                    model.showChannelSettings("new")
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
        case .briefs:
            if let brief = model.selectedVoiceBrief {
                Button {
                    model.showVoiceBriefSettings(brief.id)
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(width: 44, height: 44)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .background(opaqueHeaderActionBackground, in: Circle())
                .help("Settings for \(brief.title)")
                .accessibilityLabel("Settings for \(brief.title)")
            } else {
                Button {
                    model.query = ""
                    model.showVoiceBriefSettings("new")
                } label: {
                    Image(systemName: "plus")
                        .frame(width: 44, height: 44)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .background(opaqueHeaderActionBackground, in: Circle())
                .help("New brief")
                .accessibilityLabel("New brief")
            }
        }
    }

    private var opaqueHeaderActionBackground: Color {
        Color(nsColor: .windowBackgroundColor)
    }

    private var channelTabs: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 20) {
                selectionTab("All", selected: model.selectedChannelSource.isEmpty) {
                    model.selectChannel("")
                }
                ForEach(Array(channels.prefix(7))) { channel in
                    selectionTab(
                        compactLabel(channel.title),
                        selected: model.selectedChannelSource == channel.source
                    ) {
                        model.selectChannel(channel.source)
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.trailing, 62)
            .padding(.top, 24)
        }
        .scrollIndicators(.hidden)
    }

    private var briefTabs: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 20) {
                selectionTab("All", selected: model.selectedVoiceBriefID.isEmpty) {
                    model.selectVoiceBrief("")
                }
                ForEach(Array(model.projection.voiceBriefDefinitions.prefix(7)), id: \.id) { brief in
                    selectionTab(
                        brief.title,
                        selected: model.selectedVoiceBriefID == brief.id
                    ) {
                        model.selectVoiceBrief(brief.id)
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
        let selected = model.selectedTopic == topic
        return Button {
            Task { await model.showTopic(topic) }
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

    private func briefRefreshPrompt(_ brief: LibraryVoiceBrief) -> some View {
        BriefPreparationPanel(model: model, brief: brief)
    }

    private var feedRail: some View {
        VStack(spacing: 14) {
            HStack(spacing: 9) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search your library", text: $model.query)
                    .textFieldStyle(.plain)
            }
            .padding(.horizontal, 14)
            .frame(height: 44)
            .background(.regularMaterial)
            .clipShape(Capsule())
            .overlay { Capsule().stroke(Color.primary.opacity(0.10)) }

            FeedRailCard(title: "Collections") {
                ForEach(Array(model.projection.documentTopics.prefix(6)), id: \.self) { topic in
                    Button {
                        Task { await model.showTopic(topic) }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "folder")
                                .foregroundStyle(.secondary)
                            Text(topic)
                                .lineLimit(1)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 5)
                    }
                    .buttonStyle(.plain)
                }
            }

        }
    }

    private var feedTitle: String {
        switch model.activeSection {
        case .items:
            model.showingTrash ? "Trash" : model.selectedTopic == "All" ? "For you" : model.selectedTopic
        case .channels:
            model.selectedChannel?.title ?? "Channel"
        case .briefs:
            model.selectedVoiceBrief?.title ?? "Briefs"
        }
    }

    @ViewBuilder
    private var desktopActions: some View {
        if model.activeSection == .channels,
            let channel = model.selectedChannel
        {
            HStack {
                Spacer()
                Button {
                    Task { await model.checkSelectedChannel() }
                } label: {
                    if model.isCheckingChannel {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Fetch fresh", systemImage: "arrow.clockwise")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isCheckingChannel)

                Button {
                    model.showChannelSettings(channel.source)
                } label: {
                    Image(systemName: "gearshape")
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("Settings for \(channel.title)")
                .help("Settings for \(channel.title)")
            }
        } else if model.activeSection == .briefs,
            let brief = model.selectedVoiceBrief
        {
            HStack {
                Spacer()
                Button {
                    model.showVoiceBriefSettings(brief.id)
                } label: {
                    Image(systemName: "gearshape")
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("Settings for \(brief.title)")
                .help("Settings for \(brief.title)")
            }
        }
    }

    @ViewBuilder
    private func noteCard(
        _ entry: LibraryEntry,
        minimumHeight: CGFloat? = nil,
        featured: Bool = false
    ) -> some View {
        let card = GrainyEntryCard(
            entry: entry,
            minimumHeight: minimumHeight,
            featured: featured,
            action: { Task { await model.select(entry.id) } }
        )
        if model.showingTrash {
            card
        } else {
            card.modifier(EntryContextMenu(model: model, entry: entry))
        }
    }

    private func channelCard(_ channel: LibraryChannel) -> some View {
        BrowserCard(
            action: { model.selectChannel(channel.source) },
            settingsAction: { model.showChannelSettings(channel.source) },
            settingsLabel: "Settings for \(channel.title)",
            palette: .channel,
            variationKey: channel.source
        ) {
            CardEyebrow(
                icon: channel.kind == .podcast
                    ? "waveform"
                    : "dot.radiowaves.left.and.right",
                title: channelDomain(channel.primarySource)
            )
            Text(channel.title)
                .font(.title3.weight(.semibold))
                .lineLimit(2)
            Text(channel.sources.joined(separator: " · "))
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)
            Label(
                "\(model.channelEntries(for: channel.source).count) notes",
                systemImage: "doc.text"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var emptyTitle: String {
        if !model.query.isEmpty { return "No matches" }
        return switch model.activeSection {
        case .items: model.showingTrash ? "Trash is empty" : "No notes yet"
        case .channels:
            model.selectedChannelSource.isEmpty ? "No channels yet" : "No notes yet"
        case .briefs:
            "No briefs yet"
        }
    }

    private var emptyIcon: String {
        switch model.activeSection {
        case .items: model.showingTrash ? "trash" : "doc.text"
        case .channels: "dot.radiowaves.left.and.right"
        case .briefs: "headphones"
        }
    }

    private var emptyDescription: String {
        if !model.query.isEmpty { return "Try another search." }
        return switch model.activeSection {
        case .items:
            model.showingTrash
                ? "Notes moved to Trash appear here."
                : "Add a note to start your library."
        case .channels:
            model.selectedChannelSource.isEmpty
                ? "Add a channel to follow its updates."
                : "New notes from this channel appear here."
        case .briefs:
            model.projection.voiceBriefDefinitions.isEmpty
                ? "Create a voice brief from your channels."
                : "Generated briefs appear here."
        }
    }
}

#endif
