import BrieflyCore

import SwiftUI

#if os(iOS)
struct MobileLibraryNavigation: View {
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
                        homeSelected ? "Search recent items" : model.navigation.activeSection.searchPrompt,
                        text: $model.navigation.query
                    )
                        .textFieldStyle(.plain)
                        .focused($searchFocused)
                        .submitLabel(.search)
                    if !model.navigation.query.isEmpty {
                        Button {
                            model.navigation.query = ""
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
                    if isItemDetail, let entry = model.selection.selectedEntry {
                        ReadingDepthStrip(model: model, entry: entry)
                            .frame(height: 58)
                    } else {
                        Color.clear.frame(height: 58)
                    }

                    HStack(spacing: 0) {
                        Button {
                            showsSearch = false
                            model.navigation.query = ""
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
                                Task { await model.workflows.show(section) }
                            } label: {
                                tabLabel(
                                    icon: section.icon,
                                    title: section.title,
                                    selected: !homeSelected &&
                                        model.navigation.activeSection == section
                                )
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(section.title)
                            .accessibilityAddTraits(
                                !homeSelected && model.navigation.activeSection == section
                                    ? .isSelected
                                    : []
                            )
                        }
                    }
                    .padding(4)
                    .frame(maxWidth: .infinity)
                    .frame(height: 64)
                    .mobileGlass(in: Capsule())
                    .animation(.snappy(duration: 0.24), value: model.navigation.activeSection)
                }
                .frame(maxWidth: .infinity)

                VStack(spacing: 12) {
                    Button(action: primaryAction) {
                        if model.audio.isGeneratingSpeech && isPlayableDetail {
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
                            model.navigation.query = ""
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
        switch model.navigation.activeSection {
        case .items: return "Import PDF"
        case .channels: return "New channel"
        case .briefs: return "New voice brief"
        }
    }

    private var isVoiceBriefDetail: Bool {
        preferredCompactColumn == .detail &&
            model.navigation.activeSection == .briefs &&
            model.selection.selectedEntry?.voiceBriefID != nil
    }

    private var isItemDetail: Bool {
        preferredCompactColumn == .detail &&
            !model.navigation.showingHighlights &&
            model.selection.selectedEntry?.voiceBriefID == nil
    }

    private var isPlayableDetail: Bool {
        isVoiceBriefDetail || isItemDetail
    }

    private var isChannelPage: Bool {
        !homeSelected && model.navigation.activeSection == .channels &&
            model.channels.selectedChannel(for: model.navigation.selectedChannelSource) != nil && model.selection.selectedID.isEmpty
    }

    private var isVoiceBriefPage: Bool {
        !homeSelected && model.navigation.activeSection == .briefs &&
            model.voiceBriefs.voiceBrief(for: model.navigation.selectedVoiceBriefID) != nil && model.selection.selectedID.isEmpty
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
            (model.audio.isGeneratingSpeech || model.voiceBriefs.isRunningVoiceBrief ||
                model.selection.selectedText.isEmpty)) ||
            (isChannelPage && model.channels.isCheckingChannel) ||
            (isVoiceBriefPage &&
                (model.voiceBriefs.isRunningVoiceBrief ||
                    model.voiceBriefs.voiceBrief(for: model.navigation.selectedVoiceBriefID)?.sources.isEmpty != false))
    }

    private func primaryAction() {
        if isPlayableDetail, let entry = model.selection.selectedEntry {
            Task {
                let variant = model.selection.selectedVariant
                let text = model.selection.selectedText
                let playbackID = model.audio.audioPlaybackID(
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
                        _ = await model.workflows.streamPlayableAudio(
                            for: entry,
                            variant: variant,
                            text: text,
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
                    model.session.errorMessage = error.localizedDescription
                    audioPlayer.stop()
                }
            }
            return
        }
        if isChannelPage {
            Task { await model.workflows.checkSelectedChannel() }
        } else if isVoiceBriefPage {
            Task { await model.workflows.runSelectedVoiceBrief() }
        } else {
            create()
        }
    }

    private func create() {
        showsSearch = false
        model.navigation.query = ""
        model.selection.selectedID = ""
        model.selection.selectedIDs = []
        if homeSelected {
            showsPDFImporter = true
            return
        }
        switch model.navigation.activeSection {
        case .items:
            showsPDFImporter = true
        case .channels:
            model.navigation.selectedChannelSource = "new"
            preferredCompactColumn = .detail
        case .briefs:
            model.navigation.selectedVoiceBriefID = "new"
            preferredCompactColumn = .detail
        }
    }
}

#endif
