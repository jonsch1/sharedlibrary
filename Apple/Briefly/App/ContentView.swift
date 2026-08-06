import Foundation
import SwiftUI
import BrieflyCore
import CloudKit
#if os(macOS)
import AppKit
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
            if model.lifecycle.isReady {
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
                MacXLoadingWorkspace(status: model.session.status)
                #else
                ProgressView(model.session.status)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                #endif
            }
        }
        .task { await model.workflows.start() }
        .task {
            guard model.lifecycle.runsScheduledWork else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled else { return }
                if model.session.canEdit { await model.workflows.sync() }
                await model.workflows.resumePendingVoiceBriefs()
                await model.workflows.runDueChannelChecks()
                await model.workflows.runDueVoiceBriefs()
            }
        }
        .onChange(of: scenePhase) {
            if scenePhase == .active, model.lifecycle.runsScheduledWork {
                Task {
                    if model.session.canEdit { await model.workflows.sync() }
                    await model.workflows.resumePendingVoiceBriefs()
                    await model.workflows.runDueChannelChecks()
                    await model.workflows.runDueVoiceBriefs()
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .CKAccountChanged)) { _ in
            guard model.lifecycle.runsScheduledWork else { return }
            Task {
                if model.session.canEdit { await model.workflows.sync() }
            }
        }
        .sheet(isPresented: $showsChannelBrowser) {
            if model.session.canEdit {
                ChannelLoginView(
                    initialAddress: model.channels.channelBrowserAddress.isEmpty
                        ? model.channels.selectedChannel(for: model.navigation.selectedChannelSource)?.primarySource ?? ""
                        : model.channels.channelBrowserAddress,
                    onCapture: { url, page in
                        if model.navigation.selectedChannelSource == "new" ||
                            model.channels.channelBrowserStagesSource
                        {
                            model.channels.stageChannelSource(url.absoluteString)
                        } else {
                            await model.workflows.captureWebPage(url: url, page: page)
                        }
                    },
                    onActivity: model.workflows.setBrowserIngesting
                )
            } else {
                ChannelLoginView(
                    initialAddress: model.channels.channelBrowserAddress.isEmpty
                        ? model.channels.selectedChannel(for: model.navigation.selectedChannelSource)?.primarySource ?? ""
                        : model.channels.channelBrowserAddress
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
                Task { await model.workflows.capturePDF(url) }
            case .failure(let error):
                model.session.errorMessage = error.localizedDescription
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard urls.count == 1 else {
                model.session.errorMessage = "Drop one document or link at a time."
                return false
            }
            if urls[0].pathExtension.lowercased() == "pdf" {
                Task { await model.workflows.capturePDF(urls[0]) }
                return true
            }
            if ["http", "https"].contains(urls[0].scheme?.lowercased() ?? "") {
                Task { await model.workflows.capture(urls[0].absoluteString) }
                return true
            }
            model.session.errorMessage = "Drop a PDF or web link."
            return false
        }
        #if os(iOS)
        .alert(
            "Briefly",
            isPresented: Binding(
                get: { model.session.errorMessage != nil },
                set: { if !$0 { model.workflows.clearError() } }
            )
        ) {
            Button("OK") { model.workflows.clearError() }
        } message: {
            Text(model.session.errorMessage ?? "")
        }
        #else
        .overlay(alignment: .top) {
            if let message = model.session.errorMessage {
                XErrorBanner(message: message, dismiss: model.workflows.clearError)
                    .padding(.top, 18)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        #endif
        #if os(macOS)
        .overlay(alignment: .bottomTrailing) {
            if model.lifecycle.isSyncing {
                SyncActivityView(model: model)
                    .padding(.horizontal, 18)
                    .padding(.bottom, 66)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            } else if model.processing.isProcessing || model.audio.isGeneratingSpeech ||
                model.audio.isPreparingSpeech
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
        .animation(.snappy(duration: 0.24), value: model.lifecycle.isSyncing)
        .sheet(item: $audioEntry) { entry in
            AudioPlayerScreen(
                text: model.selection.selectedID == entry.id && !model.selection.selectedText.isEmpty
                    ? model.selection.selectedText
                    : entry.text(for: model.selection.selectedVariant)?.text ?? entry.excerpt,
                audioPlayer: audioPlayer
            )
        }
        #if os(macOS)
        .onReceive(
            NotificationCenter.default.publisher(for: .brieflyCaptureClipboard)
        ) { _ in
            let text = NSPasteboard.general.string(forType: .string) ?? ""
            Task { await model.workflows.capture(text) }
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .brieflyImportPDF)
        ) { _ in
            showsPDFImporter = true
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .brieflyRefreshLibrary)
        ) { _ in
            Task<Void, Never> { await model.workflows.refreshLibrary() }
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
