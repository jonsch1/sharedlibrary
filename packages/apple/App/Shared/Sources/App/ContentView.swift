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
    @AppStorage(BrieflyOnboarding.completionKey) private var completedOnboardingVersion = 0
    @Bindable var model: LibraryModel
    @State private var showsSettings = false
    @State private var showsCaptureComposer = false
    @State private var showsFileImporter = false
    @State private var windowControlsVisible = true
    #if os(macOS)
    @AppStorage(MacWorkspaceLayout.sidebarCollapsedKey) private var sidebarCollapsed = false
    @State private var selectedSettingsSection = BrieflySettingsSection.general
    @State private var focusesSearch = false
    #endif
    @State private var audioPlayer = NativeAudioPlayer()
    @State private var audioEntry: LibraryEntry?

    var body: some View {
        Group {
            if needsOnboarding {
                BrieflyOnboarding {
                    completedOnboardingVersion = BrieflyOnboarding.currentVersion
                }
            } else {
                if model.lifecycle.isReady {
                #if os(macOS)
                GeometryReader { proxy in
                    macWorkspace(
                        MacWorkspaceLayout(
                            windowWidth: proxy.size.width,
                            sidebarCollapsed: sidebarCollapsed
                        )
                    )
                }
                .background {
                    BrieflyAtmosphere()
                        .ignoresSafeArea()
                }
                .ignoresSafeArea(.container, edges: .top)
                .modifier(FullScreenToolbarBehavior())
                .background(
                    WindowControlPositioner(
                        controlsVisible: $windowControlsVisible,
                        sidebarCollapsed: $sidebarCollapsed
                    )
                )
                #else
                MobileXAppShell(
                    model: model,
                    showsCaptureComposer: $showsCaptureComposer,
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
        }
        #if os(macOS)
        .frame(
            minWidth: MacWorkspaceLayout.minimumWindowSize.width,
            minHeight: MacWorkspaceLayout.minimumWindowSize.height
        )
        #endif
        .task {
            await model.workflows.start()
        }
        .task {
            guard model.lifecycle.runsScheduledWork else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5 * 60))
                guard !Task.isCancelled else { return }
                if model.session.canEdit { await model.workflows.sync() }
                await model.workflows.runDueChannelChecks()
            }
        }
        .task {
            guard model.lifecycle.runsScheduledWork else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15 * 60))
                guard !Task.isCancelled else { return }
                await model.account.refreshAccount()
            }
        }
        .onChange(of: scenePhase) {
            if scenePhase == .active, model.lifecycle.runsScheduledWork {
                Task {
                    await model.account.refreshAccount()
                    await model.workflows.importPendingSharedCaptures()
                    if model.session.canEdit { await model.workflows.sync() }
                    await model.workflows.runDueChannelChecks()
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .CKAccountChanged)) { _ in
            guard model.lifecycle.runsScheduledWork else { return }
            Task {
                if model.session.canEdit { await model.workflows.sync() }
            }
        }
        #if os(macOS)
        .sheet(isPresented: $showsCaptureComposer) { CaptureComposer(model: model) }
        #endif
        #if os(iOS)
        .fullScreenCover(isPresented: $showsCaptureComposer) { CaptureComposer(model: model) }
        #endif
        .fileImporter(
            isPresented: $showsFileImporter,
            allowedContentTypes: CaptureComposer.fileTypes
        ) { result in
            switch result {
            case .success(let url):
                Task { await model.workflows.captureFile(url) }
            case .failure(let error):
                model.session.errorMessage = error.localizedDescription
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard urls.count == 1 else {
                model.session.errorMessage = "Drop one file or link at a time."
                return false
            }
            if urls[0].isFileURL {
                Task { await model.workflows.captureFile(urls[0]) }
                return true
            }
            if ["http", "https"].contains(urls[0].scheme?.lowercased() ?? "") {
                Task { await model.workflows.capture(urls[0].absoluteString) }
                return true
            }
            model.session.errorMessage = "Drop a PDF, text file, or web link."
            return false
        }
        #if os(iOS)
        .alert(
            "Briefly",
            isPresented: Binding(
                get: { !needsOnboarding && model.session.errorMessage != nil },
                set: { if !$0 { model.workflows.clearError() } }
            )
        ) {
            Button("OK") { model.workflows.clearError() }
        } message: {
            Text(model.session.errorMessage ?? "")
        }
        #else
        .overlay(alignment: .top) {
            if !needsOnboarding, let message = model.session.errorMessage {
                XErrorBanner(message: message, dismiss: model.workflows.clearError)
                    .padding(.horizontal, 20)
                    .padding(.top, 18)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        #endif
        #if os(macOS)
        .alert(
            "Custom capture failed",
            isPresented: Binding(
                get: { model.session.customCaptureFailure != nil },
                set: { if !$0 { model.session.customCaptureFailure = nil } }
            ),
            presenting: model.session.customCaptureFailure
        ) { failure in
            Button("Retry") {
                Task { await model.workflows.capture(failure.url.absoluteString) }
            }
            Button("Use native capture") {
                Task { await model.workflows.capture(failure.url.absoluteString, useNative: true) }
            }
            Button("Cancel", role: .cancel) { model.session.customCaptureFailure = nil }
        } message: { failure in
            Text(failure.localizedDescription)
        }
        #endif
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
            NotificationCenter.default.publisher(for: .brieflyImportFile)
        ) { _ in
            showsFileImporter = true
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .brieflyRefreshLibrary)
        ) { _ in
            Task<Void, Never> { await model.workflows.refreshLibrary() }
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .brieflyOpenCaptureComposer)
        ) { _ in
            guard showsWorkspace else { return }
            showsCaptureComposer = true
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .brieflyOpenSettings)
        ) { _ in
            guard showsWorkspace else { return }
            showsSettings = true
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .brieflyNavigateBack)
        ) { _ in
            guard showsWorkspace, model.selection.selectedEntry != nil else { return }
            showsSettings = false
            Task { await model.workflows.select("") }
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .brieflyFocusSearch)
        ) { _ in
            guard showsWorkspace else { return }
            showsSettings = false
            // The search field sits at the top of the list, so return to it first.
            if model.navigation.showingHighlights {
                model.workflows.showInbox()
            } else if model.navigation.activeSection == .channels &&
                (model.navigation.showingChannelSettings ||
                    !model.navigation.selectedChannelSource.isEmpty)
            {
                model.workflows.selectChannel("")
            } else if model.selection.selectedEntry != nil {
                Task { await model.workflows.select("") }
            }
            focusesSearch = true
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

    private var needsOnboarding: Bool {
        !model.session.environment.isUITesting &&
            !model.session.environment.isAppReviewTesting &&
            completedOnboardingVersion < BrieflyOnboarding.currentVersion
    }

    #if os(macOS)
    private var showsWorkspace: Bool {
        !needsOnboarding && model.lifecycle.isReady
    }

    private func macWorkspace(_ layout: MacWorkspaceLayout) -> some View {
        HStack(alignment: .top, spacing: MacWorkspaceLayout.spacing) {
            MacXNavigation(
                model: model,
                showsSettings: $showsSettings,
                showsCaptureComposer: $showsCaptureComposer,
                selectedSettingsSection: $selectedSettingsSection,
                collapsed: $sidebarCollapsed,
                logoBelowWindowControls: layout.logoBelowWindowControls
            )
            .frame(width: layout.sidebarWidth)

            if showsSettings {
                MacXSettingsWorkspace(
                    model: model,
                    selectedSection: $selectedSettingsSection,
                    indexWidth: layout.settingsIndexWidth,
                    contentWidth: layout.settingsWidth
                )
                .frame(width: layout.contentAreaWidth)
                .frame(maxHeight: .infinity)
            } else {
                LibraryDetail(
                    model: model,
                    audioPlayer: audioPlayer,
                    audioEntry: $audioEntry
                )
                .environment(\.librarySearchFocusRequest, $focusesSearch)
                .environment(\.readingColumnWidth, layout.readerColumnWidth)
                .frame(width: layout.contentAreaWidth)
                .frame(maxHeight: .infinity)
                .clipShape(Rectangle())
            }
        }
        .padding(.leading, layout.leadingOffset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .ignoresSafeArea(.container, edges: .top)
        .animation(.snappy(duration: 0.22), value: sidebarCollapsed)
    }
    #endif
}
