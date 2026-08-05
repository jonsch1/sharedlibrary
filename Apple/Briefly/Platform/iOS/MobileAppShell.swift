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

#endif
