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

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("BrieflyAppearance") private var appearance = "system"
    @Bindable var model: LibraryModel
    @State private var showsChannelBrowser = false
    @State private var showsSettings = false
    @State private var showsCaptureComposer = false
    @State private var showsPDFImporter = false
    @State private var windowControlsVisible = true
    @State private var audioPlayer = NativeAudioPlayer()
    @State private var audioEntry: LibraryEntry?

    var body: some View {
        Group {
            if model.isReady {
                #if os(macOS)
                HStack(alignment: .top, spacing: 24) {
                    MacXNavigation(
                        model: model,
                        showsSettings: $showsSettings,
                        showsCaptureComposer: $showsCaptureComposer
                    )
                    .frame(width: 220)

                    if showsSettings {
                        MacXSettingsWorkspace(model: model)
                            .frame(width: 1_014)
                    } else {
                        LibraryDetail(
                            model: model,
                            showsChannelBrowser: $showsChannelBrowser,
                            audioPlayer: audioPlayer,
                            audioEntry: $audioEntry
                        )
                        .layoutPriority(1)
                        .frame(width: 680)
                        .frame(maxHeight: .infinity)
                        .background(
                            .ultraThinMaterial.opacity(0.56),
                            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                        )
                        .clipShape(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .stroke(Color.primary.opacity(0.10))
                        }

                        MacXRightRail(model: model)
                            .frame(width: 310)
                    }
                }
                .padding(.horizontal, 20)
                .frame(maxWidth: 1298, maxHeight: .infinity, alignment: .top)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background {
                    BrieflyAtmosphere()
                        .ignoresSafeArea()
                }
                .ignoresSafeArea(.container, edges: .top)
                .modifier(FullScreenToolbarBehavior())
                .background(
                    WindowControlPositioner(
                        x: 10,
                        y: -12,
                        controlsVisible: $windowControlsVisible
                    )
                )
                #else
                MobileXAppShell(
                    model: model,
                    showsSettings: $showsSettings,
                    showsCaptureComposer: $showsCaptureComposer,
                    showsChannelBrowser: $showsChannelBrowser,
                    audioPlayer: audioPlayer,
                    audioEntry: $audioEntry
                )
                #endif
            } else {
                #if os(macOS)
                MacXLoadingWorkspace(status: model.status)
                #else
                ProgressView(model.status)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                #endif
            }
        }
        .task { await model.start() }
        .task {
            guard model.runsScheduledWork else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled else { return }
                await model.resumePendingVoiceBriefs()
                await model.runDueChannelChecks()
                await model.runDueVoiceBriefs()
            }
        }
        .onChange(of: scenePhase) {
            if scenePhase == .active, model.runsScheduledWork {
                Task {
                    #if os(iOS)
                    if model.canEdit { await model.sync() }
                    #endif
                    await model.resumePendingVoiceBriefs()
                    await model.runDueChannelChecks()
                    await model.runDueVoiceBriefs()
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .CKAccountChanged)) { _ in
            guard model.runsScheduledWork else { return }
            Task {
                if model.canEdit { await model.sync() }
            }
        }
        .sheet(isPresented: $showsChannelBrowser) {
            if model.canEdit {
                ChannelLoginView(
                    initialAddress: model.channelBrowserAddress.isEmpty
                        ? model.selectedChannel?.primarySource ?? ""
                        : model.channelBrowserAddress,
                    onCapture: { url, page in
                        if model.selectedChannelSource == "new" ||
                            model.channelBrowserStagesSource
                        {
                            model.stageChannelSource(url.absoluteString)
                        } else {
                            await model.captureWebPage(url: url, page: page)
                        }
                    },
                    onActivity: model.setBrowserIngesting
                )
            } else {
                ChannelLoginView(
                    initialAddress: model.channelBrowserAddress.isEmpty
                        ? model.selectedChannel?.primarySource ?? ""
                        : model.channelBrowserAddress
                )
            }
        }
        #if os(macOS)
        .sheet(isPresented: $showsCaptureComposer) {
            MacCaptureComposer(
                model: model,
                openPDFImporter: {
                    showsCaptureComposer = false
                    showsPDFImporter = true
                },
                openBrowser: {
                    showsCaptureComposer = false
                    showsChannelBrowser = true
                }
            )
        }
        #endif
        #if os(iOS)
        .fullScreenCover(isPresented: $showsSettings) {
            SettingsView(model: model)
        }
        .fullScreenCover(isPresented: $showsCaptureComposer) {
            MobileCaptureComposer(
                model: model,
                openPDFImporter: {
                    showsCaptureComposer = false
                    showsPDFImporter = true
                },
                openBrowser: {
                    showsCaptureComposer = false
                    showsChannelBrowser = true
                }
            )
        }
        #endif
        .fileImporter(
            isPresented: $showsPDFImporter,
            allowedContentTypes: [.pdf]
        ) { result in
            switch result {
            case .success(let url):
                Task { await model.capturePDF(url) }
            case .failure(let error):
                model.errorMessage = error.localizedDescription
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard urls.count == 1 else {
                model.errorMessage = "Drop one document or link at a time."
                return false
            }
            if urls[0].pathExtension.lowercased() == "pdf" {
                Task { await model.capturePDF(urls[0]) }
                return true
            }
            if ["http", "https"].contains(urls[0].scheme?.lowercased() ?? "") {
                Task { await model.capture(urls[0].absoluteString) }
                return true
            }
            model.errorMessage = "Drop a PDF or web link."
            return false
        }
        #if os(iOS)
        .alert(
            "Briefly",
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.clearError() } }
            )
        ) {
            Button("OK") { model.clearError() }
        } message: {
            Text(model.errorMessage ?? "")
        }
        #else
        .overlay(alignment: .top) {
            if let message = model.errorMessage {
                XErrorBanner(message: message, dismiss: model.clearError)
                    .padding(.top, 18)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        #endif
        #if os(macOS)
        .overlay(alignment: .bottomTrailing) {
            if model.isSyncing {
                SyncActivityView(model: model)
                    .padding(.horizontal, 18)
                    .padding(.bottom, 66)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            } else if model.isProcessing || model.isGeneratingSpeech ||
                model.isPreparingSpeech
            {
                HStack(spacing: 9) {
                    ProgressView()
                        .controlSize(.small)
                    Text(model.activityStatus)
                        .font(.callout)
                }
                .padding(.horizontal, 14)
                .frame(height: 40)
                .macLiquidGlass(in: Capsule())
                .padding(18)
                .padding(.bottom, 48)
                .accessibilityElement(children: .combine)
            }
        }
        #endif
        .animation(.snappy(duration: 0.24), value: model.isSyncing)
        .sheet(item: $audioEntry) { entry in
            AudioPlayerScreen(
                text: model.selectedID == entry.id && !model.selectedText.isEmpty
                    ? model.selectedText
                    : entry.text(for: model.selectedVariant)?.text ?? entry.excerpt,
                audioPlayer: audioPlayer
            )
        }
        #if os(macOS)
        .onReceive(
            NotificationCenter.default.publisher(for: .brieflyCaptureClipboard)
        ) { _ in
            let text = NSPasteboard.general.string(forType: .string) ?? ""
            Task { await model.capture(text) }
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .brieflyImportPDF)
        ) { _ in
            showsPDFImporter = true
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .brieflyRefreshLibrary)
        ) { _ in
            Task<Void, Never> { await model.refreshLibrary() }
        }
        #endif
        .preferredColorScheme(
            appearance == "light" ? .light :
                appearance == "dark" ? .dark : nil
        )
        .fontDesign(.rounded)
        #if os(macOS)
        .controlSize(.large)
        #endif
}
}
