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

extension SettingsView {
    var body: some View {
        NavigationSplitView {
            #if os(iOS)
            List(selection: $selectedSection) {
                Section("General settings") {
                    settingsRow(
                        .account,
                        value: model.account.authenticated ? "Signed in" : "Signed out"
                    )
                    settingsRow(
                        .general,
                        value: appearance == "system" ? "Auto" : appearance.capitalized
                    )
                    settingsRow(.library)
                }

                Section("Briefly") {
                    settingsRow(.capture)
                    settingsRow(.personalization)
                }

                Section("Advanced") {
                    settingsRow(.topics)
                    settingsRow(.ai)
                }

                Section("Help") {
                    externalSettingsRow(
                        "Feedback",
                        icon: "bubble.left.and.bubble.right",
                        destination: "https://www.readbriefly.fyi/feedback"
                    )
                }

                Section("Legal") {
                    externalSettingsRow(
                        "Terms of Use",
                        icon: "doc.text",
                        destination: "https://www.readbriefly.fyi/terms"
                    )
                    externalSettingsRow(
                        "Privacy Policy",
                        icon: "hand.raised",
                        destination: "https://www.readbriefly.fyi/privacy"
                    )
                    externalSettingsRow(
                        "Imprint",
                        icon: "building.columns",
                        destination: "https://www.readbriefly.fyi/imprint"
                    )
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(readerBackground)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            #else
            VStack(alignment: .leading, spacing: 0) {
                Text("Settings")
                    .font(.title2.weight(.bold))
                    .padding(.horizontal, 18)
                    .padding(.top, 18)
                    .padding(.bottom, 14)

                HStack(spacing: 9) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Search Settings", text: $settingsQuery)
                        .textFieldStyle(.plain)
                    if !settingsQuery.isEmpty {
                        Button {
                            settingsQuery = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 13)
                .frame(height: 38)
                .background(Color.primary.opacity(0.055), in: Capsule())
                .overlay { Capsule().stroke(Color.primary.opacity(0.09)) }
                .padding(.horizontal, 14)
                .padding(.bottom, 10)

                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(filteredSettingsSections) { section in
                            Button {
                                selectedSection = section
                            } label: {
                                settingsNavigationRow(section)
                            }
                            .buttonStyle(.plain)
                        }

                        Divider().padding(.vertical, 8)

                        externalSettingsRow(
                            "Feedback",
                            icon: "bubble.left.and.bubble.right",
                            destination: "https://www.readbriefly.fyi/feedback"
                        )
                        .padding(.horizontal, 16)
                        externalSettingsRow(
                            "Privacy Policy",
                            icon: "hand.raised",
                            destination: "https://www.readbriefly.fyi/privacy"
                        )
                        .padding(.horizontal, 16)
                        externalSettingsRow(
                            "Terms of Use",
                            icon: "doc.text",
                            destination: "https://www.readbriefly.fyi/terms"
                        )
                        .padding(.horizontal, 16)
                    }
                }
            }
            .background(.ultraThinMaterial.opacity(0.56))
            .overlay { Rectangle().stroke(Color.primary.opacity(0.10)) }
            .navigationSplitViewColumnWidth(min: 370, ideal: 390, max: 410)
            #endif
        } detail: {
            NavigationStack {
                Form {
                    switch selectedSection ?? .general {
                    case .general:
                Section("Appearance") {
                    Picker("Mode", selection: $appearance) {
                        Text("System").tag("system")
                        Text("Light").tag("light")
                        Text("Dark").tag("dark")
                    }
                    .pickerStyle(.segmented)
                }

                    case .library:
                Section("Library") {
                    LabeledContent("Storage", value: "Local SQLite database")
                    LabeledContent("Status", value: model.status)
                    if model.isSyncing {
                        SyncActivityView(model: model)
                            .padding(.vertical, 4)
                    }
                    if model.canEdit {
                        Button {
                            Task { await model.refreshLibrary() }
                        } label: {
                            Label("Refresh library", systemImage: "arrow.clockwise")
                        }
                    }
                    Button {
                        Task { await model.sync() }
                    } label: {
                        Label(
                            model.isSyncing ? "Syncing…" : "Sync with iCloud",
                            systemImage: "arrow.triangle.2.circlepath"
                        )
                    }
                    .disabled(model.isSyncing)
                }

                    case .capture:
                #if os(macOS)
                Section("Capture shortcut") {
                    HStack {
                        ShortcutRecorder(shortcut: $captureShortcut)
                            .frame(width: 150, height: 30)
                        Button("Reset") {
                            captureShortcut = .defaultValue
                        }
                        .disabled(captureShortcut == .defaultValue)
                    }
                    Text(
                        shortcutRegistered
                            ? "Active system-wide. Click the field and press a replacement shortcut."
                            : "This shortcut is unavailable; choose another combination."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                #endif

                Section("Capture tools") {
                    #if os(macOS)
                    if model.canEdit {
                        Button {
                            let text = NSPasteboard.general.string(forType: .string) ?? ""
                            Task { await model.capture(text) }
                        } label: {
                            Label("Capture clipboard", systemImage: "clipboard")
                        }
                    }
                    #endif
                    if model.canEdit {
                        Button {
                            showsPDFImporter = true
                        } label: {
                            Label("Import PDF", systemImage: "doc.richtext")
                        }
                    }
                    Button {
                        showsChannelBrowser = true
                    } label: {
                        Label("Signed-in browser", systemImage: "globe")
                    }
                }
                Section("Media") {
                    Toggle("Save captured YouTube audio", isOn: $saveCapturedAudio)
                    Text("Applies to manual link captures. Podcast episode audio remains streamed from its source.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                    case .account:
                Section("Briefly account") {
                    LabeledContent(
                        "Status",
                        value: model.account.authenticated
                            ? model.account.email ?? "Signed in"
                            : "Signed out"
                    )
                    if model.account.authenticated {
                        LabeledContent(
                            "Membership",
                            value: model.account.entitled == true
                                ? "Active"
                                : "Needs activation"
                        )
                    }
                    HStack {
                        if model.account.authenticated {
                            Button("Sign out", role: .destructive) {
                                Task { await model.signOut() }
                            }
                        }
                        Spacer()
                        Button {
                            Task { await model.refreshAccount(reportErrors: true) }
                        } label: {
                            if model.isCheckingAccount {
                                ProgressView()
                            } else {
                                Label("Refresh", systemImage: "arrow.clockwise")
                            }
                        }
                        .disabled(model.isCheckingAccount)
                    }
                    if model.account.authenticated {
                        if model.account.entitled == true {
                            Link(
                                "Manage App Store subscription",
                                destination: URL(string: "https://apps.apple.com/account/subscriptions")!
                            )
                        } else if let product = model.subscriptionProduct {
                            Button("Subscribe — \(product.displayPrice)/month") {
                                Task { await model.purchaseSubscription() }
                            }
                            .disabled(model.isPurchasingSubscription)
                        } else {
                            Text("The subscription is not available from the App Store yet.")
                                .foregroundStyle(.secondary)
                        }
                        Button("Restore purchases") {
                            Task { await model.restoreSubscription() }
                        }
                        .disabled(model.isPurchasingSubscription)
                    } else {
                        SignInWithAppleButton(.signIn) { request in
                            let nonce = randomAppleNonce()
                            appleSignInNonce = nonce
                            request.requestedScopes = [.email]
                            request.nonce = SHA256.hash(data: Data(nonce.utf8))
                                .map { String(format: "%02x", $0) }
                                .joined()
                        } onCompletion: { result in
                            let nonce = appleSignInNonce
                            appleSignInNonce = ""
                            Task { await model.signInWithApple(result, nonce: nonce) }
                        }
                        .signInWithAppleButtonStyle(.black)
                        .frame(maxWidth: 280, minHeight: 42, maxHeight: 42)
                        .accessibilityLabel("Sign in with Apple")
                    }
                }

                    case .personalization:
                Section("Personalization") {
                    TextField(
                        "About you",
                        text: $model.aboutYou,
                        axis: .vertical
                    )
                    .lineLimit(3...8)
                    Text("Used only when “Prioritize for me” is enabled.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack {
                        Spacer()
                        Button("Save") {
                            model.savePersonalizationSettings()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }

                    case .topics:
                if model.canEdit {
                    Section("Topics") {
                        Text("One reusable topic per line, written as “id: Title”.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextEditor(text: $model.topicsText)
                            .font(.system(.body, design: .monospaced))
                            .frame(minHeight: 110)
                        HStack {
                            Spacer()
                            Button("Save topics") {
                                Task { await model.saveTopics() }
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                } else {
                    ContentUnavailableView(
                        "Topics need a library",
                        systemImage: "folder",
                        description: Text("Open a Briefly library to edit topics.")
                    )
                }

                    case .ai:
                Section("AI processing") {
                    #if os(macOS)
                    Toggle(
                        "Use Briefly AI",
                        isOn: Binding(
                            get: { model.usesManagedAI },
                            set: model.useManagedAI
                        )
                    )
                    if !model.usesManagedAI {
                        Menu("Choose processing preset") {
                            Button("Codex") {
                                model.processingCommand =
                                    defaultProcessingCommand
                            }
                            Button("Claude") {
                                model.processingCommand =
                                    #"claude -p --tools "" --strict-mcp-config --no-session-persistence"#
                            }
                            Button("Pi") {
                                model.processingCommand =
                                    "pi -p --no-tools --no-session --no-context-files --no-extensions --no-skills"
                            }
                            Button("OpenCode") {
                                model.processingCommand =
                                    #"opencode run --pure "$(cat)""#
                            }
                        }
                        TextField(
                            "Command",
                            text: $model.processingCommand,
                            axis: .vertical
                        )
                        .lineLimit(2...5)
                    } else {
                        Text(
                            "Briefly AI via OpenRouter, covered by a zero-data-retention agreement."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    #else
                    Label("Briefly AI", systemImage: "sparkles")
                    Text(
                        "Briefly AI via OpenRouter, covered by a zero-data-retention agreement."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    #endif
                    TextEditor(text: $model.processingPrompt)
                        .font(.system(.caption, design: .monospaced))
                        .frame(minHeight: 150)
                    HStack {
                        Button("Restore default prompt") {
                            model.processingPrompt = defaultProcessingPrompt
                        }
                        #if os(macOS)
                        Button {
                            Task { await model.testProcessingCommand() }
                        } label: {
                            if model.isTestingAI {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Text("Test command")
                            }
                        }
                        .disabled(model.isTestingAI)
                        #endif
                        Spacer()
                        Button("Save") {
                            model.saveProcessingSettings()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }

                    }
                }
                .formStyle(.grouped)
                .scrollContentBackground(.hidden)
                .background(.ultraThinMaterial.opacity(0.72))
                .navigationTitle((selectedSection ?? .general).title)
                #if os(iOS)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
                #endif
            }
        }
        #if os(macOS)
        .toolbar(removing: .sidebarToggle)
        .toolbar(.hidden, for: .windowToolbar)
        #endif
        #if os(macOS)
        .background(.ultraThinMaterial.opacity(0.48))
        .overlay { Rectangle().stroke(Color.primary.opacity(0.10)) }
        .onChange(of: captureShortcut) {
            captureShortcut.save()
            NotificationCenter.default.post(
                name: .brieflyCaptureShortcutChanged,
                object: nil
            )
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: .brieflyCaptureShortcutRegistrationChanged
            )
        ) { notification in
            shortcutRegistered = notification.object as? Bool ?? false
        }
        #endif
        .fileImporter(
            isPresented: $showsPDFImporter,
            allowedContentTypes: [.pdf]
        ) { result in
            switch result {
            case .success(let url):
                Task {
                    await model.capturePDF(url)
                    dismiss()
                }
            case .failure(let error):
                model.errorMessage = error.localizedDescription
            }
        }
        .sheet(isPresented: $showsChannelBrowser) {
            ChannelLoginView()
        }
        .task {
            await model.refreshAccount()
            await model.loadSubscription()
        }
    }

}
