import Foundation
import CryptoKit
import AuthenticationServices
import SwiftUI
import BrieflyCore

/// The body of one settings section, shared by the Mac workspace and the iOS settings screen.
struct SettingsSectionContent: View {
    let section: BrieflySettingsSection
    @Bindable var model: LibraryModel

    var body: some View {
        VStack(alignment: .leading, spacing: 32) {
            switch section {
            case .general: AppearanceSettings()
            case .library: LibrarySyncSettings(model: model)
            case .account: AccountSettings(model: model)
            case .topics: TopicSettings(model: model)
            case .capture:
                #if os(macOS)
                CaptureSettings()
                #endif
            case .ai:
                #if os(macOS)
                AIProcessingSettingsView(settings: model.settings)
                #endif
            case .agents:
                #if os(macOS)
                AgentConnectionSettings(model: model)
                #endif
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .buttonBorderShape(.roundedRectangle(radius: 0))
    }
}

private struct AppearanceSettings: View {
    @AppStorage("BrieflyAppearance") private var appearance = "system"

    var body: some View {
        SettingsGroup(title: "Theme") {
            HStack(spacing: 8) {
                ForEach([("System", "system"), ("Light", "light"), ("Dark", "dark")], id: \.1) { title, value in
                    ChoiceChip(title: title, isSelected: appearance == value, fillsWidth: true) {
                        appearance = value
                    }
                }
            }
            .frame(maxWidth: 360)
        }

        SettingsGroup(
            title: "Background",
            footer: "Custom backgrounds are stored on this device only."
        ) {
            VStack(alignment: .leading, spacing: 20) {
                BrieflyBackgroundSetting(appearance: .light)
                BrieflyBackgroundSetting(appearance: .dark)
            }
        }
    }
}

private struct LibrarySyncSettings: View {
    @Bindable var model: LibraryModel

    var body: some View {
        SettingsGroup(title: "Sync", footer: syncFooter) {
            VStack(alignment: .leading, spacing: 4) {
                if model.lifecycle.isSyncing {
                    SyncActivityView(model: model)
                        .padding(.vertical, 6)
                } else {
                    SettingsActionRow(
                        icon: model.lifecycle.syncError == nil ? "arrow.triangle.2.circlepath" : "icloud.slash",
                        title: "Sync now",
                        subtitle: model.lifecycle.syncError ?? "Briefly also syncs automatically when you open it."
                    ) {
                        Task { await model.workflows.sync() }
                    }
                }
                if model.session.canEdit {
                    SettingsActionRow(
                        icon: "arrow.clockwise",
                        title: "Reload library",
                        subtitle: "Read all items again from this device’s storage."
                    ) {
                        Task { await model.workflows.refreshLibrary() }
                    }
                }
                #if os(iOS)
                SettingsActionRow(
                    icon: "square.and.arrow.down",
                    title: "Retry shared items",
                    subtitle: "Import items from the share sheet that didn’t finish."
                ) {
                    Task { await model.workflows.importPendingSharedCaptures(retryFailed: true) }
                }
                .disabled(model.isProcessing || !model.session.canEdit)
                #endif
            }
        }

        SettingsGroup(title: "Export") {
            LibraryExportControls(model: model)
        }
    }

    private var syncFooter: String? {
        #if os(iOS)
        "Summaries are created by Briefly on your Mac and arrive here through iCloud."
        #else
        nil
        #endif
    }
}

private struct AccountSettings: View {
    @Bindable var model: LibraryModel
    @Environment(\.colorScheme) private var colorScheme
    @State private var appleSignInNonce = ""
    @State private var confirmsDeletion = false

    private var account: BrieflyAccountStatus { model.account.account }

    var body: some View {
        if account.authenticated {
            SettingsGroup(title: "Briefly account") {
                SettingsRow(
                    icon: "person.crop.circle.fill",
                    title: account.email ?? "Signed in",
                    subtitle: "Signed in with Apple. Your share links are tied to this account."
                ) {
                    if model.account.isCheckingAccount {
                        ProgressView().controlSize(.small)
                    }
                }
                SettingsActionRow(icon: "rectangle.portrait.and.arrow.right", title: "Sign out") {
                    Task { await model.account.signOut() }
                }
            }

            SettingsGroup(
                title: "Delete account",
                footer: "Removes your Briefly server account, public share links, and feedback. Your library on this device and in iCloud stays."
            ) {
                SettingsActionRow(
                    icon: "trash",
                    title: "Delete Briefly account…",
                    role: .destructive,
                    isWorking: model.account.isDeletingAccount
                ) {
                    confirmsDeletion = true
                }
                .disabled(model.account.isDeletingAccount)
            }
            .alert("Delete Briefly Account?", isPresented: $confirmsDeletion) {
                Button("Cancel", role: .cancel) {}
                Button("Delete Account", role: .destructive) {
                    Task { await model.account.deleteAccount() }
                }
            } message: {
                Text(
                    "This permanently removes your Briefly server account, public shares, " +
                        "sessions, feedback, and service usage. It does not delete your local " +
                        "or iCloud library. Content-moderation records may be retained where " +
                        "legally required."
                )
            }
        } else {
            SettingsGroup(
                title: "Briefly account",
                footer: "An account is only needed for public share links. Your library stays on your devices and in iCloud either way."
            ) {
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
                .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
                .frame(maxWidth: 300)
                .frame(height: 44)
                .accessibilityLabel("Sign in with Apple")
            }
        }
    }
}

private struct TopicSettings: View {
    @Bindable var model: LibraryModel

    var body: some View {
        if model.session.canEdit {
            SettingsGroup(title: nil) {
                Text("Write one topic per line as “id: Title”. Removing a topic keeps its items in your library.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                TextEditor(text: $model.settings.topicsText)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    .frame(minHeight: 220)
                    .padding(.vertical, 8)
                    .settingsField()
                    .accessibilityLabel("Topics")
                HStack {
                    Spacer()
                    Button("Save topics") {
                        Task { await model.workflows.saveTopics() }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        } else {
            SettingsGroup(title: nil) {
                Text("Topics can be edited once your library has loaded.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

#if os(macOS)
private struct CaptureSettings: View {
    @State private var shortcut = CaptureShortcut.load()
    @State private var registered = UserDefaults.standard.bool(
        forKey: "BrieflyCaptureShortcutRegistered"
    )

    var body: some View {
        SettingsGroup(title: "Shortcut") {
            SettingsRow(
                icon: "keyboard",
                title: "Capture from anywhere",
                subtitle: registered
                    ? "Click the shortcut, then press a new combination."
                    : "This shortcut is unavailable. Choose another combination.",
                tint: registered ? .primary : .red
            ) {
                ShortcutRecorder(shortcut: $shortcut)
                    .frame(width: 140, height: 32)
                    .background(Color.primary.opacity(0.055), in: Rectangle())
                if shortcut != .defaultValue {
                    Button("Reset") { shortcut = .defaultValue }
                        .buttonStyle(.borderless)
                }
            }
        }
        .onChange(of: shortcut) {
            shortcut.save()
            NotificationCenter.default.post(name: .brieflyCaptureShortcutChanged, object: nil)
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .brieflyCaptureShortcutRegistrationChanged)
        ) { notification in
            registered = notification.object as? Bool ?? false
        }
    }
}
#endif
