import Foundation
import CryptoKit
import AuthenticationServices
import SwiftUI
import BrieflyCore

#if os(macOS)
struct MacXSettingsWorkspace: View {
    @AppStorage("BrieflyAppearance") private var appearance = "system"
    @Bindable var model: LibraryModel
    @State private var selectedSection = BrieflySettingsSection.general
    @State private var query = ""
    @State private var captureShortcut = CaptureShortcut.load()
    @State private var shortcutRegistered = UserDefaults.standard.bool(
        forKey: "BrieflyCaptureShortcutRegistered"
    )
    @State private var appleSignInNonce = ""
    @State private var showingAccountDeletionConfirmation = false
    @State private var showingSubscription = false

    private var filteredSections: [BrieflySettingsSection] {
        guard !query.isEmpty else { return BrieflySettingsSection.allCases }
        return BrieflySettingsSection.allCases.filter {
            $0.title.localizedCaseInsensitiveContains(query) ||
                subtitle(for: $0).localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            settingsIndex
                .frame(width: 390)

            settingsDetail
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
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
        .task {
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
        .sheet(isPresented: $showingSubscription) {
            SubscriptionScreen(account: model.account)
                .frame(width: 560, height: 760)
        }
    }

    private var settingsIndex: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Settings")
                .font(.title2.weight(.bold))
                .padding(.horizontal, 18)
                .padding(.top, 17)
                .padding(.bottom, 14)

            HStack(spacing: 9) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search Settings", text: $query)
                    .textFieldStyle(.plain)
                if !query.isEmpty {
                    Button { query = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 13)
            .frame(height: 40)
            .background(Color.primary.opacity(0.055), in: Capsule())
            .overlay { Capsule().stroke(Color.primary.opacity(0.09)) }
            .padding(.horizontal, 14)
            .padding(.bottom, 10)

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(filteredSections) { section in
                        Button { selectedSection = section } label: {
                            HStack(spacing: 12) {
                                Image(systemName: section.icon)
                                    .frame(width: 22)
                                    .foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(section.title)
                                        .font(.callout.weight(.medium))
                                    Text(subtitle(for: section))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.horizontal, 16)
                            .frame(minHeight: 55)
                            .background(
                                selectedSection == section
                                    ? Color.primary.opacity(0.055)
                                    : .clear
                            )
                            .overlay(alignment: .trailing) {
                                Rectangle()
                                    .fill(selectedSection == section ? Color.accentColor : .clear)
                                    .frame(width: 3)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }

                    Divider().padding(.vertical, 8)
                    indexLink("Feedback", icon: "bubble.left.and.bubble.right", url: "https://www.readbriefly.fyi/feedback")
                    indexLink("Privacy Policy", icon: "hand.raised", url: "https://www.readbriefly.fyi/privacy")
                    indexLink("Terms of Use", icon: "doc.text", url: "https://www.readbriefly.fyi/terms")
                }
            }
        }
        .background(.ultraThinMaterial.opacity(0.42))
        .overlay(alignment: .trailing) { Divider() }
    }

    private var settingsDetail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(selectedSection.title)
                        .font(.title2.weight(.bold))
                    Text(detailSubtitle(for: selectedSection))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 14)

                Divider()
                detailContent
            }
        }
        .scrollIndicators(.hidden)
    }

    @ViewBuilder
    private var detailContent: some View {
        switch selectedSection {
        case .general:
            detailGroup("Display") {
                detailRow(icon: "circle.lefthalf.filled", title: "Appearance", subtitle: "Choose how Briefly looks on this Mac") {
                    Picker("", selection: $appearance) {
                        Text("System").tag("system")
                        Text("Light").tag("light")
                        Text("Dark").tag("dark")
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 210)
                }
            }
            detailGroup("Backgrounds") {
                BrieflyBackgroundSetting(appearance: .light)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 14)
                Divider().padding(.leading, 20)
                BrieflyBackgroundSetting(appearance: .dark)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 14)
                Text("Custom backgrounds are stored on this Mac and can be reset independently.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 18)
            }

        case .library:
            detailGroup("Library") {
                valueRow(icon: "internaldrive", title: "Storage", value: "Local SQLite database")
                valueRow(icon: "checkmark.circle", title: "Status", value: model.session.status)
                actionRow(icon: "arrow.clockwise", title: "Refresh library", subtitle: "Reload all saved notes from local storage") {
                    Task { await model.workflows.refreshLibrary() }
                }
                actionRow(icon: "arrow.triangle.2.circlepath", title: model.lifecycle.isSyncing ? "Syncing…" : "Sync with iCloud", subtitle: "Push and pull the latest library changes") {
                    Task { await model.workflows.sync() }
                }
                .disabled(model.lifecycle.isSyncing)
            }

        case .capture:
            detailGroup("Shortcut") {
                detailRow(icon: "keyboard", title: "Global shortcut", subtitle: shortcutRegistered ? "Active system-wide" : "Choose another shortcut") {
                    ShortcutRecorder(shortcut: $captureShortcut)
                        .frame(width: 150, height: 30)
                }
            }

        case .account:
            detailGroup("Your account") {
                valueRow(icon: "person.crop.circle", title: "Account", value: model.account.account.authenticated ? model.account.account.email ?? "Signed in" : "Signed out")
                if model.account.account.authenticated {
                    valueRow(icon: "checkmark.seal", title: "Membership", value: model.account.account.entitled == true ? "Active" : "Needs activation")
                    actionRow(icon: "arrow.clockwise", title: "Refresh account", subtitle: "Check membership and subscription status") {
                        Task { await model.account.refreshAccount(reportErrors: true) }
                    }
                    if model.account.account.entitled == true {
                        externalDetailRow(icon: "creditcard", title: "Manage App Store subscription", url: "https://apps.apple.com/account/subscriptions")
                    } else {
                        actionRow(icon: "sparkles", title: "Explore Briefly Plus", subtitle: "See membership benefits and pricing") {
                            showingSubscription = true
                        }
                    }
                    actionRow(icon: "arrow.counterclockwise", title: "Restore purchases", subtitle: "Restore an existing App Store subscription") {
                        Task { await model.account.restoreSubscription() }
                    }
                    actionRow(icon: "rectangle.portrait.and.arrow.right", title: "Sign out", subtitle: "Remove this account from the Mac", destructive: true) {
                        Task { await model.account.signOut() }
                    }
                    actionRow(icon: "trash", title: "Delete Briefly account", subtitle: "Permanently delete server account data", destructive: true) {
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
                    .frame(width: 260, height: 42)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 16)
                }
            }

        case .personalization:
            editorGroup(
                title: "Personalization",
                description: "Context used when Prioritize for me is enabled.",
                firstTitle: "About you",
                firstText: $model.settings.aboutYou,
                save: model.settings.savePersonalizationSettings
            )

        case .topics:
            detailGroup("Topics") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("One reusable topic per line, written as “id: Title”.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextEditor(text: $model.settings.topicsText)
                        .font(.system(.body, design: .monospaced))
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 220)
                        .padding(10)
                        .background(Color.primary.opacity(0.04))
                        .overlay { Rectangle().stroke(Color.primary.opacity(0.10)) }
                    HStack {
                        Spacer()
                        Button("Save topics") { Task { await model.workflows.saveTopics() } }
                            .buttonStyle(.borderedProminent)
                            .buttonBorderShape(.capsule)
                    }
                }
                .padding(20)
            }

        case .ai:
            detailGroup("AI processing") {
                detailRow(icon: "sparkles", title: "Use Briefly AI", subtitle: "Managed processing with zero-data retention") {
                    Toggle("", isOn: Binding(get: { model.settings.usesManagedAI }, set: model.settings.useManagedAI))
                        .labelsHidden()
                }
                if !model.settings.usesManagedAI {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Processing command")
                            .font(.callout.weight(.semibold))
                        TextField("Command", text: $model.settings.processingCommand, axis: .vertical)
                            .textFieldStyle(.plain)
                            .padding(11)
                            .background(Color.primary.opacity(0.04))
                            .overlay { Rectangle().stroke(Color.primary.opacity(0.10)) }
                    }
                    .padding(20)
                    Divider().padding(.leading, 58)
                }
                VStack(alignment: .leading, spacing: 10) {
                    Text("Processing prompt")
                        .font(.callout.weight(.semibold))
                    TextEditor(text: $model.settings.processingPrompt)
                        .font(.system(.caption, design: .monospaced))
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 230)
                        .padding(10)
                        .background(Color.primary.opacity(0.04))
                        .overlay { Rectangle().stroke(Color.primary.opacity(0.10)) }
                    HStack {
                        Button("Restore default") { model.settings.processingPrompt = defaultProcessingPrompt }
                        Button("Test") { Task { await model.settings.testProcessingCommand() } }
                            .disabled(model.settings.isTestingAI)
                        Spacer()
                        Button("Save") { model.settings.saveProcessingSettings() }
                            .buttonStyle(.borderedProminent)
                            .buttonBorderShape(.capsule)
                    }
                }
                .padding(20)
            }
        }
    }

    private func detailGroup<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.headline)
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 10)
            content()
        }
    }

    private func detailRow<Trailing: View>(
        icon: String,
        title: String,
        subtitle: String,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(spacing: 13) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.callout.weight(.medium))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            trailing()
        }
        .padding(.horizontal, 20)
        .frame(minHeight: 62)
        .overlay(alignment: .bottom) { Divider().padding(.leading, 57) }
    }

    private func valueRow(icon: String, title: String, value: String) -> some View {
        detailRow(icon: icon, title: title, subtitle: value) {
            Image(systemName: "chevron.right")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.tertiary)
        }
    }

    private func actionRow(
        icon: String,
        title: String,
        subtitle: String,
        destructive: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 13) {
                Image(systemName: icon)
                    .foregroundStyle(destructive ? Color.red : Color.secondary)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(destructive ? Color.red : Color.primary)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 20)
            .frame(minHeight: 62)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .bottom) { Divider().padding(.leading, 57) }
    }

    private func externalDetailRow(icon: String, title: String, url: String) -> some View {
        Link(destination: URL(string: url)!) {
            HStack(spacing: 13) {
                Image(systemName: icon).foregroundStyle(.secondary).frame(width: 24)
                Text(title).font(.callout.weight(.medium))
                Spacer()
                Image(systemName: "arrow.up.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 20)
            .frame(minHeight: 62)
        }
        .foregroundStyle(.primary)
        .overlay(alignment: .bottom) { Divider().padding(.leading, 57) }
    }

    private func editorGroup(
        title: String,
        description: String,
        firstTitle: String,
        firstText: Binding<String>,
        save: @escaping () -> Void
    ) -> some View {
        detailGroup(title) {
            VStack(alignment: .leading, spacing: 12) {
                Text(description).font(.caption).foregroundStyle(.secondary)
                Text(firstTitle).font(.callout.weight(.semibold))
                TextField(firstTitle, text: firstText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(3...7)
                    .padding(11)
                    .background(Color.primary.opacity(0.04))
                    .overlay { Rectangle().stroke(Color.primary.opacity(0.10)) }
                HStack {
                    Spacer()
                    Button("Save", action: save)
                        .buttonStyle(.borderedProminent)
                        .buttonBorderShape(.capsule)
                }
            }
            .padding(20)
        }
    }

    private func indexLink(_ title: String, icon: String, url: String) -> some View {
        Link(destination: URL(string: url)!) {
            HStack(spacing: 12) {
                Image(systemName: icon).frame(width: 22).foregroundStyle(.secondary)
                Text(title).font(.callout.weight(.medium))
                Spacer()
                Image(systemName: "arrow.up.right")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 46)
        }
        .foregroundStyle(.primary)
    }

    private func subtitle(for section: BrieflySettingsSection) -> String {
        switch section {
        case .general: "Color scheme and display"
        case .library: "Storage, refresh, and iCloud"
        case .capture: "System-wide keyboard shortcut"
        case .account: "Sign-in and subscription"
        case .personalization: "Your context"
        case .topics: "Reusable library topics"
        case .ai: "Provider, command, and prompt"
        }
    }

    private func detailSubtitle(for section: BrieflySettingsSection) -> String {
        switch section {
        case .general: "Manage how Briefly content is displayed to you."
        case .library: "Manage local storage, refresh, and synchronization."
        case .capture: "Choose the keyboard shortcut used to capture from anywhere."
        case .account: "See account information and manage your membership."
        case .personalization: "Tell Briefly what matters to you."
        case .topics: "Manage the reusable topics applied to saved notes."
        case .ai: "Choose how Briefly processes and summarizes content."
        }
    }
}
#endif
