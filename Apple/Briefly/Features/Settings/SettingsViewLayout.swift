import Foundation
import CryptoKit
import AuthenticationServices
import SwiftUI
import BrieflyCore

extension SettingsView {
    var body: some View {
        NavigationSplitView {
            #if os(iOS)
            List(selection: $selectedSection) {
                Section("General settings") {
                    settingsRow(
                        .account,
                        value: model.account.account.authenticated ? "Signed in" : "Signed out"
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
                Section {
                    BrieflyBackgroundSetting(appearance: .light)
                    BrieflyBackgroundSetting(appearance: .dark)
                } header: {
                    Text("Backgrounds")
                } footer: {
                    Text("Custom backgrounds are stored on this device and can be reset independently.")
                }

                    case .library:
                Section("Library") {
                    LabeledContent("Storage", value: "Local SQLite database")
                    LabeledContent("Status", value: model.session.status)
                    if model.lifecycle.isSyncing {
                        SyncActivityView(model: model)
                            .padding(.vertical, 4)
                    }
                    if model.session.canEdit {
                        Button {
                            Task { await model.workflows.refreshLibrary() }
                        } label: {
                            Label("Refresh library", systemImage: "arrow.clockwise")
                        }
                    }
                    Button {
                        Task { await model.workflows.sync() }
                    } label: {
                        Label(
                            model.lifecycle.isSyncing ? "Syncing…" : "Sync with iCloud",
                            systemImage: "arrow.triangle.2.circlepath"
                        )
                    }
                    .disabled(model.lifecycle.isSyncing)
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
                #else
                EmptyView()
                #endif

                    case .account:
                Section("Briefly account") {
                    LabeledContent(
                        "Status",
                        value: model.account.account.authenticated
                            ? model.account.account.email ?? "Signed in"
                            : "Signed out"
                    )
                    if model.account.account.authenticated {
                        LabeledContent(
                            "Membership",
                            value: model.account.account.entitled == true
                                ? "Active"
                                : "Needs activation"
                        )
                    }
                    HStack {
                        if model.account.account.authenticated {
                            Button("Sign out", role: .destructive) {
                                Task { await model.account.signOut() }
                            }
                        }
                        Spacer()
                        Button {
                            Task { await model.account.refreshAccount(reportErrors: true) }
                        } label: {
                            if model.account.isCheckingAccount {
                                ProgressView()
                            } else {
                                Label("Refresh", systemImage: "arrow.clockwise")
                            }
                        }
                        .disabled(model.account.isCheckingAccount)
                    }
                    if model.account.account.authenticated {
                        if model.account.account.entitled == true {
                            Link(
                                "Manage App Store subscription",
                                destination: URL(string: "https://apps.apple.com/account/subscriptions")!
                            )
                        } else {
                            Button {
                                showingSubscription = true
                            } label: {
                                Label("Explore Briefly Plus", systemImage: "sparkles")
                            }
                        }
                        Button("Restore purchases") {
                            Task { await model.account.restoreSubscription() }
                        }
                        .disabled(model.account.isPurchasingSubscription)
                        Button("Delete Briefly account", role: .destructive) {
                            showingAccountDeletionConfirmation = true
                        }
                        .disabled(model.account.isDeletingAccount)
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
                            Task { await model.account.signInWithApple(result, nonce: nonce) }
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
                        text: $model.settings.aboutYou,
                        axis: .vertical
                    )
                    .lineLimit(3...8)
                    Text("Used only when “Prioritize for me” is enabled.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack {
                        Spacer()
                        Button("Save") {
                            model.settings.savePersonalizationSettings()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }

                    case .topics:
                if model.session.canEdit {
                    Section("Topics") {
                        Text("One reusable topic per line, written as “id: Title”.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextEditor(text: $model.settings.topicsText)
                            .font(.system(.body, design: .monospaced))
                            .frame(minHeight: 110)
                        HStack {
                            Spacer()
                            Button("Save topics") {
                                Task { await model.workflows.saveTopics() }
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
                            get: { model.settings.usesManagedAI },
                            set: model.settings.useManagedAI
                        )
                    )
                    if !model.settings.usesManagedAI {
                        Menu("Choose processing preset") {
                            Button("Codex") {
                                model.settings.processingCommand =
                                    defaultProcessingCommand
                            }
                            Button("Claude") {
                                model.settings.processingCommand =
                                    #"claude -p --tools "" --strict-mcp-config --no-session-persistence"#
                            }
                            Button("Pi") {
                                model.settings.processingCommand =
                                    "pi -p --no-tools --no-session --no-context-files --no-extensions --no-skills"
                            }
                            Button("OpenCode") {
                                model.settings.processingCommand =
                                    #"opencode run --pure "$(cat)""#
                            }
                        }
                        TextField(
                            "Command",
                            text: $model.settings.processingCommand,
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
                    TextEditor(text: $model.settings.processingPrompt)
                        .font(.system(.caption, design: .monospaced))
                        .frame(minHeight: 150)
                    HStack {
                        Button("Restore default prompt") {
                            model.settings.processingPrompt = defaultProcessingPrompt
                        }
                        #if os(macOS)
                        Button {
                            Task { await model.settings.testProcessingCommand() }
                        } label: {
                            if model.settings.isTestingAI {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Text("Test command")
                            }
                        }
                        .disabled(model.settings.isTestingAI)
                        #endif
                        Spacer()
                        Button("Save") {
                            model.settings.saveProcessingSettings()
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
        #if os(iOS)
        .fullScreenCover(isPresented: $showingSubscription) {
            SubscriptionScreen(account: model.account)
        }
        #else
        .sheet(isPresented: $showingSubscription) {
            SubscriptionScreen(account: model.account)
                .frame(width: 560, height: 760)
        }
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
        .task {
            if let initialSection {
                selectedSection = initialSection
            }
            await model.account.refreshAccount()
            await model.account.loadSubscription()
        }
        .alert(
            "Delete Briefly Account?",
            isPresented: $showingAccountDeletionConfirmation
        ) {
            Button("Cancel", role: .cancel) {}
            Button("Delete Account", role: .destructive) {
                Task { await model.account.deleteAccount() }
            }
        } message: {
            Text(
                "This permanently removes your Briefly server account, public shares, " +
                    "sessions, feedback, and service usage. It does not delete your local " +
                    "or iCloud library or cancel an App Store subscription. Billing and " +
                    "content-moderation records may be retained where legally required."
            )
        }
    }

}
