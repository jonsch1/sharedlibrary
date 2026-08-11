import AuthenticationServices
import CryptoKit
import StoreKit
import SwiftUI

struct SubscriptionScreen: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss
    @Bindable var account: LibraryAccountModel
    var dismissesWhenEntitled = true
    var previewPrice: String? = nil
    var previewAuthenticated = false
    var allowsDismissal = true

    @State private var appleSignInNonce = ""
    @State private var showingAppReviewAccess = false

    private let privacyURL = URL(string: "https://www.readbriefly.fyi/privacy")!
    private let termsURL = URL(string: "https://www.readbriefly.fyi/terms")!

    var body: some View {
        ZStack {
            BrieflyAtmosphere()
                .ignoresSafeArea()

            ScrollView {
                VStack(spacing: 0) {
                    header
                    SubscriptionHeroArtwork()
                        .padding(.top, 16)
                    introduction
                        .padding(.top, 20)
                    benefits
                        .padding(.top, 30)
                    planCard
                        .padding(.top, 28)
                    purchaseDisclosure
                        .padding(.top, 18)
                    footerLinks
                        .padding(.top, 14)
                        .padding(.bottom, 30)
                }
                .padding(.horizontal, 24)
                .frame(maxWidth: 590)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.hidden)
        }
        .safeAreaInset(edge: .bottom) {
            purchaseBar
        }
        .task {
            if previewPrice == nil, account.subscriptionProduct == nil {
                await account.loadSubscription()
            }
        }
        .onChange(of: account.account.entitled) { _, entitled in
            if dismissesWhenEntitled, entitled == true { dismiss() }
        }
        .sheet(isPresented: $showingAppReviewAccess) {
            AppReviewAccessSheet(account: account)
        }
    }

    private var header: some View {
        ZStack {
            BrieflyLogo()

            HStack {
                Spacer()
                if allowsDismissal {
                    Button(action: dismiss.callAsFunction) {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .bold))
                            .frame(width: 36, height: 36)
                            .background(Color.primary.opacity(0.07), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Close")
                }
            }
        }
        .frame(maxWidth: .infinity)
        #if os(iOS)
        .padding(.horizontal, 10)
        .frame(height: 58)
        .padding(.top, 8)
        #else
        .padding(.top, 14)
        #endif
    }

    private var introduction: some View {
        VStack(spacing: 11) {
            Text("Make space for what matters.")
                .font(.system(.largeTitle, design: .rounded, weight: .bold))
                .multilineTextAlignment(.center)

            Text(
                "Briefly Plus handles the heavy reading. Save anything, get the point " +
                    "first, and go deeper only when it is worth your time."
            )
            .font(.body)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .lineSpacing(3)
            .frame(maxWidth: 470)
        }
    }

    private var benefits: some View {
        VStack(spacing: 18) {
            SubscriptionBenefit(
                symbol: "text.document.fill",
                title: "Clear at every depth",
                detail: "Start brief, then expand from concise to comprehensive."
            )
            SubscriptionBenefit(
                symbol: "headphones",
                title: "Listen instead of scroll",
                detail: "Turn briefs into audio and keep moving."
            )
            SubscriptionBenefit(
                symbol: "sparkles",
                title: "The hard work, handled",
                detail: "Hosted AI, transcription, web extraction, and sharing are included."
            )
        }
    }

    private var planCard: some View {
        HStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(Color.accentColor)

            VStack(alignment: .leading, spacing: 3) {
                Text("Monthly membership")
                    .font(.headline)
                Text("Renews monthly · Cancel anytime")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)

            if let displayedPrice {
                VStack(alignment: .trailing, spacing: 1) {
                    Text(displayedPrice)
                        .font(.title3.weight(.bold))
                    Text("per month")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if account.isLoadingSubscription {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Loading App Store price")
            } else {
                VStack(alignment: .trailing, spacing: 3) {
                    Text("Price unavailable")
                        .font(.caption.weight(.semibold))
                    Button("Try again") {
                        Task { await account.loadSubscription() }
                    }
                    .font(.caption2)
                }
                .foregroundStyle(.secondary)
            }
        }
        .padding(18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.accentColor.opacity(0.65), lineWidth: 1.5)
        }
    }

    private var purchaseDisclosure: some View {
        Text(
            "Payment is charged to your Apple Account. Your subscription renews " +
                "automatically each month until canceled in App Store settings."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .lineSpacing(2)
        .frame(maxWidth: 470)
    }

    private var footerLinks: some View {
        HStack(spacing: 17) {
            if isAuthenticated {
                Button("Restore purchases") {
                    Task { await account.restoreSubscription() }
                }
                .disabled(account.isPurchasingSubscription)
            }

            Link("Terms", destination: termsURL)
            Link("Privacy", destination: privacyURL)
        }
        .font(.caption.weight(.medium))
    }

    private var purchaseBar: some View {
        VStack(spacing: 8) {
            if isAuthenticated {
                Button {
                    Task { await account.purchaseSubscription() }
                } label: {
                    HStack(spacing: 9) {
                        if account.isPurchasingSubscription {
                            ProgressView()
                                .tint(.white)
                        }
                        Text(purchaseButtonTitle)
                            .font(.headline)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 28)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .controlSize(.large)
                .disabled(displayedPrice == nil || account.isPurchasingSubscription)

                if displayedPrice == nil {
                    Button("Try loading the App Store price again") {
                        Task { await account.loadSubscription() }
                    }
                    .font(.caption)
                    .disabled(account.isPurchasingSubscription)
                }
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
                    Task { await account.signInWithApple(result, nonce: nonce) }
                }
                .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
                .frame(maxWidth: .infinity, minHeight: 50, maxHeight: 50)

                Text("Sign in to restore an existing membership or continue to subscribe.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                Button {
                    showingAppReviewAccess = true
                } label: {
                    Text("App Review access")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 12)
        .padding(.bottom, 10)
        .frame(maxWidth: 590)
        .frame(maxWidth: .infinity)
        #if os(macOS)
        .background(Color.clear)
        #else
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) { Divider().opacity(0.45) }
        #endif
    }

    private var purchaseButtonTitle: String {
        guard let displayedPrice else {
            return account.isLoadingSubscription
                ? "Loading subscription…"
                : "Subscription unavailable"
        }
        return "Subscribe for \(displayedPrice) / month"
    }

    private var displayedPrice: String? {
        account.subscriptionProduct?.displayPrice ?? previewPrice
    }

    private var isAuthenticated: Bool {
        account.account.authenticated || previewAuthenticated
    }
}

private struct AppReviewAccessSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var account: LibraryAccountModel

    @State private var username = ""
    @State private var password = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Username", text: $username)
                        .textContentType(.username)
                        .autocorrectionDisabled()
                    SecureField("Password", text: $password)
                        .textContentType(.password)
                } header: {
                    Text("Reviewer credentials")
                } footer: {
                    Text(
                        "This access is reserved for App Review and does not change " +
                            "the Apple Account on this device."
                    )
                }

                Section {
                    Button {
                        Task {
                            await account.signInForAppReview(
                                username: username,
                                password: password
                            )
                            if account.account.entitled == true { dismiss() }
                        }
                    } label: {
                        HStack {
                            Spacer()
                            if account.isSigningInForReview {
                                ProgressView()
                            } else {
                                Text("Continue")
                            }
                            Spacer()
                        }
                    }
                    .disabled(
                        username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                            password.isEmpty ||
                            account.isSigningInForReview
                    )
                }
            }
            .navigationTitle("App Review Access")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: dismiss.callAsFunction)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 300)
        #endif
    }
}

private struct SubscriptionBenefit: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 42, height: 42)
                .background(Color.accentColor.opacity(0.12), in: Circle())

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct SubscriptionHeroArtwork: View {
    var body: some View {
        ZStack {
            heroCard
                .opacity(0.45)
                .rotationEffect(.degrees(-8))
                .offset(x: -20, y: 6)
            heroCard
                .opacity(0.68)
                .rotationEffect(.degrees(7))
                .offset(x: 20, y: 3)
            heroCard
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: "waveform")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background(Color.accentColor, in: Circle())
                        .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
                        .offset(x: 10, y: 10)
                }
        }
        .frame(height: 172)
        .accessibilityHidden(true)
    }

    private var heroCard: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack {
                Image(systemName: "bookmark.fill")
                    .foregroundStyle(Color.accentColor)
                Spacer()
                Text("BRIEF")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                    .tracking(1.2)
            }
            RoundedRectangle(cornerRadius: 3)
                .frame(width: 176, height: 9)
            RoundedRectangle(cornerRadius: 3)
                .fill(.secondary.opacity(0.35))
                .frame(width: 214, height: 7)
            RoundedRectangle(cornerRadius: 3)
                .fill(.secondary.opacity(0.25))
                .frame(width: 186, height: 7)
            RoundedRectangle(cornerRadius: 3)
                .fill(.secondary.opacity(0.20))
                .frame(width: 138, height: 7)
        }
        .foregroundStyle(.primary.opacity(0.82))
        .padding(20)
        .frame(width: 278, height: 142, alignment: .topLeading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(.primary.opacity(0.10))
        }
        .shadow(color: .black.opacity(0.12), radius: 14, y: 7)
    }
}
