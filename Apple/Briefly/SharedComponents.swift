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
private struct MobileGlass<S: Shape>: ViewModifier {
    let shape: S
    let tint: Color?
    let interactive: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            let glass = tint.map { Glass.regular.tint($0) } ?? .regular
            if interactive {
                content.glassEffect(glass.interactive(), in: shape)
            } else {
                content.glassEffect(glass, in: shape)
            }
        } else if let tint {
            content.background(tint, in: shape)
        } else {
            content.background(.regularMaterial, in: shape)
        }
    }
}

extension View {
    func mobileGlass<S: Shape>(
        in shape: S,
        tint: Color? = nil,
        interactive: Bool = true
    ) -> some View {
        modifier(MobileGlass(shape: shape, tint: tint, interactive: interactive))
    }
}
#endif

#if os(macOS)
struct FullScreenToolbarBehavior: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.windowToolbarFullScreenVisibility(.onHover)
        } else {
            content
        }
    }
}

struct WindowControlPositioner: NSViewRepresentable {
    let x: CGFloat
    let y: CGFloat
    @Binding var controlsVisible: Bool

    func makeNSView(context: Context) -> PositioningView {
        PositioningView(x: x, y: y) { visible in
            if controlsVisible != visible {
                controlsVisible = visible
            }
        }
    }

    func updateNSView(_ nsView: PositioningView, context: Context) {
        nsView.onControlsVisible = { visible in
            if controlsVisible != visible {
                controlsVisible = visible
            }
        }
        nsView.positionControls()
    }

    final class PositioningView: NSView {
        let x: CGFloat
        let y: CGFloat
        weak var positionedWindow: NSWindow?
        var onControlsVisible: (Bool) -> Void
        private var originalOrigins = [NSWindow.ButtonType: NSPoint]()
        private var observers = [NSObjectProtocol]()

        init(
            x: CGFloat,
            y: CGFloat,
            onControlsVisible: @escaping (Bool) -> Void
        ) {
            self.x = x
            self.y = y
            self.onControlsVisible = onControlsVisible
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, positionedWindow !== window else { return }
            removeObservers()
            positionedWindow = window
            originalOrigins = [:]
            let center = NotificationCenter.default
            observers = [
                center.addObserver(
                    forName: NSWindow.didEnterFullScreenNotification,
                    object: window,
                    queue: .main
                ) { [weak self] _ in
                    self?.onControlsVisible(false)
                },
                center.addObserver(
                    forName: NSWindow.didExitFullScreenNotification,
                    object: window,
                    queue: .main
                ) { [weak self] _ in
                    guard let self else { return }
                    self.positionControls()
                    self.onControlsVisible(true)
                }
            ]
            DispatchQueue.main.async {
                self.positionControls()
                self.onControlsVisible(!window.styleMask.contains(.fullScreen))
            }
        }

        func positionControls() {
            guard let window, !window.styleMask.contains(.fullScreen) else { return }
            for kind in [
                NSWindow.ButtonType.closeButton,
                .miniaturizeButton,
                .zoomButton
            ] {
                guard let button = window.standardWindowButton(kind) else { continue }
                let origin = originalOrigins[kind] ?? button.frame.origin
                originalOrigins[kind] = origin
                button.setFrameOrigin(NSPoint(x: origin.x + x, y: origin.y + y))
            }
        }

        private func removeObservers() {
            for observer in observers {
                NotificationCenter.default.removeObserver(observer)
            }
            observers = []
        }

        deinit {
            removeObservers()
        }
    }
}

extension View {
    func macLiquidGlass<S: Shape>(
        in shape: S,
        tint: Color? = nil,
        interactive: Bool = false
    ) -> some View {
        modifier(
            MacLiquidGlass(
                shape: shape,
                tint: tint,
                interactive: interactive
            )
        )
    }

    @ViewBuilder
    func actionBarGlass() -> some View {
        macLiquidGlass(in: Capsule(), interactive: true)
    }
}

private struct MacLiquidGlass<S: Shape>: ViewModifier {
    let shape: S
    let tint: Color?
    let interactive: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            let glass = tint.map { Glass.regular.tint($0) } ?? .regular
            if interactive {
                content.glassEffect(glass.interactive(), in: shape)
            } else {
                content.glassEffect(glass, in: shape)
            }
        } else if let tint {
            content.background(tint.opacity(0.22), in: shape)
                .background(.regularMaterial, in: shape)
        } else {
            content.background(.regularMaterial, in: shape)
        }
    }
}
#endif

struct BrieflyAtmosphere: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24.0, paused: reduceMotion)) {
            context in
            GeometryReader { geometry in
                let time = reduceMotion
                    ? 0
                    : context.date.timeIntervalSinceReferenceDate
                        .truncatingRemainder(dividingBy: 240)
                Color.white.colorEffect(
                    ShaderLibrary.organicAtmosphere(
                        .float2(geometry.size),
                        .float(time),
                        .float(colorScheme == .dark ? 1 : 0)
                    )
                )
            }
        }
        .overlay {
            Rectangle().fill(
                colorScheme == .dark
                    ? Color.black.opacity(0.12)
                    : Color.white.opacity(0.08)
            )
        }
    }
}

struct BrieflyLogo: View {
    var body: some View {
        Group {
            #if os(macOS)
            Image("BrieflyWordmark")
                .resizable()
                .renderingMode(.template)
                .scaledToFit()
                .frame(width: 76, height: 30)
            #else
            Image("BrieflyWordmark")
                .resizable()
                .renderingMode(.template)
                .scaledToFit()
                .frame(width: 97, height: 39)
            #endif
        }
        .foregroundStyle(.primary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Briefly")
    }
}

struct SyncActivityView: View {
    @Bindable var model: LibraryModel

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "icloud")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 36, height: 36)
                .background(Color.accentColor.opacity(0.12), in: Circle())

            VStack(alignment: .leading, spacing: 5) {
                Text("Syncing with iCloud")
                    .font(.subheadline.weight(.semibold))

                if model.syncTotal > 0 {
                    HStack {
                        Text("\(model.syncCompleted) of \(model.syncTotal) changes")
                        Spacer(minLength: 16)
                        Text(
                            Double(model.syncCompleted) / Double(model.syncTotal),
                            format: .percent.precision(.fractionLength(0))
                        )
                        .monospacedDigit()
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    ProgressView(
                        value: Double(model.syncCompleted),
                        total: Double(model.syncTotal)
                    )
                    .tint(.accentColor)
                } else {
                    HStack(spacing: 7) {
                        ProgressView()
                            .controlSize(.small)
                        Text(model.status)
                            .lineLimit(1)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            .frame(width: 210, alignment: .leading)
        }
        .padding(14)
        #if os(macOS)
        .macLiquidGlass(
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
        #else
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        #endif
        .shadow(color: .black.opacity(0.13), radius: 16, y: 7)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Syncing with iCloud")
        .accessibilityValue(
            model.syncTotal > 0
                ? "\(model.syncCompleted) of \(model.syncTotal) changes"
                : model.status
        )
    }
}

private struct LibrarySidebar: View {
    @Bindable var model: LibraryModel
    @Binding var showsSettings: Bool
    @Bindable var audioPlayer: NativeAudioPlayer
    @Binding var audioEntry: LibraryEntry?
    var onOpenDetail: () -> Void = {}

    var body: some View {
        VStack(spacing: 0) {
            #if os(macOS)
            Color.clear
            .frame(height: 45)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            #endif

            #if os(macOS)
            HStack {
                BrieflyLogo()
                Spacer()
            }
            .padding(.horizontal, 20)
            .frame(height: 54)
            #endif

            #if os(iOS)
            MobileLibraryRows(model: model, onOpenDetail: onOpenDetail)
            #else
            ScrollView {
                xSidebarNavigation
            }
            .scrollIndicators(.hidden)
            #endif

            #if os(macOS)
            sidebarFooter
                .padding(14)
            #endif
        }
        #if os(macOS)
        .background {
            ZStack {
                sidebarBackground.opacity(0.22)
                Rectangle()
                    .fill(.thinMaterial)
                    .opacity(0.72)
            }
            .ignoresSafeArea()
        }
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(.white.opacity(0.07))
                .frame(width: 1)
                .ignoresSafeArea()
        }
        #else
        .background(sidebarBackground.ignoresSafeArea())
        #endif
    }

    #if os(macOS)
    private var xSidebarNavigation: some View {
        LazyVStack(alignment: .leading, spacing: 4) {
            ForEach(LibrarySection.allCases) { section in
                Button {
                    Task { await model.show(section) }
                } label: {
                    xSidebarRow(
                        icon: section.icon,
                        title: section.title,
                        selected: model.activeSection == section
                    )
                }
                .accessibilityAddTraits(
                    model.activeSection == section ? .isSelected : []
                )
                .help(section.title)
            }

            if model.activeSection == .items {
                Divider()
                    .padding(.vertical, 10)
                    .padding(.horizontal, 8)

                Button(action: model.showInbox) {
                    xSidebarRow(
                        icon: "tray",
                        title: "Inbox",
                        selected: model.selectedTopic == "All" &&
                            !model.showingHighlights && !model.showingTrash
                    )
                }
                Button(action: model.showHighlights) {
                    xSidebarRow(
                        icon: "highlighter",
                        title: "Highlights",
                        selected: model.showingHighlights
                    )
                }
                Button(action: model.showTrash) {
                    xSidebarRow(
                        icon: "trash",
                        title: "Trash",
                        selected: model.showingTrash
                    )
                }
            }

            if model.activeSection != .items {
                Button {
                    model.query = ""
                    if model.activeSection == .channels {
                        model.showChannelSettings("new")
                    } else {
                        model.showVoiceBriefSettings("new")
                    }
                } label: {
                    Label(
                        model.activeSection == .channels ? "New channel" : "New brief",
                        systemImage: "plus"
                    )
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .frame(height: 42)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .padding(.top, 14)
                .padding(.horizontal, 4)
            } else {
                Button {
                    let text = NSPasteboard.general.string(forType: .string) ?? ""
                    Task { await model.capture(text) }
                } label: {
                    Label("Capture", systemImage: "plus")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .frame(height: 42)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .padding(.top, 14)
                .padding(.horizontal, 4)
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 14)
        .padding(.top, 8)
    }

    private var sidebarFooter: some View {
        VStack(spacing: 4) {
            if let playingEntry {
                Button {
                    audioEntry = playingEntry
                } label: {
                    xSidebarRow(icon: "waveform", title: "Now playing", selected: false)
                }
                .symbolEffect(.variableColor.iterative, options: .repeating)
            }

            Button {
                showsSettings = true
            } label: {
                xSidebarRow(icon: "gearshape", title: "Settings", selected: false)
            }
            .help("Settings")
        }
        .buttonStyle(.plain)
    }

    private var playingEntry: LibraryEntry? {
        guard
            audioPlayer.isPlaying,
            let id = audioPlayer.currentEntryID
        else { return nil }
        return model.projection.entries.first { $0.id == id }
    }

    private func xSidebarRow(
        icon: String,
        title: String,
        selected: Bool
    ) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 19, weight: selected ? .semibold : .regular))
                .frame(width: 24)
            Text(title)
                .font(.system(size: 17, weight: selected ? .bold : .medium))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .foregroundStyle(selected ? Color.primary : Color.primary.opacity(0.82))
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, minHeight: 46, alignment: .leading)
        .contentShape(Rectangle())
    }
    #endif
}

#if os(macOS)
private struct SidebarTopic: Identifiable {
    let name: String
    let count: Int
    var id: String { name }
}

private struct MacSidebarFilters: View {
    @Bindable var model: LibraryModel

    private var notes: [LibraryEntry] {
        model.projection.entries.filter(\.isMainLibraryEntry)
    }

    private var topics: [SidebarTopic] {
        model.projection.documentTopics.map { topic in
            SidebarTopic(
                name: topic,
                count: notes.count { $0.topicNames.contains(topic) }
            )
        }
        .sorted {
            $0.count != $1.count
                ? $0.count > $1.count
                : $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    var body: some View {
        LazyVStack(spacing: 2) {
            switch model.activeSection {
            case .items:
                SidebarRow(
                    icon: "tray",
                    title: "Inbox",
                    count: notes.count,
                    selected: model.selectedTopic == "All" &&
                        !model.showingHighlights && !model.showingTrash,
                    action: model.showInbox
                )
                SidebarRow(
                    icon: "highlighter",
                    title: "Highlights",
                    count: model.loadedHighlightCount,
                    selected: model.showingHighlights,
                    action: model.showHighlights
                )
                SidebarRow(
                    icon: "trash",
                    title: "Trash",
                    count: model.loadedTrashCount,
                    selected: model.showingTrash,
                    action: model.showTrash
                )

                if !topics.isEmpty {
                    SidebarSectionHeader("Collections")
                    ForEach(topics) { topic in
                        SidebarRow(
                            icon: "folder",
                            title: topic.name,
                            count: topic.count,
                            selected: model.selectedTopic == topic.name &&
                                !model.showingHighlights && !model.showingTrash
                        ) {
                            Task { await model.showTopic(topic.name) }
                        }
                    }
                }

            case .channels:
                SidebarRow(
                    icon: "dot.radiowaves.left.and.right",
                    title: "All Channels",
                    count: model.channels.count,
                    selected: model.selectedChannelDomain == "All"
                ) {
                    model.showChannelDomain("All")
                }
                if !model.channels.isEmpty {
                    SidebarSectionHeader("Domains")
                    ForEach(channelDomainGroups(model.channels)) { group in
                        SidebarRow(
                            icon: "globe",
                            title: group.domain,
                            count: group.channels.count,
                            selected: model.selectedChannelDomain == group.domain
                        ) {
                            model.showChannelDomain(group.domain)
                        }
                    }
                }

            case .briefs:
                SidebarRow(
                    icon: "headphones",
                    title: "All",
                    count: model.projection.entries.count {
                        $0.entryType == "voice_brief_episode"
                    },
                    selected: model.selectedVoiceBriefID.isEmpty
                ) {
                    model.selectVoiceBrief("")
                }
                if !model.projection.voiceBriefDefinitions.isEmpty {
                    SidebarSectionHeader("Voice Briefs")
                    ForEach(model.projection.voiceBriefDefinitions, id: \.id) { brief in
                        SidebarRow(
                            icon: "headphones",
                            title: brief.title,
                            count: model.projection.episodes(for: brief.id).count,
                            selected: model.selectedVoiceBriefID == brief.id
                        ) {
                            model.selectVoiceBrief(brief.id)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, 4)
        .padding(.bottom, 10)
    }
}

private struct SidebarSectionHeader: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title.uppercased())
            .font(.system(size: 11, weight: .semibold))
            .tracking(0.5)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 11)
            .padding(.top, 18)
            .padding(.bottom, 5)
    }
}
#endif

#if os(iOS)
struct ReadingDepthStrip: View {
    @Bindable var model: LibraryModel
    let entry: LibraryEntry

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(entry.texts.map(\.variant), id: \.self) { variant in
                    Button {
                        Task { await model.selectVariant(variant) }
                    } label: {
                        ReadingDepthIcon(variant: variant)
                            .frame(width: 44, height: 32)
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .background(
                        model.selectedVariant == variant
                            ? Color.accentColor
                            : Color.primary.opacity(0.055)
                    )
                    .foregroundStyle(
                        model.selectedVariant == variant ? Color.white : Color.primary
                    )
                    .clipShape(Capsule())
                    .accessibilityLabel(
                        variant == .source ? "Original" : variant.title
                    )
                    .accessibilityAddTraits(
                        model.selectedVariant == variant ? .isSelected : []
                    )
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .mobileGlass(in: Capsule())
    }
}
#endif

#if os(iOS)
private struct MobileLibraryRows: View {
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

private struct MobileCollectionHeader: View {
    let title: String
    let count: Int
    let back: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: back) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 15, weight: .bold))
                    .frame(width: 44, height: 44)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .mobileGlass(in: Circle())
            .accessibilityLabel("Back to collections")

            Text(title)
                .font(.title3.weight(.bold))
                .lineLimit(1)
            Spacer(minLength: 4)
            Text(count.formatted())
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 4)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }
}

private struct MobileCollectionCard: View {
    let key: String
    var palette: GrainyGradientPalette = .item
    var minimumHeight: CGFloat? = nil
    let icon: String
    let eyebrow: String
    let title: String
    let subtitle: String
    var settingsLabel = "Settings"
    var settingsAction: (() -> Void)?
    let action: () -> Void

    var body: some View {
        GrainyCard(palette: palette, variationKey: key) {
            ZStack(alignment: .topTrailing) {
                Button(action: action) {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(eyebrow, systemImage: icon)
                            .font(.system(size: 10, weight: .bold))
                            .tracking(0.5)
                        Text(title)
                            .font(.title2.weight(.bold))
                            .lineLimit(2)
                        Text(subtitle)
                            .font(.caption.weight(.semibold))
                            .lineLimit(3)
                            .opacity(0.85)
                    }
                    .foregroundStyle(.white)
                    .frame(
                        maxWidth: .infinity,
                        minHeight: minimumHeight ?? 132,
                        alignment: .topLeading
                    )
                    .padding(14)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if let settingsAction {
                    Button(action: settingsAction) {
                        Image(systemName: "gearshape")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.primary)
                            .frame(width: 34, height: 34)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .background(.primary.opacity(0.06), in: Circle())
                    .padding(12)
                    .accessibilityLabel(settingsLabel)
                }
            }
        }
    }
}

#endif

enum GrainyGradientPalette {
    case item
    case channel
    case brief
}

struct GrainyCard<Content: View>: View {
    let content: Content

    init(
        palette: GrainyGradientPalette,
        variationKey: String,
        @ViewBuilder content: () -> Content
    ) {
        self.content = content()
    }

    var body: some View {
        content
            .frame(
                maxWidth: .infinity,
                maxHeight: .infinity,
                alignment: .topLeading
            )
            .background {
                ZStack {
                    Rectangle()
                        .fill(.ultraThinMaterial)
                        .opacity(0.78)
                    Color.primary.opacity(0.018)
                }
            }
            .clipShape(
                RoundedRectangle(
                    cornerRadius: cardCornerRadius,
                    style: .continuous
                )
            )
            .overlay {
                RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous)
                    .stroke(.primary.opacity(0.11))
            }
            #if os(macOS)
            .shadow(color: .black.opacity(0.12), radius: 7, y: 3)
            #else
            .shadow(color: .black.opacity(0.12), radius: 12, y: 5)
            #endif
    }

    private var cardCornerRadius: CGFloat {
        #if os(macOS)
        11
        #else
        20
        #endif
    }
}

struct GrainyEntryCard: View {
    let entry: LibraryEntry
    let paletteOverride: GrainyGradientPalette?
    let selected: Bool
    let minimumHeight: CGFloat?
    let featured: Bool
    let action: () -> Void

    private var palette: GrainyGradientPalette {
        paletteOverride ?? (entry.voiceBriefID == nil ? .item : .brief)
    }

    init(
        entry: LibraryEntry,
        palette: GrainyGradientPalette? = nil,
        selected: Bool = false,
        minimumHeight: CGFloat? = nil,
        featured: Bool = false,
        action: @escaping () -> Void
    ) {
        self.entry = entry
        self.paletteOverride = palette
        self.selected = selected
        self.minimumHeight = minimumHeight
        self.featured = featured
        self.action = action
    }

    private var cardMinimumHeight: CGFloat? {
        if let minimumHeight { return minimumHeight }
        #if os(macOS)
        return nil
        #else
        return 132
        #endif
    }

    private var dateText: String? {
        guard
            let value = entry.createdAt ?? entry.updatedAt,
            let date = try? Date(value, strategy: .iso8601)
        else { return nil }
        return date.formatted(
            .relative(presentation: .named, unitsStyle: .abbreviated)
        )
    }

    var body: some View {
        GrainyCard(palette: palette, variationKey: entry.id) {
            Button(action: action) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .top, spacing: 8) {
                        Text(entry.title)
                            .font(cardTitleFont)
                            .lineLimit(3)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        if let dateText {
                            Text(dateText)
                                .font(.system(size: 10, weight: .medium))
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                                .opacity(0.85)
                        }
                    }

                    if !entry.excerpt.isEmpty {
                        Text(entry.excerpt)
                            .font(.system(size: featured ? 13 : 12, weight: .regular))
                            .lineLimit(featured ? 5 : 4)
                            .multilineTextAlignment(.leading)
                            .opacity(0.85)
                    }
                }
                .foregroundStyle(.primary)
                .frame(
                    maxWidth: .infinity,
                    minHeight: cardMinimumHeight,
                    alignment: .topLeading
                )
                .padding(featured ? 22 : 18)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .overlay {
            RoundedRectangle(cornerRadius: selectionCornerRadius, style: .continuous)
                .stroke(
                    selected ? .white.opacity(0.7) : .clear,
                    lineWidth: selected ? 2 : 0
                )
        }
    }

    private var cardTitleFont: Font {
        #if os(macOS)
        .system(size: featured ? 21 : 16, weight: .semibold)
        #else
        .title2.weight(.bold)
        #endif
    }

    private var selectionCornerRadius: CGFloat {
        #if os(macOS)
        11
        #else
        20
        #endif
    }
}

private struct ChannelDomainGroup: Identifiable {
    let domain: String
    let channels: [LibraryChannel]

    var id: String { domain }
}

private func channelDomainGroups(
    _ channels: [LibraryChannel]
) -> [ChannelDomainGroup] {
    Dictionary(grouping: channels, by: { channelDomain($0.primarySource) })
        .map { domain, channels in
            ChannelDomainGroup(
                domain: domain,
                channels: channels.sorted {
                    $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
                }
            )
        }
        .sorted {
            $0.channels.count != $1.channels.count
                ? $0.channels.count > $1.channels.count
                : $0.domain.localizedCaseInsensitiveCompare($1.domain) == .orderedAscending
        }
}

func channelDomain(_ source: String) -> String {
    let host = URL(string: source)?.host?.lowercased()
        .replacingOccurrences(of: #"^www\."#, with: "", options: .regularExpression) ??
        "other"
    if host == "x.com" || host == "twitter.com" { return "x.com" }
    if host == "youtu.be" || host == "youtube.com" || host.hasSuffix(".youtube.com") {
        return "youtube.com"
    }
    if host == "reddit.com" || host.hasSuffix(".reddit.com") { return "reddit.com" }
    return host
}

private struct SidebarRow: View {
    let icon: String
    let title: String
    var count: Int? = nil
    let selected: Bool
    var inset = false
    var imageURL: URL?
    var showsIcon = true
    var glass = false
    let action: () -> Void

    @ViewBuilder
    var body: some View {
        #if os(iOS)
        if glass {
            row.mobileGlass(
                in: RoundedRectangle(cornerRadius: 18, style: .continuous),
                tint: selected ? Color.accentColor.opacity(0.18) : nil
            )
        } else {
            row
        }
        #else
        if selected {
            row.macLiquidGlass(
                in: RoundedRectangle(cornerRadius: 9, style: .continuous),
                tint: Color(red: 0.43, green: 0.34, blue: 0.21).opacity(0.44),
                interactive: true
            )
        } else {
            row
        }
        #endif
    }

    private var row: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                if showsIcon {
                    if let imageURL {
                        FaviconImage(url: imageURL, fallback: icon)
                    } else {
                        Image(systemName: icon)
                            .font(.system(size: 15))
                            .foregroundStyle(.secondary)
                            .frame(width: 17)
                    }
                }
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: 0)
                if let count {
                    Text(count.formatted())
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .frame(minHeight: 24)
                        .background(Color.primary.opacity(0.055), in: Capsule())
                        .accessibilityLabel("\(count) items")
                }
            }
            .padding(.leading, inset ? 27 : 11)
            .padding(.trailing, 11)
            .frame(minHeight: 37, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .background {
            if !glass {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(rowBackgroundColor)
            }
        }
        .clipShape(
            RoundedRectangle(
                cornerRadius: glass ? 18 : 9,
                style: .continuous
            )
        )
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var rowBackgroundColor: Color {
        #if os(iOS)
        selected
            ? Color(red: 0.38, green: 0.10, blue: 0.72).opacity(0.34)
            : .clear
        #else
        .clear
        #endif
    }
}

struct EntryContextMenu: ViewModifier {
    @Bindable var model: LibraryModel
    let entry: LibraryEntry
    @State private var confirmsTrash = false

    func body(content: Content) -> some View {
        content.contextMenu {
            if let source = entry.sourceURL, let url = URL(string: source) {
                Link(destination: url) {
                    Label("Open original", systemImage: "arrow.up.right")
                }
            }
            if model.canEdit {
                Button {
                    Task {
                        await model.select(entry.id)
                        await model.processSelected()
                    }
                } label: {
                    Label("Regenerate summaries", systemImage: "sparkles")
                }
                .disabled(model.isProcessing)
                Divider()
                Button(role: .destructive) {
                    confirmsTrash = true
                } label: {
                    Label(
                        model.selectionCount(for: entry.id) > 1
                            ? "Move Items to Trash"
                            : "Move to Trash",
                        systemImage: "trash"
                    )
                }
            }
        }
        .confirmationDialog(
            model.selectionCount(for: entry.id) > 1
                ? "Move \(model.selectionCount(for: entry.id)) items to Trash?"
                : "Move this item to Trash?",
            isPresented: $confirmsTrash
        ) {
            Button("Move to Trash", role: .destructive) {
                Task { await model.trash(entryID: entry.id) }
            }
        }
    }
}

private func extendsSidebarSelection() -> Bool {
    #if os(macOS)
    NSEvent.modifierFlags.contains(.command)
    #else
    false
    #endif
}

private struct FaviconImage: View {
    let url: URL
    let fallback: String

    var body: some View {
        #if os(macOS)
        if let image = NSImage(contentsOf: url) {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .frame(width: 16, height: 16)
                .clipShape(RoundedRectangle(cornerRadius: 3))
        } else {
            fallbackImage
        }
        #else
        if let image = UIImage(contentsOfFile: url.path) {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(width: 16, height: 16)
                .clipShape(RoundedRectangle(cornerRadius: 3))
        } else {
            fallbackImage
        }
        #endif
    }

    private var fallbackImage: some View {
        Image(systemName: fallback)
            .font(.system(size: 15))
            .foregroundStyle(.secondary)
            .frame(width: 17)
    }
}

private struct SidebarEmpty: View {
    let icon: String
    let title: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.title3)
            Text(title)
                .font(.callout)
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity)
        .padding(.top, 12)
    }
}
func channelTitle(_ source: String) -> String {
    guard let host = URL(string: source)?.host?.lowercased() else {
        return source
    }
    if host.contains("arxiv.org") { return "ArXiv" }
    if host.contains("ycombinator.com") { return "Hacker News" }
    if host.contains("reddit.com") { return "Reddit" }
    if host == "x.com" || host.hasSuffix(".x.com") || host.contains("twitter.com") {
        return "X"
    }
    return host
        .replacingOccurrences(of: "www.", with: "")
        .split(separator: ".")
        .first
        .map { String($0).capitalized } ?? source
}

func compactLabel(_ value: String, maxLength: Int = 28) -> String {
    guard value.count > maxLength else { return value }
    return String(value.prefix(maxLength - 1)).trimmingCharacters(in: .whitespaces) + "…"
}

private func localFaviconURL(
    for entry: LibraryEntry
) -> URL? {
    guard let favicon = entry.favicon else { return nil }
    let url = URL(fileURLWithPath: favicon.path)
    return FileManager.default.fileExists(atPath: url.path) ? url : nil
}

func audioTime(_ value: Double) -> String {
    guard value.isFinite, value >= 0 else { return "0:00" }
    let seconds = Int(value)
    return "\(seconds / 60):\(String(format: "%02d", seconds % 60))"
}

#if os(macOS)
private func adaptiveColor(
    light: (CGFloat, CGFloat, CGFloat),
    dark: (CGFloat, CGFloat, CGFloat)
) -> Color {
    Color(nsColor: NSColor(name: nil) { appearance in
        let components = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? dark
            : light
        return NSColor(
            srgbRed: components.0,
            green: components.1,
            blue: components.2,
            alpha: 1
        )
    })
}
#else
private func adaptiveColor(
    light: (CGFloat, CGFloat, CGFloat),
    dark: (CGFloat, CGFloat, CGFloat)
) -> Color {
    Color(uiColor: UIColor { traits in
        let components = traits.userInterfaceStyle == .dark ? dark : light
        return UIColor(
            red: components.0,
            green: components.1,
            blue: components.2,
            alpha: 1
        )
    })
}
#endif

private let appBackground = adaptiveColor(
    light: (0.957, 0.953, 0.941),
    dark: (0.018, 0.020, 0.030)
)

let sidebarBackground = adaptiveColor(
    light: (0.975, 0.973, 0.965),
    dark: (0.026, 0.028, 0.043)
)

let readerBackground = adaptiveColor(
    light: (0.986, 0.984, 0.976),
    dark: (0.022, 0.024, 0.038)
)

enum NativeLibraryError: LocalizedError {
    case audioGenerationFailed
    case audioPlaybackFailed
    case emptySpeech
    case iCloudUnavailable
    case unexpectedAIResponse

    var errorDescription: String? {
        switch self {
        case .audioGenerationFailed:
            "The system voice could not create an audio file."
        case .audioPlaybackFailed:
            "Briefly could not start audio playback."
        case .emptySpeech:
            "The voice brief does not contain text to speak."
        case .iCloudUnavailable:
            "Sign in to iCloud and enable iCloud Drive for Briefly."
        case .unexpectedAIResponse:
            "The command ran, but returned an unexpected response."
        }
    }
}
