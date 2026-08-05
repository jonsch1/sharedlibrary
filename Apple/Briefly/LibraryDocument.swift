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

struct LibraryDetail: View {
    @Bindable var model: LibraryModel
    @Binding var showsChannelBrowser: Bool
    @Bindable var audioPlayer: NativeAudioPlayer
    @Binding var audioEntry: LibraryEntry?

    var body: some View {
        Group {
            #if os(macOS)
            if model.showingHighlights {
                HighlightsDocument(model: model)
            } else if let entry = model.selectedEntry {
                LibraryDocument(
                    model: model,
                    entry: entry,
                    audioPlayer: audioPlayer,
                    audioEntry: $audioEntry
                )
            } else if model.activeSection == .briefs &&
                model.showingVoiceBriefSettings
            {
                VoiceBriefConfiguration(model: model)
            } else if model.activeSection == .channels &&
                model.showingChannelSettings
            {
                ChannelConfiguration(
                    model: model,
                    showsChannelBrowser: $showsChannelBrowser
                )
            } else {
                LibraryCardBrowser(model: model)
            }
            #else
            if model.showingHighlights {
                HighlightsDocument(model: model)
            } else if let entry = model.selectedEntry {
                LibraryDocument(
                    model: model,
                    entry: entry,
                    audioPlayer: audioPlayer,
                    audioEntry: $audioEntry
                )
            } else if model.activeSection == .briefs {
                VoiceBriefConfiguration(model: model)
            } else if model.activeSection == .channels {
                ChannelConfiguration(
                    model: model,
                    showsChannelBrowser: $showsChannelBrowser
                )
            } else if model.activeSection == .items && model.filteredEntries.isEmpty {
                ContentUnavailableView(
                    model.query.isEmpty
                        ? model.selectedTopic == "All"
                            ? "No documents yet"
                            : "No documents in \(model.selectedTopic)"
                        : "No matching documents",
                    systemImage: model.query.isEmpty
                        ? "doc.text"
                        : "doc.text.magnifyingglass",
                    description: Text(
                        model.query.isEmpty
                            ? model.selectedTopic == "All"
                                ? "Add a document to start your library."
                                : "Choose another topic or add a document."
                            : "Try another search."
                    )
                )
            } else {
                ContentUnavailableView(
                    "No document selected",
                    systemImage: "doc.text",
                    description: Text("Choose a document from the library.")
                )
            }
            #endif
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        #if os(macOS)
        .background {
            ZStack {
                readerBackground.opacity(0.08)
                Rectangle()
                    .fill(.ultraThinMaterial)
                    .opacity(0.08)
            }
        }
        #else
        .background(readerBackground.ignoresSafeArea())
        #endif
    }

}

#if os(macOS)
private struct MasonryLayout: Layout {
    let minimumColumnWidth: CGFloat
    let maximumColumnWidth: CGFloat
    let spacing: CGFloat

    struct Cache {
        var frames = [CGRect]()
        var size = CGSize.zero
    }

    func makeCache(subviews: Subviews) -> Cache {
        Cache()
    }

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Cache
    ) -> CGSize {
        guard !subviews.isEmpty else {
            cache = Cache()
            return .zero
        }

        let availableWidth = max(
            1,
            proposal.width ?? maximumColumnWidth
        )
        let columnCount = max(
            1,
            Int(
                floor(
                    (availableWidth + spacing) /
                        (minimumColumnWidth + spacing)
                )
            )
        )
        let columnWidth = min(
            maximumColumnWidth,
            (availableWidth - CGFloat(columnCount - 1) * spacing) /
                CGFloat(columnCount)
        )
        var columnHeights = Array(repeating: CGFloat.zero, count: columnCount)
        var frames = Array(repeating: CGRect.zero, count: subviews.count)

        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(
                ProposedViewSize(width: columnWidth, height: nil)
            )
            let column = columnHeights.enumerated().min {
                if $0.element == $1.element {
                    return $0.offset < $1.offset
                }
                return $0.element < $1.element
            }?.offset ?? 0
            let origin = CGPoint(
                x: CGFloat(column) * (columnWidth + spacing),
                y: columnHeights[column]
            )
            frames[index] = CGRect(
                origin: origin,
                size: CGSize(width: columnWidth, height: size.height)
            )
            columnHeights[column] = origin.y + size.height + spacing
        }

        let height = max(0, (columnHeights.max() ?? 0) - spacing)
        cache.frames = frames
        cache.size = CGSize(width: availableWidth, height: height)
        return cache.size
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Cache
    ) {
        if cache.frames.count != subviews.count ||
            abs(cache.size.width - bounds.width) > 0.5
        {
            _ = sizeThatFits(
                proposal: ProposedViewSize(width: bounds.width, height: bounds.height),
                subviews: subviews,
                cache: &cache
            )
        }

        for index in subviews.indices {
            let frame = cache.frames[index]
            subviews[index].place(
                at: CGPoint(
                    x: bounds.minX + frame.minX,
                    y: bounds.minY + frame.minY
                ),
                anchor: .topLeading,
                proposal: ProposedViewSize(
                    width: frame.width,
                    height: nil
                )
            )
        }
    }
}

private struct BalancedTilingLayout: Layout {
    let minimumTileWidth: CGFloat
    let maximumColumns: Int
    let spacing: CGFloat
    let featuredCount: Int

    struct Cache {
        var frames = [CGRect]()
        var size = CGSize.zero
    }

    func makeCache(subviews: Subviews) -> Cache {
        Cache()
    }

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Cache
    ) -> CGSize {
        guard !subviews.isEmpty else {
            cache = Cache()
            return .zero
        }

        let availableWidth = max(1, proposal.width ?? minimumTileWidth)
        let rows = rowCounts(itemCount: subviews.count, width: availableWidth)
        var frames = Array(repeating: CGRect.zero, count: subviews.count)
        var itemIndex = 0
        var y = CGFloat.zero

        for (rowIndex, itemCount) in rows.enumerated() {
            let availableForTiles = availableWidth - CGFloat(itemCount - 1) * spacing
            let weights = rowWeights(count: itemCount, rowIndex: rowIndex)
            let totalWeight = weights.reduce(0, +)
            let widths = weights.map { availableForTiles * $0 / totalWeight }
            var measuredHeights = [CGFloat]()

            for offset in 0..<itemCount {
                let size = subviews[itemIndex + offset].sizeThatFits(
                    ProposedViewSize(width: widths[offset], height: nil)
                )
                measuredHeights.append(size.height)
            }

            let isFeaturedRow = rowIndex == 0 && featuredCount > 0 &&
                subviews.count >= 6
            let rowHeight = max(
                isFeaturedRow ? 262 : 164,
                measuredHeights.max() ?? 0
            )
            var x = CGFloat.zero

            for offset in 0..<itemCount {
                frames[itemIndex + offset] = CGRect(
                    x: x,
                    y: y,
                    width: widths[offset],
                    height: rowHeight
                )
                x += widths[offset] + spacing
            }

            itemIndex += itemCount
            y += rowHeight + spacing
        }

        cache.frames = frames
        cache.size = CGSize(width: availableWidth, height: max(0, y - spacing))
        return cache.size
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Cache
    ) {
        if cache.frames.count != subviews.count ||
            abs(cache.size.width - bounds.width) > 0.5
        {
            _ = sizeThatFits(
                proposal: ProposedViewSize(width: bounds.width, height: nil),
                subviews: subviews,
                cache: &cache
            )
        }

        for index in subviews.indices {
            let frame = cache.frames[index]
            subviews[index].place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: frame.width, height: frame.height)
            )
        }
    }

    private func rowCounts(itemCount: Int, width: CGFloat) -> [Int] {
        let preferred = max(
            2,
            min(
                maximumColumns,
                Int((width + spacing) / (minimumTileWidth + spacing))
            )
        )
        var remaining = itemCount
        var rows = [Int]()

        if featuredCount > 0 && itemCount >= 6 {
            let count = min(featuredCount, remaining)
            rows.append(count)
            remaining -= count
        }

        while remaining > 0 {
            if remaining <= preferred {
                rows.append(remaining)
                break
            }
            if remaining < preferred * 2 {
                let leading = Int(ceil(Double(remaining) / 2.0))
                rows.append(leading)
                rows.append(remaining - leading)
                break
            }
            rows.append(preferred)
            remaining -= preferred
        }
        return rows
    }

    private func rowWeights(count: Int, rowIndex: Int) -> [CGFloat] {
        let weights: [CGFloat] = switch count {
        case 2: [1.08, 0.92]
        case 3: rowIndex == 0 && featuredCount > 0
            ? [1.24, 1.0, 0.86]
            : [1.08, 0.92, 1.0]
        case 4: [1.08, 0.92, 1.04, 0.96]
        case 5: [1.06, 0.94, 1.02, 0.90, 1.08]
        case 6: [1.05, 0.95, 1.0, 1.04, 0.92, 1.04]
        default: Array(repeating: 1, count: count)
        }
        return rowIndex.isMultiple(of: 2) ? weights : Array(weights.reversed())
    }
}

private struct LibraryCardBrowser: View {
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

struct FeedEntryRow: View {
    let entry: LibraryEntry
    let action: () -> Void

    private var sourceURL: URL? {
        entry.sourceURL.flatMap(URL.init(string:))
    }

    private var sourceName: String {
        if let sharedBy = entry.sharedByDisplayName, !sharedBy.isEmpty {
            return sharedBy
        }
        if let host = sourceURL?.host {
            return host.replacingOccurrences(of: "www.", with: "")
        }
        return entry.entryType == "voice_brief_episode" ? "Voice Brief" : "Briefly"
    }

    private var relativeDate: String? {
        guard
            let rawDate = entry.createdAt ?? entry.updatedAt,
            let date = try? Date(rawDate, strategy: .iso8601)
        else { return nil }
        return date.formatted(.relative(presentation: .named, unitsStyle: .abbreviated))
    }

    private var displayExcerpt: String {
        let excerpt = entry.excerpt.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = entry.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty,
            excerpt.lowercased().hasPrefix(title.lowercased())
        else { return excerpt }
        return String(excerpt.dropFirst(title.count))
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Text(sourceName)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                if let username = entry.sharedByUsername, !username.isEmpty {
                    Text("@\(username)")
                        .lineLimit(1)
                }
                if let relativeDate {
                    Text("·")
                    Text(relativeDate)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
            }
            .padding(.trailing, sourceURL == nil ? 0 : 40)
            .font(.callout)
            .foregroundStyle(.secondary)

            Text(entry.title)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            if !displayExcerpt.isEmpty {
                Text(displayExcerpt)
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .lineSpacing(2)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }

        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("library.entry.\(entry.id)")
        .overlay(alignment: .topTrailing) {
            if let sourceURL {
                Link(destination: sourceURL) {
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 14, weight: .medium))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Open original")
                .padding(.trailing, 6)
                .padding(.top, 2)
            }
        }
        .overlay(alignment: .bottom) {
            Divider()
        }
    }
}

#if os(macOS)
struct FeedRailCard<Content: View>: View {
    let title: String
    let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial.opacity(0.72))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.primary.opacity(0.10))
        }
    }
}

private struct BrowserCard<Content: View>: View {
    let palette: GrainyGradientPalette
    let variationKey: String
    let action: () -> Void
    let settingsAction: (() -> Void)?
    let settingsLabel: String
    let content: Content

    init(
        action: @escaping () -> Void,
        settingsAction: (() -> Void)? = nil,
        settingsLabel: String = "Settings",
        palette: GrainyGradientPalette = .item,
        variationKey: String = "",
        @ViewBuilder content: () -> Content
    ) {
        self.palette = palette
        self.variationKey = variationKey
        self.action = action
        self.settingsAction = settingsAction
        self.settingsLabel = settingsLabel
        self.content = content()
    }

    var body: some View {
        GrainyCard(palette: palette, variationKey: variationKey) {
            ZStack(alignment: .topTrailing) {
                Button(action: action) {
                    VStack(alignment: .leading, spacing: 10) {
                        content
                    }
                    .padding(.leading, 18)
                    .padding(.vertical, 18)
                    .padding(.trailing, settingsAction == nil ? 18 : 50)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                }
                .buttonStyle(.plain)

                if let settingsAction {
                    Button(action: settingsAction) {
                        Image(systemName: "gearshape")
                            .frame(width: 44, height: 44)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .macLiquidGlass(in: Circle(), interactive: true)
                    .padding(10)
                    .foregroundStyle(.primary)
                    .accessibilityLabel(settingsLabel)
                    .help(settingsLabel)
                }
            }
        }
    }
}

private struct CardEyebrow: View {
    let icon: String
    let title: String
    var date: String? = nil

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
            Text(title.uppercased())
                .lineLimit(1)
            Spacer(minLength: 6)
            if let date, let value = try? Date(date, strategy: .iso8601) {
                Text(
                    value.formatted(
                        .relative(presentation: .named, unitsStyle: .abbreviated)
                    )
                )
                .foregroundStyle(.tertiary)
            }
        }
        .font(.system(size: 10, weight: .bold))
        .tracking(0.4)
        .foregroundStyle(.secondary)
    }
}
#endif

struct XEmptyState: View {
    let icon: String
    let title: String
    let message: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.title2.weight(.bold))
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: 360, alignment: .leading)
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }
}

struct XLoadingState: View {
    let title: String
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ProgressView()
                .controlSize(.small)
            Text(title)
                .font(.headline)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: 360, alignment: .leading)
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }
}

private struct HighlightsDocument: View {
    @Bindable var model: LibraryModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Highlights")
                        .font(.title2.weight(.bold))
                    Text("Passages saved from your library")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(18)
            .background(.regularMaterial)

            Divider()

            GeometryReader { geometry in
                if model.highlightsText.isEmpty {
                    XEmptyState(
                        icon: "highlighter",
                        title: "No highlights yet",
                        message: "Select a passage in any document, then choose Highlight."
                    )
                } else {
                    ScrollView {
                        MarkdownArticle(model.highlightsText)
                            .frame(maxWidth: 620, alignment: .leading)
                            .padding(.horizontal, 28)
                            .padding(.top, 34)
                            .padding(.bottom, 80)
                            .frame(maxWidth: .infinity)
                            .frame(minHeight: geometry.size.height, alignment: .top)
                    }
                }
            }
        }
        .frame(maxWidth: 680)
        .frame(maxWidth: .infinity, alignment: .top)
        .background(.ultraThinMaterial.opacity(0.64))
        .overlay { Rectangle().stroke(Color.primary.opacity(0.10)) }
    }
}

struct BriefPreparationPanel: View {
    @Bindable var model: LibraryModel
    let brief: LibraryVoiceBrief

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.isRunningVoiceBrief,
               let progress = model.voiceBriefGenerationProgress,
               progress.voiceBriefID == brief.id {
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text("Preparing your brief")
                            .font(.callout.weight(.semibold))
                        Spacer()
                        if progress.phase == .summarizing, progress.retrievedItemCount > 0 {
                            Text(
                                "\(progress.summarizedItemCount + progress.failedItemCount)" +
                                    "/\(progress.retrievedItemCount)"
                            )
                            .font(.caption.monospacedDigit().weight(.medium))
                            .foregroundStyle(.secondary)
                        }
                    }
                    Text(brief.title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                VStack(alignment: .leading, spacing: 0) {
                    preparationStep(
                        title: "Gathering channel items",
                        detail: retrievalDetail(progress),
                        state: progress.phase == .retrieving ? .active : .complete
                    )
                    Divider().padding(.leading, 32)
                    preparationStep(
                        title: "Preparing summaries",
                        detail: summaryDetail(progress),
                        state: summaryState(progress)
                    )
                    Divider().padding(.leading, 32)
                    preparationStep(
                        title: "Writing your brief",
                        detail: "Creating short and detailed versions",
                        state: progress.phase == .assembling ? .active : .waiting
                    )
                }
                .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Prepare a new brief")
                        .font(.callout.weight(.semibold))
                    Text("Fetch the channels and assemble short and detailed versions.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Button {
                    Task { await model.runSelectedVoiceBrief() }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "sparkles")
                        Text("Prepare new brief")
                            .font(.callout.weight(.semibold))
                    }
                    .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.white)
                .background(Color.blue, in: Capsule())
                .disabled(model.isRunningVoiceBrief || brief.sources.isEmpty)
            }
        }
        .padding(14)
        .background(
            model.isRunningVoiceBrief
                ? Color.accentColor.opacity(0.10)
                : Color.primary.opacity(0.045),
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(
                    model.isRunningVoiceBrief
                        ? Color.accentColor.opacity(0.28)
                        : Color.primary.opacity(0.08)
                )
        }
        .animation(.smooth(duration: 0.35), value: model.isRunningVoiceBrief)
        .animation(.smooth(duration: 0.25), value: model.status)
    }

    private enum StepState {
        case waiting
        case active
        case complete
    }

    private func summaryState(_ progress: VoiceBriefGenerationProgress) -> StepState {
        switch progress.phase {
        case .retrieving: .waiting
        case .summarizing: .active
        case .assembling: .complete
        }
    }

    private func retrievalDetail(_ progress: VoiceBriefGenerationProgress) -> String {
        let channelLabel = progress.totalChannelCount == 1 ? "channel" : "channels"
        let itemLabel = progress.retrievedItemCount == 1 ? "item" : "items"
        if progress.phase == .retrieving {
            return "Checked \(progress.checkedChannelCount) of \(progress.totalChannelCount) " +
                "\(channelLabel) · \(progress.retrievedItemCount) new \(itemLabel)"
        }
        return "Retrieved \(progress.retrievedItemCount) new \(itemLabel) from " +
            "\(progress.totalChannelCount) \(channelLabel)"
    }

    private func summaryDetail(_ progress: VoiceBriefGenerationProgress) -> String {
        guard progress.phase != .retrieving else { return "Waiting for new items" }
        guard progress.retrievedItemCount > 0 else { return "No new items to summarize" }
        if progress.failedItemCount > 0 {
            return "\(progress.summarizedItemCount) summarized · " +
                "\(progress.failedItemCount) unavailable"
        }
        return "\(progress.summarizedItemCount) of \(progress.retrievedItemCount) summarized"
    }

    @ViewBuilder
    private func preparationStep(
        title: String,
        detail: String,
        state: StepState
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Group {
                switch state {
                case .waiting:
                    Circle()
                        .stroke(Color.secondary.opacity(0.35), lineWidth: 1.5)
                        .frame(width: 16, height: 16)
                case .active:
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 16, height: 16)
                case .complete:
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.system(size: 16))
                }
            }
            .frame(width: 16, height: 18)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.caption.weight(state == .active ? .semibold : .medium))
                    .foregroundStyle(state == .waiting ? .secondary : .primary)
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
    }
}

struct ReadingDepthIcon: View {
    let variant: LibraryVariant

    private var lineWidths: [CGFloat] {
        switch variant {
        case .concise: [18, 12]
        case .detailed: [18, 18, 12]
        case .source: []
        }
    }

    var body: some View {
        if variant == .source {
            Image(systemName: "doc.text")
                .font(.system(size: 17, weight: .medium))
        } else {
            VStack(alignment: .leading, spacing: 2.5) {
                ForEach(Array(lineWidths.enumerated()), id: \.offset) { _, width in
                    Capsule()
                        .frame(width: width, height: 2)
                }
            }
            .frame(width: 18, height: 21, alignment: .center)
        }
    }
}
private struct LibraryDocument: View {
    @Bindable var model: LibraryModel
    let entry: LibraryEntry
    @Bindable var audioPlayer: NativeAudioPlayer
    @Binding var audioEntry: LibraryEntry?
    @State private var isEditing = false
    @State private var showsSharing = false

    var body: some View {
        VStack(spacing: 0) {
            #if os(macOS)
            HStack(spacing: 12) {
                Button {
                    Task { await model.select("") }
                } label: {
                    Image(systemName: "arrow.left")
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .contentShape(Circle())

                Spacer()
                Menu {
                    Button("Regenerate summaries", systemImage: "arrow.clockwise") {
                        Task { await model.processSelected() }
                    }
                    .disabled(model.isProcessing)
                    Button("Move to Trash", systemImage: "trash", role: .destructive) {
                        Task { await model.trashSelected() }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
            .padding(.horizontal, 14)
            .frame(height: 56)
            .background(.regularMaterial)
            Divider()
            #endif

            ZStack(alignment: .bottom) {
            if model.isLoadingText {
                XLoadingState(
                    title: "Loading post",
                    message: "Fetching the saved document and its reading variants."
                )
            } else if model.selectedText.isEmpty && !model.canEdit {
                XEmptyState(
                    icon: "icloud.slash",
                    title: "Document unavailable",
                    message: "Sync the library to download this document."
                )
            } else {
                DocumentEditor(
                    model: model,
                    entryID: entry.id,
                    variant: model.selectedVariant,
                    sourceText: model.selectedText,
                    highlightedPassages: highlightedPassages(
                        in: model.highlightsText
                    ),
                    isEditing: isEditing
                )
                .accessibilityIdentifier("reader.editor")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .id("\(entry.id):\(model.selectedVariant.rawValue)")
            }

            HStack(alignment: .bottom, spacing: 0) {
                if entry.texts.count > 1 {
                    HStack(spacing: 0) {
                        ForEach(entry.texts.map(\.variant), id: \.self) { variant in
                            Button {
                                Task { await model.selectVariant(variant) }
                            } label: {
                                ReadingDepthIcon(variant: variant)
                                    .frame(width: 44, height: 44)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(
                                model.selectedVariant == variant
                                    ? Color.accentColor
                                    : Color.primary
                            )
                            .background(
                                model.selectedVariant == variant
                                    ? Color.accentColor.opacity(0.12)
                                    : Color.clear
                            )
                            .accessibilityLabel(
                                variant == .source ? "Original" : variant.title
                            )
                            .accessibilityIdentifier("reader.depth.\(variant.rawValue)")
                            .accessibilityAddTraits(
                                model.selectedVariant == variant ? .isSelected : []
                            )
                            .help(variant == .source ? "Original" : variant.title)
                        }
                    }
                    #if os(iOS)
                    .padding(4)
                    .mobileGlass(in: Capsule())
                    #endif
                }

                #if os(iOS)
                Spacer()
                #else
                Spacer(minLength: 12)
                #endif

                HStack(spacing: 0) {
                    #if os(macOS)
                    if model.canEdit && !model.showingTrash {
                        Button {
                            isEditing.toggle()
                        } label: {
                            Image(systemName: isEditing ? "checkmark" : "pencil")
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(isEditing ? Color.accentColor : Color.primary)
                        .background(
                            isEditing ? Color.accentColor.opacity(0.12) : Color.clear
                        )
                        .accessibilityLabel(
                            isEditing ? "Finish editing" : "Edit document"
                        )
                        .help(isEditing ? "Finish editing" : "Edit document")

                    }
                    #endif

                    if !usesMobileVoiceBriefControls && !usesMobileItemControls {
                        Button {
                            Task {
                                let variant = model.selectedVariant
                                let text = model.selectedText
                                let playbackID = model.audioPlaybackID(
                                    for: entry,
                                    variant: variant,
                                    text: text
                                )
                                do {
                                    let shouldGenerate = try audioPlayer.startStream(
                                        entryID: entry.id,
                                        title: entry.title,
                                        playbackID: playbackID,
                                        positionID: "\(entry.id):\(variant.rawValue)"
                                    )
                                    if shouldGenerate {
                                        var startedPlayback = false
                                        _ = await model.streamPlayableAudio(
                                            for: entry,
                                            variant: variant,
                                            text: text
                                        ) { url in
                                            try audioPlayer.appendSegment(
                                                url,
                                                playbackID: playbackID
                                            )
                                            if !startedPlayback {
                                                startedPlayback = true
                                                audioEntry = entry
                                            }
                                        }
                                        audioPlayer.finishStream(playbackID: playbackID)
                                        if !startedPlayback { audioPlayer.stop() }
                                    } else {
                                        audioEntry = entry
                                    }
                                } catch {
                                    model.errorMessage = error.localizedDescription
                                    audioPlayer.stop()
                                }
                            }
                        } label: {
                            if model.isGeneratingSpeech {
                                ProgressView()
                                    .tint(.white)
                                    .frame(width: 44, height: 44)
                                    .background(Color.accentColor, in: Circle())
                            } else {
                                Image(systemName: "play.fill")
                                    .font(.system(size: 17, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .frame(width: 44, height: 44)
                                    .background(Color.accentColor, in: Circle())
                                    .contentShape(Circle())
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Play audio")
                        .help("Play audio")
                        .disabled(
                            model.isGeneratingSpeech || model.isRunningVoiceBrief ||
                                model.selectedText.isEmpty
                        )
                    }

                    if !usesMobileVoiceBriefControls && !usesMobileItemControls,
                       let source = entry.sourceURL, let url = URL(string: source) {
                        Link(destination: url) {
                            Image(systemName: "arrow.up.right")
                                .frame(width: 44, height: 44)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Open original source")
                    }

                    if !model.showingTrash &&
                        entry.origin != .shared &&
                        !usesMobileVoiceBriefControls &&
                        !usesMobileItemControls
                    {
                        Button {
                            showsSharing = true
                        } label: {
                            Image(systemName: "square.and.arrow.up")
                                .frame(width: 44, height: 44)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Share document")
                    }
                }
                #if os(iOS)
                .background(readerBackground)
                .clipShape(
                    .rect(
                        topLeadingRadius: 14,
                        bottomLeadingRadius: 0,
                        bottomTrailingRadius: 0,
                        topTrailingRadius: 0
                    )
                )
                .overlay(alignment: .top) {
                    Rectangle()
                        .fill(.primary.opacity(0.08))
                        .frame(height: 1)
                }
                #endif
            }
            #if os(iOS)
            .padding(.horizontal, 18)
            .padding(.bottom, 8)
            #endif
            #if os(macOS)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity)
            .frame(height: 58)
            .background(.regularMaterial)
            .overlay(alignment: .top) { Divider() }
            .frame(maxWidth: .infinity, alignment: .bottom)
            #endif
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        #if os(macOS)
        .frame(maxWidth: 680)
        .frame(maxWidth: .infinity, alignment: .top)
        .background(.ultraThinMaterial.opacity(0.64))
        .overlay { Rectangle().stroke(Color.primary.opacity(0.10)) }
        #else
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        #endif
        .onChange(of: entry.id) {
            isEditing = false
        }
        .contextMenu {
            if model.canEdit && !model.showingTrash {
                Button("Regenerate summaries") {
                    Task { await model.processSelected() }
                }
                .disabled(model.isProcessing)
                Divider()
                Button("Move to Trash", role: .destructive) {
                    Task { await model.trashSelected() }
                }
            }
        }
        .sheet(isPresented: $showsSharing) {
            ShareDocumentView(model: model, entry: entry)
        }
        #if os(iOS)
        .toolbar {
            if usesMobileVoiceBriefControls || usesMobileItemControls {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        if let source = entry.sourceURL, let url = URL(string: source) {
                            Link(destination: url) {
                                Label("Open original source", systemImage: "arrow.up.right")
                            }
                        }
                        if entry.origin != .shared {
                            Button {
                                showsSharing = true
                            } label: {
                                Label(
                                    usesMobileVoiceBriefControls
                                        ? "Share voice brief"
                                        : "Share document",
                                    systemImage: "square.and.arrow.up"
                                )
                            }
                        }
                        if model.canEdit && !model.showingTrash {
                            Divider()
                            Button("Regenerate summaries", systemImage: "arrow.clockwise") {
                                Task { await model.processSelected() }
                            }
                            .disabled(model.isProcessing)
                            Button("Move to Trash", systemImage: "trash", role: .destructive) {
                                Task { await model.trashSelected() }
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .accessibilityLabel("Document settings")
                }
            }
        }
        #endif
    }

    private var usesMobileVoiceBriefControls: Bool {
        #if os(iOS)
        entry.voiceBriefID != nil
        #else
        false
        #endif
    }

    private var usesMobileItemControls: Bool {
        #if os(iOS)
        entry.voiceBriefID == nil
        #else
        false
        #endif
    }
}

private struct ShareDocumentView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: LibraryModel
    let entry: LibraryEntry
    @State private var link: BrieflyShareLinkStatus?
    @State private var isBusy = false
    @State private var errorMessage = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Text("Share")
                    .font(.headline)
                Spacer()
            }
            .padding(.horizontal, 16)
            .frame(height: 54)
            Divider()

            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 12) {
                    Label("PUBLIC READER", systemImage: "link")
                        .font(.system(size: 10, weight: .bold))
                        .tracking(0.7)
                        .foregroundStyle(.secondary)

                    Text(entry.title)
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                        .lineLimit(3)

                    Text(
                        "Share the summaries and a listenable audio version. Your private captured source stays private."
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.ultraThinMaterial.opacity(0.72))
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color.primary.opacity(0.10))
                }

                if !model.account.authenticated {
                    Label(
                        "Sign in to your Briefly account in Settings before publishing.",
                        systemImage: "person.crop.circle.badge.exclamationmark"
                    )
                } else if let urlString = link?.url, let url = URL(string: urlString) {
                    Text(url.absoluteString)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 10))
                    HStack {
                        Button("Copy link", systemImage: "doc.on.doc") {
                            copyShareURL(url)
                            model.status = "Share link copied"
                        }
                        ShareLink(item: url) {
                            Label("Share…", systemImage: "square.and.arrow.up")
                        }
                        Spacer()
                        Button("Stop sharing", role: .destructive) {
                            Task { await revoke() }
                        }
                    }
                } else if link?.shared == true {
                    Label("Publishing continues in the background.", systemImage: "clock")
                } else {
                    Button {
                        Task { await publish() }
                    } label: {
                        HStack {
                            if isBusy {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Image(systemName: "link.badge.plus")
                            }
                            Text(isBusy ? "Creating link…" : "Create link & copy")
                            Spacer()
                            Image(systemName: "arrow.right")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
                    .disabled(isBusy)

                    Label(
                        "The link is copied as soon as it exists. Publishing finishes in the background.",
                        systemImage: "bolt.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                if !errorMessage.isEmpty {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(.regularMaterial)
        .task { await load() }
        #if os(macOS)
        .frame(minWidth: 540, minHeight: 390)
        #endif
    }

    private func load() async {
        guard model.account.authenticated else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            link = try await model.shareStatus(for: entry)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func publish() async {
        isBusy = true
        errorMessage = ""
        defer { isBusy = false }
        do {
            link = try await model.publishShare(for: entry)
            if let value = link?.url, let url = URL(string: value) {
                copyShareURL(url)
                model.status = "Share link copied. Publishing in the background…"
                dismiss()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func revoke() async {
        guard let token = link?.token else { return }
        isBusy = true
        errorMessage = ""
        defer { isBusy = false }
        do {
            try await model.revokeShare(token)
            link = BrieflyShareLinkStatus(
                shared: false,
                token: nil,
                url: nil,
                status: nil,
                error: nil
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func copyShareURL(_ url: URL) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
        #else
        UIPasteboard.general.url = url
        #endif
    }
}

struct MarkdownArticle: View {
    let lines: [String]

    init(_ text: String) {
        lines = text.replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                MarkdownLine(line: line)
            }
        }
        .textSelection(.enabled)
    }
}

private struct MarkdownLine: View {
    let line: String

    var body: some View {
        if line.isEmpty {
            Color.clear.frame(height: 16)
        } else if line.hasPrefix("# ") {
            markdownText(String(line.dropFirst(2)))
                .font(.system(size: 28, weight: .bold, design: .serif))
                .lineSpacing(4)
                .padding(.bottom, 2)
        } else if line.hasPrefix("## ") {
            markdownText(String(line.dropFirst(3)))
                .font(.system(size: 23, weight: .bold, design: .serif))
                .padding(.top, 8)
        } else if line.hasPrefix("### ") {
            markdownText(String(line.dropFirst(4)))
                .font(.system(size: 19, weight: .bold, design: .serif))
                .padding(.top, 6)
        } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("•")
                markdownText(String(line.dropFirst(2)))
            }
            .articleBodyStyle()
        } else if line.hasPrefix("> ") {
            markdownText(String(line.dropFirst(2)))
                .articleBodyStyle()
                .italic()
                .foregroundStyle(.secondary)
                .padding(.leading, 14)
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(.secondary.opacity(0.35))
                        .frame(width: 3)
                }
        } else {
            markdownText(line)
                .articleBodyStyle()
        }
    }

    private func markdownText(_ value: String) -> Text {
        guard let attributed = try? AttributedString(
            markdown: value,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) else {
            return Text(value)
        }
        return Text(attributed)
    }
}

private extension View {
    func articleBodyStyle() -> some View {
        font(.system(size: 19, weight: .regular, design: .serif))
            .lineSpacing(7)
            .fixedSize(horizontal: false, vertical: true)
    }
}
