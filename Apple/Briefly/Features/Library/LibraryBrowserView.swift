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
        model.channels.filteredChannels.filter {
            model.navigation.selectedChannelDomain == "All" ||
                channelDomain($0.primarySource) == model.navigation.selectedChannelDomain
        }
    }

    private var channelEntries: [LibraryEntry] {
        guard !model.navigation.selectedChannelSource.isEmpty else { return [] }
        return model.channels.channelEntries(for: model.navigation.selectedChannelSource).filter {
            $0.matches(model.navigation.query)
        }
    }

    private var allChannelEntries: [LibraryEntry] {
        var seen = Set<String>()
        return channels
            .flatMap { model.channels.channelEntries(for: $0.source) }
            .filter { seen.insert($0.id).inserted && $0.matches(model.navigation.query) }
            .sorted {
                ($0.createdAt ?? $0.updatedAt ?? "") >
                    ($1.createdAt ?? $1.updatedAt ?? "")
            }
    }

    private var voiceBriefEntries: [LibraryEntry] {
        model.session.projection.entries.filter {
            $0.entryType == "voice_brief_episode" &&
                (model.navigation.selectedVoiceBriefID.isEmpty ||
                    $0.voiceBriefID == model.navigation.selectedVoiceBriefID) &&
                $0.matches(model.navigation.query)
        }
        .sorted {
            ($0.createdAt ?? $0.updatedAt ?? "") >
                ($1.createdAt ?? $1.updatedAt ?? "")
        }
    }

    private var count: Int {
        switch model.navigation.activeSection {
        case .items: model.navigation.filteredEntries.count
        case .channels:
            model.navigation.selectedChannelSource.isEmpty ? allChannelEntries.count : channelEntries.count
        case .briefs:
            voiceBriefEntries.count
        }
    }

    private var feedEntries: [LibraryEntry]? {
        switch model.navigation.activeSection {
        case .items:
            model.navigation.filteredEntries
        case .channels:
            model.navigation.selectedChannelSource.isEmpty ? allChannelEntries : channelEntries
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
                        Text("\(model.channels.channelEntries(for: channel.source).count) saved notes")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 12)

                    Button {
                        model.navigation.showChannelSettings(channel.source)
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
                .onTapGesture { model.navigation.selectChannel(channel.source) }
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
                        action: { Task { await model.selection.select(entry.id) } }
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

            if model.navigation.activeSection == .briefs, let brief = model.voiceBriefs.selectedVoiceBrief {
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
        case .briefs:
            briefTabs
        }
    }

    @ViewBuilder
    private var feedHeaderAction: some View {
        switch model.navigation.activeSection {
        case .items:
            EmptyView()
        case .channels:
            if let channel = model.channels.selectedChannel {
                Button {
                    model.navigation.showChannelSettings(channel.source)
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
                    model.navigation.showChannelSettings("new")
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
            if let brief = model.voiceBriefs.selectedVoiceBrief {
                Button {
                    model.navigation.showVoiceBriefSettings(brief.id)
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
                    model.navigation.query = ""
                    model.navigation.showVoiceBriefSettings("new")
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
                selectionTab("All", selected: model.navigation.selectedChannelSource.isEmpty) {
                    model.navigation.selectChannel("")
                }
                ForEach(Array(channels.prefix(7))) { channel in
                    selectionTab(
                        compactLabel(channel.title),
                        selected: model.navigation.selectedChannelSource == channel.source
                    ) {
                        model.navigation.selectChannel(channel.source)
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
                selectionTab("All", selected: model.navigation.selectedVoiceBriefID.isEmpty) {
                    model.navigation.selectVoiceBrief("")
                }
                ForEach(Array(model.session.projection.voiceBriefDefinitions.prefix(7)), id: \.id) { brief in
                    selectionTab(
                        brief.title,
                        selected: model.navigation.selectedVoiceBriefID == brief.id
                    ) {
                        model.navigation.selectVoiceBrief(brief.id)
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
            Task { await model.navigation.showTopic(topic) }
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
                TextField("Search your library", text: $model.navigation.query)
                    .textFieldStyle(.plain)
            }
            .padding(.horizontal, 14)
            .frame(height: 44)
            .background(.regularMaterial)
            .clipShape(Capsule())
            .overlay { Capsule().stroke(Color.primary.opacity(0.10)) }

            FeedRailCard(title: "Collections") {
                ForEach(Array(model.session.projection.documentTopics.prefix(6)), id: \.self) { topic in
                    Button {
                        Task { await model.navigation.showTopic(topic) }
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
        switch model.navigation.activeSection {
        case .items:
            model.navigation.showingTrash ? "Trash" : model.navigation.selectedTopic == "All" ? "For you" : model.navigation.selectedTopic
        case .channels:
            model.channels.selectedChannel?.title ?? "Channel"
        case .briefs:
            model.voiceBriefs.selectedVoiceBrief?.title ?? "Briefs"
        }
    }

    @ViewBuilder
    private var desktopActions: some View {
        if model.navigation.activeSection == .channels,
            let channel = model.channels.selectedChannel
        {
            HStack {
                Spacer()
                Button {
                    Task { await model.channels.checkSelectedChannel() }
                } label: {
                    if model.channels.isCheckingChannel {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Fetch fresh", systemImage: "arrow.clockwise")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.channels.isCheckingChannel)

                Button {
                    model.navigation.showChannelSettings(channel.source)
                } label: {
                    Image(systemName: "gearshape")
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("Settings for \(channel.title)")
                .help("Settings for \(channel.title)")
            }
        } else if model.navigation.activeSection == .briefs,
            let brief = model.voiceBriefs.selectedVoiceBrief
        {
            HStack {
                Spacer()
                Button {
                    model.navigation.showVoiceBriefSettings(brief.id)
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
            action: { Task { await model.selection.select(entry.id) } }
        )
        if model.navigation.showingTrash {
            card
        } else {
            card.modifier(EntryContextMenu(model: model, entry: entry))
        }
    }

    private func channelCard(_ channel: LibraryChannel) -> some View {
        BrowserCard(
            action: { model.navigation.selectChannel(channel.source) },
            settingsAction: { model.navigation.showChannelSettings(channel.source) },
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
                "\(model.channels.channelEntries(for: channel.source).count) notes",
                systemImage: "doc.text"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var emptyTitle: String {
        if !model.navigation.query.isEmpty { return "No matches" }
        return switch model.navigation.activeSection {
        case .items: model.navigation.showingTrash ? "Trash is empty" : "No notes yet"
        case .channels:
            model.navigation.selectedChannelSource.isEmpty ? "No channels yet" : "No notes yet"
        case .briefs:
            "No briefs yet"
        }
    }

    private var emptyIcon: String {
        switch model.navigation.activeSection {
        case .items: model.navigation.showingTrash ? "trash" : "doc.text"
        case .channels: "dot.radiowaves.left.and.right"
        case .briefs: "headphones"
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
                : "New notes from this channel appear here."
        case .briefs:
            model.session.projection.voiceBriefDefinitions.isEmpty
                ? "Create a voice brief from your channels."
                : "Generated briefs appear here."
        }
    }
}

#endif
