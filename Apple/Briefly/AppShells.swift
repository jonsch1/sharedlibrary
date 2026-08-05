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
struct MacXLoadingWorkspace: View {
    let status: String

    var body: some View {
        HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 5) {
                Color.clear
                    .frame(height: 42)
                    .accessibilityHidden(true)
                ForEach([
                    ("house", "Home"),
                    ("dot.radiowaves.left.and.right", "Channels"),
                    ("headphones", "Briefs"),
                    ("highlighter", "Highlights"),
                    ("trash", "Trash")
                ], id: \.1) { icon, title in
                    Label(title, systemImage: icon)
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                }
                Spacer()
            }
            .padding(.vertical, 12)
            .frame(width: 220)

            VStack(spacing: 0) {
                HStack {
                    Text("Home").font(.title2.weight(.bold))
                    Spacer()
                }
                .padding(18)
                Divider()
                XLoadingState(
                    title: "Opening your library",
                    message: status
                )
            }
            .frame(width: 680)
            .frame(maxHeight: .infinity)
            .background(.ultraThinMaterial.opacity(0.64))
            .overlay { Rectangle().stroke(Color.primary.opacity(0.10)) }

            VStack(alignment: .leading, spacing: 14) {
                Capsule()
                    .fill(Color.primary.opacity(0.07))
                    .frame(height: 44)
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.primary.opacity(0.045))
                    .frame(height: 230)
            }
            .frame(width: 310)
        }
        .padding(.horizontal, 20)
        .frame(maxWidth: 1_298, maxHeight: .infinity, alignment: .top)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background { BrieflyAtmosphere().ignoresSafeArea() }
        .ignoresSafeArea(.container, edges: .top)
    }
}

struct XErrorBanner: View {
    let message: String
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.red)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text("Something went wrong")
                    .font(.callout.weight(.semibold))
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
            Spacer(minLength: 12)
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .frame(width: 520)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.primary.opacity(0.12))
        }
        .shadow(color: .black.opacity(0.20), radius: 18, y: 8)
    }
}

struct MacCaptureComposer: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: LibraryModel
    let openPDFImporter: () -> Void
    let openBrowser: () -> Void
    @State private var draft = ""
    @FocusState private var focused: Bool

    private var canCapture: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !model.isProcessing
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Text("Capture")
                    .font(.headline)
                Spacer()
                Button("Save") {
                    let value = draft
                    dismiss()
                    Task { await model.capture(value) }
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .disabled(!canCapture)
                .accessibilityIdentifier("capture.save")
            }
            .padding(.horizontal, 16)
            .frame(height: 54)

            Divider()

            HStack(alignment: .top, spacing: 12) {
                Circle()
                    .fill(Color.primary.opacity(0.07))
                    .overlay {
                        Image(systemName: "doc.text")
                            .font(.system(size: 17, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    .frame(width: 42, height: 42)

                TextEditor(text: $draft)
                    .font(.system(size: 18))
                    .scrollContentBackground(.hidden)
                    .focused($focused)
                    .accessibilityIdentifier("capture.text")
                    .overlay(alignment: .topLeading) {
                        if draft.isEmpty {
                            Text("Paste a link or write something…")
                                .font(.system(size: 18))
                                .foregroundStyle(.tertiary)
                                .allowsHitTesting(false)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 8)
                        }
                    }
            }
            .padding(16)
            .frame(minHeight: 190, alignment: .top)

            Divider()

            HStack(spacing: 4) {
                composerTool("doc.richtext", label: "Import PDF", action: openPDFImporter)
                composerTool("globe", label: "Signed-in browser", action: openBrowser)
                composerTool("clipboard", label: "Paste clipboard") {
                    draft = NSPasteboard.general.string(forType: .string) ?? ""
                }
                Spacer()
                if model.isProcessing {
                    ProgressView().controlSize(.small)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 56)
        }
        .frame(width: 600, height: 302)
        .background(.regularMaterial)
        .task {
            if draft.isEmpty {
                draft = NSPasteboard.general.string(forType: .string) ?? ""
            }
            focused = true
        }
    }

    private func composerTool(
        _ icon: String,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }
}

struct MacXNavigation: View {
    @Bindable var model: LibraryModel
    @Binding var showsSettings: Bool
    @Binding var showsCaptureComposer: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                BrieflyLogo()
                Spacer()
            }
            .padding(.horizontal, 12)
            .frame(height: 42)
            .padding(.bottom, 10)

            ForEach(LibrarySection.allCases) { section in
                Button {
                    showsSettings = false
                    Task { await model.show(section) }
                } label: {
                    navigationRow(
                        section.title,
                        icon: section.icon,
                        selected: model.activeSection == section &&
                            !model.showingHighlights && !model.showingTrash
                    )
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("navigation.\(section.rawValue)")
            }

            Button {
                showsSettings = false
                model.showHighlights()
            } label: {
                navigationRow(
                    "Highlights",
                    icon: "highlighter",
                    selected: model.showingHighlights
                )
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("navigation.highlights")

            Button {
                showsSettings = false
                model.showTrash()
            } label: {
                navigationRow("Trash", icon: "trash", selected: model.showingTrash)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("navigation.trash")

            Button {
                switch model.activeSection {
                case .items:
                    showsCaptureComposer = true
                case .channels:
                    model.query = ""
                    model.showChannelSettings("new")
                case .briefs:
                    model.query = ""
                    model.showVoiceBriefSettings("new")
                }
            } label: {
                Label(primaryActionTitle, systemImage: "plus")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .accessibilityIdentifier(
                model.activeSection == .items ? "capture.open" : "navigation.primaryAction"
            )
            .padding(.top, 12)
            .padding(.horizontal, 4)

            Spacer(minLength: 18)

            Button {
                showsSettings = true
            } label: {
                navigationRow("Settings", icon: "gearshape", selected: showsSettings)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Settings")
            .accessibilityIdentifier("settings.open")
        }
        .padding(.vertical, 12)
        .frame(maxHeight: .infinity)
    }

    private var primaryActionTitle: String {
        switch model.activeSection {
        case .items: "Capture"
        case .channels: "New channel"
        case .briefs: "New brief"
        }
    }

    private func navigationRow(
        _ title: String,
        icon: String,
        selected: Bool
    ) -> some View {
        HStack(spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 23, weight: selected ? .semibold : .regular))
                .frame(width: 28)
            Text(title)
                .font(.system(size: 19, weight: selected ? .bold : .medium))
            Spacer()
        }
        .foregroundStyle(selected ? Color.primary : Color.primary.opacity(0.82))
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
        .contentShape(Rectangle())
    }
}

struct MacXRightRail: View {
    @Bindable var model: LibraryModel
    @State private var topicBeingRenamed: String?
    @State private var renamedTopic = ""
    @State private var topicBeingDeleted: String?

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 9) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search your library", text: $model.query)
                    .textFieldStyle(.plain)
                    .accessibilityIdentifier("library.search")
                if !model.query.isEmpty {
                    Button {
                        model.query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 44)
            .background(.regularMaterial, in: Capsule())
            .overlay { Capsule().stroke(Color.primary.opacity(0.10)) }

            if let entry = model.selectedEntry {
                FeedRailCard(title: "About this post") {
                    if let source = entry.sourceURL,
                        let url = URL(string: source)
                    {
                        Link(destination: url) {
                            HStack(spacing: 8) {
                                Image(systemName: "link")
                                    .foregroundStyle(.secondary)
                                Text(url.host ?? source)
                                    .lineLimit(1)
                                Spacer()
                                Image(systemName: "arrow.up.right")
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(.tertiary)
                            }
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .contentShape(Rectangle())
                        }
                        .foregroundStyle(.primary)
                    }
                    ForEach(Array(entry.topicNames.prefix(5)), id: \.self) { topic in
                        Button {
                            Task {
                                await model.select("")
                                await model.showTopic(topic)
                            }
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "number")
                                    .foregroundStyle(.secondary)
                                Text(topic).lineLimit(1)
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(.tertiary)
                            }
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            } else {
                contextualCard
            }

            Spacer()
        }
        .padding(.top, 16)
        .frame(maxHeight: .infinity)
        .alert("Rename collection", isPresented: renamingCollection) {
            TextField("Collection name", text: $renamedTopic)
            Button("Cancel", role: .cancel) {}
            Button("Rename") {
                guard let topicBeingRenamed else { return }
                Task { await model.renameTopic(topicBeingRenamed, to: renamedTopic) }
            }
            .disabled(renamedTopic.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .alert("Delete collection?", isPresented: deletingCollection) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                guard let topicBeingDeleted else { return }
                Task { await model.deleteTopic(topicBeingDeleted) }
            }
        } message: {
            Text("The collection will be removed, but its notes will stay in your library.")
        }
    }

    private var renamingCollection: Binding<Bool> {
        Binding(
            get: { topicBeingRenamed != nil },
            set: { if !$0 { topicBeingRenamed = nil } }
        )
    }

    private var deletingCollection: Binding<Bool> {
        Binding(
            get: { topicBeingDeleted != nil },
            set: { if !$0 { topicBeingDeleted = nil } }
        )
    }

    @ViewBuilder
    private var contextualCard: some View {
        switch model.activeSection {
        case .items:
            FeedRailCard(title: "Collections") {
                ForEach(Array(model.projection.documentTopics.prefix(6)), id: \.self) { topic in
                    collectionRow(topic)
                }
            }
        case .channels:
            FeedRailCard(title: "Main channels") {
                ForEach(Array(model.channels.prefix(6))) { channel in
                    railButton(compactLabel(channel.title), icon: channel.kind == .podcast ? "waveform" : "dot.radiowaves.left.and.right") {
                        model.selectChannel(channel.source)
                    }
                }
            }
        case .briefs:
            FeedRailCard(title: "Main briefs") {
                ForEach(Array(model.projection.voiceBriefDefinitions.prefix(6)), id: \.id) { brief in
                    railButton(brief.title, icon: "headphones") {
                        model.selectVoiceBrief(brief.id)
                    }
                }
            }
        }
    }

    private func collectionRow(_ topic: String) -> some View {
        HStack(spacing: 6) {
            Button {
                Task { await model.showTopic(topic) }
            } label: {
                railRowLabel(topic, icon: "folder")
            }
            .buttonStyle(.plain)

            Menu {
                Button("Rename", systemImage: "pencil") {
                    renamedTopic = topic
                    topicBeingRenamed = topic
                }
                Button("Delete", systemImage: "trash", role: .destructive) {
                    topicBeingDeleted = topic
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .accessibilityLabel("Settings for \(topic)")
            .help("Settings for \(topic)")
        }
    }

    private func railButton(
        _ title: String,
        icon: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            railRowLabel(title, icon: icon, showsDisclosure: true)
        }
        .buttonStyle(.plain)
    }

    private func railRowLabel(
        _ title: String,
        icon: String,
        showsDisclosure: Bool = false
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 17))
                .foregroundStyle(.secondary)
                .frame(width: 22)
            Text(title)
                .font(.system(size: 17, weight: .semibold))
                .lineLimit(1)
            Spacer()
            if showsDisclosure {
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 48)
        .contentShape(Rectangle())
    }
}
#endif

#if os(iOS)
private enum MobilePrimaryTab: String, Hashable {
    case home
    case channels
    case briefs
    case library
}

struct MobileXAppShell: View {
    @Bindable var model: LibraryModel
    @Binding var showsSettings: Bool
    @Binding var showsCaptureComposer: Bool
    @Binding var showsChannelBrowser: Bool
    @Bindable var audioPlayer: NativeAudioPlayer
    @Binding var audioEntry: LibraryEntry?
    @AppStorage("BrieflyMobileTab") private var selectedTab = MobilePrimaryTab.home
    @State private var showsDetail = false

    var body: some View {
        TabView(selection: $selectedTab) {
            mobileStack(.home)
                .tabItem { Label("Home", systemImage: "house") }
                .tag(MobilePrimaryTab.home)

            mobileStack(.channels)
                .tabItem { Label("Channels", systemImage: "dot.radiowaves.left.and.right") }
                .tag(MobilePrimaryTab.channels)

            mobileStack(.briefs)
                .tabItem { Label("Briefs", systemImage: "headphones") }
                .tag(MobilePrimaryTab.briefs)

            NavigationStack {
                MobileXLibraryScreen(
                    model: model,
                    showsSettings: $showsSettings,
                    openEntry: openEntry,
                    create: primaryCreate
                )
                .navigationDestination(isPresented: $showsDetail) {
                    MobileXDetail(
                        model: model,
                        showsChannelBrowser: $showsChannelBrowser,
                        audioPlayer: audioPlayer,
                        audioEntry: $audioEntry
                    )
                }
            }
            .tabItem { Label("Library", systemImage: "bookmark") }
            .tag(MobilePrimaryTab.library)
        }
        .tint(Color.accentColor)
        .overlay(alignment: .bottomTrailing) {
            if let playingEntry {
                Button {
                    audioEntry = playingEntry
                } label: {
                    ZStack {
                        Circle().fill(Color.accentColor)
                        if audioPlayer.isPlaying {
                            Image(systemName: "waveform")
                                .font(.system(size: 22, weight: .semibold))
                                .foregroundStyle(.white)
                                .symbolEffect(.variableColor.iterative, options: .repeating)
                        } else {
                            Image(systemName: "play.fill")
                                .font(.system(size: 20, weight: .semibold))
                                .foregroundStyle(.white)
                        }
                    }
                    .frame(width: 56, height: 56)
                    .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .shadow(color: .black.opacity(0.18), radius: 10, y: 5)
                .padding(.trailing, 18)
                .padding(.bottom, 58)
                .accessibilityLabel("Open audio player")
            } else if isPlayableDetail {
                Button(action: primaryAction) {
                    if model.isGeneratingSpeech {
                        ProgressView()
                            .tint(.white)
                            .frame(width: 56, height: 56)
                            .background(Color.accentColor, in: Circle())
                            .contentShape(Circle())
                    } else {
                        Image(systemName: "play.fill")
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 56, height: 56)
                            .background(Color.accentColor, in: Circle())
                            .contentShape(Circle())
                    }
                }
                .buttonStyle(.plain)
                .shadow(color: .black.opacity(0.18), radius: 10, y: 5)
                .padding(.trailing, 18)
                .padding(.bottom, 58)
                .accessibilityLabel("Play audio")
                .disabled(
                    model.isGeneratingSpeech || model.isRunningVoiceBrief ||
                        model.selectedText.isEmpty
                )
            }
        }
        .onChange(of: selectedTab) {
            showsDetail = false
            model.query = ""
            Task { await activate(selectedTab) }
        }
        .task { await activate(selectedTab) }
    }

    private func mobileStack(_ tab: MobilePrimaryTab) -> some View {
        NavigationStack {
            MobileXFeedScreen(
                model: model,
                tab: tab,
                showsSettings: $showsSettings,
                openEntry: openEntry,
                openConfiguration: {
                    showsDetail = true
                },
                create: primaryCreate
            )
            .navigationDestination(isPresented: $showsDetail) {
                MobileXDetail(
                    model: model,
                    showsChannelBrowser: $showsChannelBrowser,
                    audioPlayer: audioPlayer,
                    audioEntry: $audioEntry
                )
            }
        }
    }

    private func openEntry(_ entry: LibraryEntry) {
        Task {
            if entry.voiceBriefID != nil {
                model.activeSection = .briefs
                model.selectedVoiceBriefID = entry.voiceBriefID ?? ""
            } else if selectedTab == .home {
                model.activeSection = .items
            }
            await model.select(entry.id)
            showsDetail = true
        }
    }

    private func activate(_ tab: MobilePrimaryTab) async {
        switch tab {
        case .home: await model.show(.items)
        case .channels: await model.show(.channels)
        case .briefs: await model.show(.briefs)
        case .library: break
        }
    }

    private var isPlayableDetail: Bool {
        showsDetail && model.selectedEntry != nil
    }

    private var playingEntry: LibraryEntry? {
        guard let id = audioPlayer.currentEntryID else { return nil }
        if isPlayableDetail, let selectedEntry = model.selectedEntry {
            let selectedPlaybackID = model.audioPlaybackID(
                for: selectedEntry,
                variant: model.selectedVariant,
                text: model.selectedText
            )
            guard
                selectedEntry.id == id,
                audioPlayer.isCurrentPlayback(selectedPlaybackID)
            else { return nil }
        }
        return model.projection.entries.first { $0.id == id }
    }

    private func primaryAction() {
        guard isPlayableDetail, let entry = model.selectedEntry else { return }

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
                        try audioPlayer.appendSegment(url, playbackID: playbackID)
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
    }

    private func primaryCreate() {
        switch selectedTab {
        case .home, .library:
            showsCaptureComposer = true
        case .channels:
            model.showChannelSettings("new")
            showsDetail = true
        case .briefs:
            model.showVoiceBriefSettings("new")
            showsDetail = true
        }
    }
}

private struct MobileXFeedScreen: View {
    @Bindable var model: LibraryModel
    let tab: MobilePrimaryTab
    @Binding var showsSettings: Bool
    let openEntry: (LibraryEntry) -> Void
    let openConfiguration: () -> Void
    let create: () -> Void
    @State private var showsSearch = false

    private var entries: [LibraryEntry] {
        let candidates: [LibraryEntry]
        switch tab {
        case .home:
            candidates = model.filteredEntries
        case .channels:
            if model.selectedChannelSource.isEmpty {
                var seen = Set<String>()
                candidates = model.channels.flatMap { model.channelEntries(for: $0.source) }
                    .filter { seen.insert($0.id).inserted }
            } else {
                candidates = model.channelEntries(for: model.selectedChannelSource)
            }
        case .briefs:
            if model.selectedVoiceBriefID.isEmpty {
                candidates = model.projection.voiceBriefDefinitions.flatMap {
                    model.projection.episodes(for: $0.id)
                }
            } else {
                candidates = model.projection.episodes(for: model.selectedVoiceBriefID)
            }
        case .library:
            candidates = []
        }
        return candidates
            .filter { $0.matches(model.query) }
            .sorted {
                ($0.createdAt ?? $0.updatedAt ?? "") >
                    ($1.createdAt ?? $1.updatedAt ?? "")
            }
    }

    var body: some View {
        VStack(spacing: 0) {
            if entries.isEmpty {
                ScrollView {
                    VStack(spacing: 0) {
                        Color.clear
                            .frame(height: floatingHeaderHeight)

                        if tab == .briefs, let brief = model.selectedVoiceBrief {
                            BriefPreparationPanel(model: model, brief: brief)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 12)
                        }

                        XEmptyState(
                            icon: emptyIcon,
                            title: emptyTitle,
                            message: emptyMessage
                        )
                        .frame(maxWidth: 720, minHeight: 420)
                        .frame(maxWidth: .infinity)
                    }
                }
                .scrollIndicators(.hidden)
                .refreshable { await refresh() }
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        Color.clear
                            .frame(height: floatingHeaderHeight)

                        if tab == .briefs, let brief = model.selectedVoiceBrief {
                            BriefPreparationPanel(model: model, brief: brief)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 12)
                                .transition(.move(edge: .top).combined(with: .opacity))
                        }

                        ForEach(entries) { entry in
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
        .overlay(alignment: .top) { floatingHeader }
        .background(readerBackground.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .animation(.smooth(duration: 0.3), value: model.selectedVoiceBriefID)
        .animation(.snappy(duration: 0.24), value: showsSearch)
        .onDisappear {
            showsSearch = false
            model.query = ""
        }
    }

    private func closeSearch() {
        model.query = ""
        showsSearch = false
    }

    private let floatingHeaderHeight: CGFloat = 116

    private var floatingHeader: some View {
        VStack(spacing: 0) {
            if showsSearch {
                MobileXSearchField(
                    text: $model.query,
                    prompt: searchPrompt,
                    cancel: closeSearch
                )
                .transition(.move(edge: .top).combined(with: .opacity))
            } else {
                MobileXHeader(
                    title: title,
                    showsLogo: tab == .home,
                    showsSettings: $showsSettings,
                    showsSettingsButton: tab == .home,
                    search: MobileXHeaderAction(
                        icon: "magnifyingglass",
                        label: searchPrompt,
                        identifier: "library.search.open",
                        action: { showsSearch = true }
                    ),
                    primary: MobileXHeaderAction(
                        icon: "plus",
                        label: createLabel,
                        identifier: createLabel == "Capture" ? "capture.open" : nil,
                        action: create
                    ),
                    trailing: configurationAction
                )
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            choices
        }
        .mobileGlass(
            in: RoundedRectangle(cornerRadius: 24, style: .continuous),
            interactive: false
        )
        .padding(.horizontal, 8)
        .padding(.top, 4)
        .zIndex(10)
    }

    private var choices: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                choiceButton("All", selected: allSelected) {
                    switch tab {
                    case .home: Task { await model.showTopic("All") }
                    case .channels: model.selectedChannelSource = ""
                    case .briefs: model.selectedVoiceBriefID = ""
                    case .library: break
                    }
                }

                switch tab {
                case .home:
                    ForEach(model.projection.documentTopics, id: \.self) { topic in
                        choiceButton(topic, selected: model.selectedTopic == topic) {
                            Task { await model.showTopic(topic) }
                        }
                    }
                case .channels:
                    ForEach(model.channels) { channel in
                        choiceButton(
                            channel.title,
                            selected: model.selectedChannelSource == channel.source
                        ) {
                            model.selectChannel(channel.source)
                        }
                    }
                case .briefs:
                    ForEach(model.projection.voiceBriefDefinitions, id: \.id) { brief in
                        choiceButton(
                            brief.title,
                            selected: model.selectedVoiceBriefID == brief.id
                        ) {
                            model.selectVoiceBrief(brief.id)
                        }
                    }
                case .library:
                    EmptyView()
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)
            .padding(.bottom, 12)
        }
        .defaultScrollAnchor(.leading)
    }

    private func choiceButton(
        _ label: String,
        selected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(label)
                .font(.subheadline.weight(selected ? .semibold : .regular))
                .lineLimit(1)
                .padding(.horizontal, 15)
                .frame(height: 38)
                .background(selected ? Color.primary : Color.primary.opacity(0.06), in: Capsule())
                .foregroundStyle(selected ? Color(uiColor: .systemBackground) : Color.primary)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private var configurationAction: MobileXHeaderAction? {
        switch tab {
        case .channels:
            guard let channel = model.selectedChannel else { return nil }
            return MobileXHeaderAction(icon: "ellipsis", label: "Channel settings") {
                model.showChannelSettings(channel.source)
                openConfiguration()
            }
        case .briefs:
            guard let brief = model.selectedVoiceBrief else { return nil }
            return MobileXHeaderAction(icon: "ellipsis", label: "Brief settings") {
                model.showVoiceBriefSettings(brief.id)
                openConfiguration()
            }
        default:
            return nil
        }
    }

    private func refresh() async {
        switch tab {
        case .home: await model.refreshLibrary()
        case .channels:
            if model.selectedChannel != nil { await model.checkSelectedChannel() }
            else { await model.runDueChannelChecks() }
        case .briefs:
            if model.selectedVoiceBrief != nil { await model.runSelectedVoiceBrief() }
            else { await model.runDueVoiceBriefs() }
        case .library: break
        }
    }

    private var title: String {
        switch tab {
        case .home: "Home"
        case .channels: "Channels"
        case .briefs: "Briefs"
        case .library: "Library"
        }
    }

    private var searchPrompt: String {
        switch tab {
        case .home: "Search Home"
        case .channels: "Search Channels"
        case .briefs: "Search Briefs"
        case .library: "Search Library"
        }
    }

    private var createLabel: String {
        switch tab {
        case .home: "Capture"
        case .channels: "New channel"
        case .briefs: "New brief"
        case .library: "Capture"
        }
    }

    private var allSelected: Bool {
        switch tab {
        case .home: model.selectedTopic == "All" || model.selectedTopic.isEmpty
        case .channels: model.selectedChannelSource.isEmpty
        case .briefs: model.selectedVoiceBriefID.isEmpty
        case .library: false
        }
    }

    private var emptyIcon: String {
        if !model.query.isEmpty { return "magnifyingglass" }
        return switch tab {
        case .home: "tray"
        case .channels: "dot.radiowaves.left.and.right"
        case .briefs: "headphones"
        case .library: "bookmark"
        }
    }

    private var emptyTitle: String {
        if !model.query.isEmpty { return "No matches" }
        return switch tab {
        case .home: "Nothing here yet"
        case .channels: "No channel updates"
        case .briefs: "No generated briefs"
        case .library: "Library is empty"
        }
    }

    private var emptyMessage: String {
        if !model.query.isEmpty { return "Try another search." }
        return switch tab {
        case .home: "Capture a link or note to start your feed."
        case .channels: "Add a channel, then pull to fetch its latest updates."
        case .briefs: "Create a brief from your channels, then generate an episode."
        case .library: "Highlights and recently deleted notes appear here."
        }
    }
}

private struct MobileXHeaderAction {
    let icon: String
    let label: String
    var identifier: String? = nil
    let action: () -> Void
}

private struct MobileXHeader: View {
    let title: String
    var showsLogo = false
    @Binding var showsSettings: Bool
    var showsSettingsButton = false
    var search: MobileXHeaderAction? = nil
    var primary: MobileXHeaderAction? = nil
    var trailing: MobileXHeaderAction? = nil

    var body: some View {
        ZStack {
            if showsLogo {
                BrieflyLogo()
            } else {
                Text(title)
                    .font(.headline.weight(.bold))
            }

            HStack {
                if showsSettingsButton {
                    Button { showsSettings = true } label: {
                        Image(systemName: "gearshape")
                            .font(.system(size: 19, weight: .semibold))
                            .frame(width: 44, height: 44)
                            .background(Color.primary.opacity(0.06), in: Circle())
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Settings")
                    .accessibilityIdentifier("settings.open")
                }

                if let search {
                    headerButton(search)
                }

                Spacer()

                if let trailing {
                    headerButton(trailing)
                }

                if let primary {
                    headerButton(primary)
                } else if trailing == nil {
                    Color.clear.frame(width: 44, height: 44)
                }
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 52)
    }

    private func headerButton(_ action: MobileXHeaderAction) -> some View {
        Button(action: action.action) {
            Image(systemName: action.icon)
                .font(.system(size: 18, weight: .semibold))
                .frame(width: 44, height: 44)
                .background(Color.primary.opacity(0.06), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(action.label)
        .accessibilityIdentifier(
            action.identifier ?? "header.\(action.label.lowercased().replacingOccurrences(of: " ", with: "-"))"
        )
    }
}

private struct MobileXSearchField: View {
    @Binding var text: String
    let prompt: String
    let cancel: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 9) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField(prompt, text: $text)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .submitLabel(.search)
                    .accessibilityIdentifier("library.search")
                if !text.isEmpty {
                    Button { text = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                            .frame(width: 32, height: 32)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(.leading, 14)
            .padding(.trailing, 6)
            .frame(height: 40)
            .background(Color.primary.opacity(0.07), in: Capsule())

            Button("Cancel", action: cancel)
                .font(.subheadline.weight(.semibold))
                .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .frame(height: 52)
        .task { focused = true }
    }
}

private struct MobileXLibraryScreen: View {
    private enum Section: String, CaseIterable, Hashable {
        case highlights = "Highlights"
        case trash = "Trash"
    }

    @Bindable var model: LibraryModel
    @Binding var showsSettings: Bool
    let openEntry: (LibraryEntry) -> Void
    let create: () -> Void
    @State private var section = Section.highlights

    var body: some View {
        VStack(spacing: 0) {
            MobileXHeader(
                title: "Library",
                showsSettings: $showsSettings,
                primary: MobileXHeaderAction(
                    icon: "plus",
                    label: "Capture",
                    identifier: "capture.open",
                    action: create
                )
            )
            .mobileGlass(
                in: RoundedRectangle(cornerRadius: 24, style: .continuous),
                interactive: false
            )
            .padding(.horizontal, 8)
            .padding(.top, 4)

            HStack(spacing: 8) {
                ForEach(Section.allCases, id: \.self) { item in
                    Button {
                        section = item
                        if item == .highlights { model.showHighlights() }
                        else { model.showTrash() }
                    } label: {
                        Text(item.rawValue)
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .background(section == item ? Color.primary : Color.primary.opacity(0.06), in: Capsule())
                            .foregroundStyle(section == item ? Color(uiColor: .systemBackground) : Color.primary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .overlay(alignment: .bottom) { Divider() }

            if section == .highlights {
                if model.highlightsText.isEmpty {
                    XEmptyState(
                        icon: "highlighter",
                        title: "No highlights yet",
                        message: "Select a passage in any saved document, then choose Highlight."
                    )
                    .frame(maxWidth: 720, maxHeight: .infinity)
                } else {
                    ScrollView {
                        MarkdownArticle(model.highlightsText)
                            .frame(maxWidth: 680, alignment: .leading)
                            .padding(.horizontal, 22)
                            .padding(.vertical, 28)
                            .padding(.bottom, 80)
                            .frame(maxWidth: .infinity)
                    }
                }
            } else if model.trashEntries.isEmpty {
                XEmptyState(
                    icon: "trash",
                    title: "Trash is empty",
                    message: "Deleted notes remain available here."
                )
                .frame(maxWidth: 720, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(model.trashEntries) { entry in
                            FeedEntryRow(entry: entry) { openEntry(entry) }
                        }
                    }
                    .frame(maxWidth: 720)
                    .frame(maxWidth: .infinity)
                    .padding(.bottom, 96)
                }
            }
        }
        .background(readerBackground.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .task { model.showHighlights() }
    }
}

private struct MobileXDetail: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: LibraryModel
    @Binding var showsChannelBrowser: Bool
    @Bindable var audioPlayer: NativeAudioPlayer
    @Binding var audioEntry: LibraryEntry?

    var body: some View {
        LibraryDetail(
            model: model,
            showsChannelBrowser: $showsChannelBrowser,
            audioPlayer: audioPlayer,
            audioEntry: $audioEntry
        )
        .background(readerBackground.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(
            model.showingVoiceBriefSettings ? .hidden : .visible,
            for: .navigationBar
        )
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    model.navigateBack()
                    dismiss()
                } label: {
                    Image(systemName: "arrow.left")
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Back")
            }
        }
        .navigationBarBackButtonHidden(true)
    }
}

struct MobileCaptureComposer: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: LibraryModel
    let openPDFImporter: () -> Void
    let openBrowser: () -> Void
    @State private var draft = ""
    @FocusState private var focused: Bool

    private var canCapture: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !model.isProcessing
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                TextEditor(text: $draft)
                    .font(.system(size: 19))
                    .scrollContentBackground(.hidden)
                    .focused($focused)
                    .accessibilityIdentifier("capture.text")
                    .padding(.horizontal, 14)
                    .padding(.top, 12)
                    .overlay(alignment: .topLeading) {
                        if draft.isEmpty {
                            Text("Paste a link or write something…")
                                .font(.system(size: 19))
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 19)
                                .padding(.top, 22)
                                .allowsHitTesting(false)
                        }
                    }

                Divider()

                HStack(spacing: 8) {
                    composerTool("doc.richtext", label: "Import PDF", action: openPDFImporter)
                    composerTool("globe", label: "Signed-in browser", action: openBrowser)
                    Spacer()
                    if model.isProcessing { ProgressView().controlSize(.small) }
                }
                .padding(.horizontal, 10)
                .frame(height: 58)
            }
            .background(readerBackground.ignoresSafeArea())
            .navigationTitle("Capture")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let value = draft
                        dismiss()
                        Task { await model.capture(value) }
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
                    .disabled(!canCapture)
                    .accessibilityIdentifier("capture.save")
                }
            }
        }
        .task { focused = true }
    }

    private func composerTool(
        _ icon: String,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

private struct MobileHome: View {
    @Bindable var model: LibraryModel
    @Binding var showsSettings: Bool
    let onOpenDetail: () -> Void

    private var entries: [LibraryEntry] {
        model.homeEntries
            .filter { $0.matches(model.query) }
            .sorted {
                ($0.createdAt ?? $0.updatedAt ?? "") <
                    ($1.createdAt ?? $1.updatedAt ?? "")
            }
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                HStack {
                    Button {
                        showsSettings = true
                    } label: {
                        Image(systemName: "line.3.horizontal")
                            .font(.system(size: 20, weight: .medium))
                            .frame(width: 44, height: 44)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .mobileGlass(in: Circle())
                    .accessibilityLabel("Settings")

                    Spacer()
                }

                BrieflyLogo()
            }
            .padding(.horizontal, 18)
            .frame(height: 64)

            if entries.isEmpty {
                ContentUnavailableView(
                    model.query.isEmpty ? "Nothing here yet" : "No recent matches",
                    systemImage: model.query.isEmpty ? "tray" : "magnifyingglass",
                    description: Text(
                        model.query.isEmpty
                            ? "New items and voice briefs will appear here."
                            : "Try another search."
                    )
                )
                .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(entries) { entry in
                            MobileHomeEntryCard(
                                entry: entry
                            ) {
                                Task {
                                    model.activeSection = entry.voiceBriefID == nil
                                        ? .items
                                        : .briefs
                                    model.selectedVoiceBriefID = entry.voiceBriefID ?? ""
                                    await model.select(entry.id)
                                    onOpenDetail()
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                    .padding(.bottom, 150)
                }
                .defaultScrollAnchor(.bottom)
                .scrollIndicators(.hidden)
            }
        }
        .background(sidebarBackground.ignoresSafeArea())
    }
}

private struct MobileHomeEntryCard: View {
    let entry: LibraryEntry
    let action: () -> Void

    var body: some View {
        MobileEntryRow(entry: entry, kind: inferredKind, action: action)
    }

    private var inferredKind: MobileEntryKind {
        entry.voiceBriefID == nil ? .item : .brief
    }
}

enum MobileEntryKind {
    case item
    case channel
    case brief

    var palette: GrainyGradientPalette {
        switch self {
        case .item: .item
        case .channel: .channel
        case .brief: .brief
        }
    }
}

struct MobileEntryCard: View {
    let entry: LibraryEntry
    let kind: MobileEntryKind
    var selected = false
    let action: () -> Void

    var body: some View {
        MobileEntryRow(
            entry: entry,
            kind: kind,
            selected: selected,
            action: action
        )
    }
}

private struct MobileEntryRow: View {
    let entry: LibraryEntry
    let kind: MobileEntryKind
    var selected = false
    let action: () -> Void

    private var accent: Color {
        switch kind {
        case .item: Color(red: 0.60, green: 0.34, blue: 0.96)
        case .channel: Color(red: 0.93, green: 0.39, blue: 0.25)
        case .brief: Color(red: 0.08, green: 0.70, blue: 0.62)
        }
    }

    private var icon: String {
        switch kind {
        case .brief:
            return entry.hasAudio == true ? "waveform" : "headphones"
        case .channel:
            return "dot.radiowaves.left.and.right"
        case .item:
            return switch entry.entryType {
            case "pdf": "doc.richtext"
            case "link": "link"
            default: "doc.text"
            }
        }
    }

    private var date: Date? {
        guard let value = entry.createdAt ?? entry.updatedAt else { return nil }
        return try? Date(value, strategy: .iso8601)
    }

    private var dateText: String? {
        guard let date else { return nil }
        let elapsed = max(0, Date().timeIntervalSince(date))
        switch elapsed {
        case ..<3_600: return "\(max(1, Int(elapsed / 60)))m"
        case ..<86_400: return "\(Int(elapsed / 3_600))h"
        case ..<604_800: return "\(Int(elapsed / 86_400))d"
        case ..<2_592_000: return "\(Int(elapsed / 604_800))w"
        case ..<31_536_000: return "\(Int(elapsed / 2_592_000))mo"
        default: return "\(Int(elapsed / 31_536_000))y"
        }
    }

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(accent)
                    .symbolRenderingMode(.hierarchical)
                    .frame(width: 30, height: 30)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(entry.title)
                            .font(.headline.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        if let dateText {
                            Text(dateText)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.tertiary)
                                .monospacedDigit()
                                .fixedSize()
                        }
                    }

                    if !entry.excerpt.isEmpty {
                        Text(entry.excerpt)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(accent.opacity(0.9))
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, minHeight: 76, alignment: .leading)
            .contentShape(Rectangle())
            .background(selected ? accent.opacity(0.10) : Color.clear)
        }
        .buttonStyle(.plain)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.primary.opacity(0.075))
                .frame(height: 0.5)
                .padding(.leading, 54)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("library.entry.\(entry.id)")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityValue(
            date.map {
                $0.formatted(.relative(presentation: .named, unitsStyle: .wide))
            } ?? ""
        )
    }
}

private struct MobileLibraryNavigation: View {
    @Bindable var model: LibraryModel
    @Binding var preferredCompactColumn: NavigationSplitViewColumn
    @Binding var showsPDFImporter: Bool
    @Binding var homeSelected: Bool
    @Bindable var audioPlayer: NativeAudioPlayer
    @Binding var audioEntry: LibraryEntry?
    @State private var showsSearch = false
    @FocusState private var searchFocused: Bool
    @Namespace private var tabSelection

    var body: some View {
        Group {
            if #available(iOS 26.0, *) {
                GlassEffectContainer(spacing: 12) {
                    controls
                }
            } else {
                controls
            }
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 6)
        .animation(.snappy(duration: 0.2), value: showsSearch)
        .onChange(of: showsSearch) {
            searchFocused = showsSearch
        }
        .zIndex(10)
    }

    private var controls: some View {
        VStack(alignment: .trailing, spacing: 10) {
            if showsSearch {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField(
                        homeSelected ? "Search recent items" : model.activeSection.searchPrompt,
                        text: $model.query
                    )
                        .textFieldStyle(.plain)
                        .focused($searchFocused)
                        .submitLabel(.search)
                    if !model.query.isEmpty {
                        Button {
                            model.query = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Clear search")
                    }
                }
                .padding(.horizontal, 16)
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .mobileGlass(in: Capsule())
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            HStack(alignment: .bottom, spacing: 12) {
                VStack(spacing: 12) {
                    if isItemDetail, let entry = model.selectedEntry {
                        ReadingDepthStrip(model: model, entry: entry)
                            .frame(height: 58)
                    } else {
                        Color.clear.frame(height: 58)
                    }

                    HStack(spacing: 0) {
                        Button {
                            showsSearch = false
                            model.query = ""
                            withAnimation(.snappy(duration: 0.24)) {
                                homeSelected = true
                                preferredCompactColumn = .sidebar
                            }
                        } label: {
                            tabLabel(
                                icon: "house",
                                title: "Home",
                                selected: homeSelected
                            )
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Home")
                        .accessibilityAddTraits(homeSelected ? .isSelected : [])

                        ForEach(LibrarySection.allCases) { section in
                            Button {
                                showsSearch = false
                                withAnimation(.snappy(duration: 0.24)) {
                                    homeSelected = false
                                    preferredCompactColumn = .sidebar
                                }
                                Task { await model.show(section) }
                            } label: {
                                tabLabel(
                                    icon: section.icon,
                                    title: section.title,
                                    selected: !homeSelected &&
                                        model.activeSection == section
                                )
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(section.title)
                            .accessibilityAddTraits(
                                !homeSelected && model.activeSection == section
                                    ? .isSelected
                                    : []
                            )
                        }
                    }
                    .padding(4)
                    .frame(maxWidth: .infinity)
                    .frame(height: 64)
                    .mobileGlass(in: Capsule())
                    .animation(.snappy(duration: 0.24), value: model.activeSection)
                }
                .frame(maxWidth: .infinity)

                VStack(spacing: 12) {
                    Button(action: primaryAction) {
                        if model.isGeneratingSpeech && isPlayableDetail {
                            ProgressView()
                                .tint(.white)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .contentShape(Circle())
                        } else {
                            Image(systemName: primaryActionIcon)
                                .font(.system(size: 23, weight: .medium))
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .contentShape(Circle())
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.primary)
                    .frame(width: 58, height: 58)
                    .mobileGlass(in: Circle(), tint: .accentColor)
                    .accessibilityLabel(primaryActionLabel)
                    .disabled(primaryActionDisabled)

                    Button {
                        if showsSearch {
                            model.query = ""
                            showsSearch = false
                        } else {
                            preferredCompactColumn = .sidebar
                            showsSearch = true
                        }
                    } label: {
                        Image(systemName: showsSearch ? "xmark" : "magnifyingglass")
                            .font(.system(size: 21, weight: .medium))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .frame(width: 58, height: 58)
                    .mobileGlass(in: Circle())
                    .accessibilityLabel(showsSearch ? "Close search" : "Search")
                }
            }
        }
    }

    private func tabLabel(
        icon: String,
        title: String,
        selected: Bool
    ) -> some View {
        VStack(spacing: 2) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .medium))
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .foregroundStyle(selected ? Color.accentColor : Color.primary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .background {
            if selected {
                Capsule()
                    .fill(Color.primary.opacity(0.1))
                    .matchedGeometryEffect(id: "selected-tab", in: tabSelection)
            }
        }
    }

    private var createLabel: String {
        if homeSelected { return "Import PDF" }
        switch model.activeSection {
        case .items: return "Import PDF"
        case .channels: return "New channel"
        case .briefs: return "New voice brief"
        }
    }

    private var isVoiceBriefDetail: Bool {
        preferredCompactColumn == .detail &&
            model.activeSection == .briefs &&
            model.selectedEntry?.voiceBriefID != nil
    }

    private var isItemDetail: Bool {
        preferredCompactColumn == .detail &&
            !model.showingHighlights &&
            model.selectedEntry?.voiceBriefID == nil
    }

    private var isPlayableDetail: Bool {
        isVoiceBriefDetail || isItemDetail
    }

    private var isChannelPage: Bool {
        !homeSelected && model.activeSection == .channels &&
            model.selectedChannel != nil && model.selectedID.isEmpty
    }

    private var isVoiceBriefPage: Bool {
        !homeSelected && model.activeSection == .briefs &&
            model.selectedVoiceBrief != nil && model.selectedID.isEmpty
    }

    private var primaryActionIcon: String {
        if isPlayableDetail { return "play.fill" }
        if isChannelPage { return "arrow.clockwise" }
        if isVoiceBriefPage { return "sparkles" }
        return "plus"
    }

    private var primaryActionLabel: String {
        if isPlayableDetail { return "Play audio" }
        if isChannelPage { return "Fetch fresh channel items" }
        if isVoiceBriefPage { return "Generate fresh voice brief" }
        return createLabel
    }

    private var primaryActionDisabled: Bool {
        (isPlayableDetail &&
            (model.isGeneratingSpeech || model.isRunningVoiceBrief ||
                model.selectedText.isEmpty)) ||
            (isChannelPage && model.isCheckingChannel) ||
            (isVoiceBriefPage &&
                (model.isRunningVoiceBrief || model.selectedVoiceBrief?.sources.isEmpty != false))
    }

    private func primaryAction() {
        if isPlayableDetail, let entry = model.selectedEntry {
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
                            try audioPlayer.appendSegment(url, playbackID: playbackID)
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
            return
        }
        if isChannelPage {
            Task { await model.checkSelectedChannel() }
        } else if isVoiceBriefPage {
            Task { await model.runSelectedVoiceBrief() }
        } else {
            create()
        }
    }

    private func create() {
        showsSearch = false
        model.query = ""
        model.selectedID = ""
        model.selectedIDs = []
        if homeSelected {
            showsPDFImporter = true
            return
        }
        switch model.activeSection {
        case .items:
            showsPDFImporter = true
        case .channels:
            model.selectedChannelSource = "new"
            preferredCompactColumn = .detail
        case .briefs:
            model.selectedVoiceBriefID = "new"
            preferredCompactColumn = .detail
        }
    }
}

#endif
