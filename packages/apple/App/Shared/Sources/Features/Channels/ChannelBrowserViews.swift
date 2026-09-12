import SwiftUI
import WebKit

struct ChannelLoginView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    let onCapture: ((URL, SignedInChannelPage) async -> Void)?
    let onActivity: ((Bool) -> Void)?
    let navigationTitle: String
    @State private var address: String
    @State private var loadedURL: URL
    @State private var errorMessage = ""
    @State private var isExtracting = false
    @StateObject private var navigation = ChannelBrowserNavigation()

    init(
        initialAddress: String = "https://x.com",
        navigationTitle: String = "Signed-in browser",
        onCapture: ((URL, SignedInChannelPage) async -> Void)? = nil,
        onActivity: ((Bool) -> Void)? = nil
    ) {
        let url = validatedHTTPURL(initialAddress) ?? URL(string: "https://x.com")!
        self.onCapture = onCapture
        self.onActivity = onActivity
        self.navigationTitle = navigationTitle
        _address = State(initialValue: url.absoluteString)
        _loadedURL = State(initialValue: url)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close browser")

                Text(navigationTitle)
                    .font(.headline)

                Divider()
                    .frame(height: 22)

                Button(action: navigation.goBack) {
                    Image(systemName: "chevron.left")
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .disabled(!navigation.canGoBack)
                .accessibilityLabel("Back")

                Button(action: navigation.goForward) {
                    Image(systemName: "chevron.right")
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .disabled(!navigation.canGoForward)
                .accessibilityLabel("Forward")

                Button(action: navigation.reload) {
                    Image(systemName: "arrow.clockwise")
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Reload")

                HStack(spacing: 7) {
                    Image(systemName: "lock.fill")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    TextField("https://example.com", text: $address)
                        .textFieldStyle(.plain)
                        .autocorrectionDisabled()
                        .onSubmit(loadAddress)
                    Button(action: loadAddress) {
                        Image(systemName: "arrow.right.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Open address")
                }
                .padding(.horizontal, 11)
                .frame(height: 32)
                .background(.quaternary.opacity(0.55), in: Rectangle())
            }
            .buttonStyle(.plain)
            .controlSize(.regular)
            .padding(.horizontal, 12)
            .frame(height: 54)
            .background(.regularMaterial)
            .overlay(alignment: .bottom) { Divider() }

            ChannelWebView(url: $loadedURL, navigation: navigation) { url in
                if address != url.absoluteString {
                    address = url.absoluteString
                }
                if loadedURL != url {
                    loadedURL = url
                }
            }

            if !errorMessage.isEmpty {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(.quaternary)
            }

            if onCapture != nil {
                HStack(spacing: 10) {
                    Circle()
                        .fill(.green)
                        .frame(width: 8, height: 8)
                    Text("Session stays in Briefly")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        guard let url = validatedHTTPURL(address) else {
                            errorMessage = "Enter a valid HTTP(S) URL."
                            return
                        }
                        openURL(url)
                    } label: {
                        Label("Open in Safari", systemImage: "arrow.up.right")
                    }
                    Button {
                        Task { await savePage() }
                    } label: {
                        if isExtracting {
                            ProgressView().controlSize(.small)
                        } else {
                            Label("Save to Briefly", systemImage: "square.and.arrow.down")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.roundedRectangle(radius: 0))
                    .disabled(isExtracting)
                }
                .padding(.horizontal, 14)
                .frame(height: 58)
                .background(.regularMaterial)
                .overlay(alignment: .top) { Divider() }
            }
        }
        #if os(macOS)
        .frame(minWidth: 820, minHeight: 620)
        #endif
        .accessibilityLabel(navigationTitle)
    }

    private func loadAddress() {
        guard let url = validatedHTTPURL(address) else {
            errorMessage = "Enter a valid HTTP(S) URL."
            return
        }
        errorMessage = ""
        loadedURL = url
    }

    private func savePage() async {
        guard let url = validatedHTTPURL(address) else {
            errorMessage = "Enter a valid HTTP(S) URL."
            return
        }
        isExtracting = true
        onActivity?(true)
        defer {
            isExtracting = false
            onActivity?(false)
        }
        do {
            let page = try await ChannelBrowserSession.shared.extractPage(from: url)
            await onCapture?(url, page)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

#if os(macOS)
struct ChannelPreview: View {
    @State private var loadedURL: URL
    @StateObject private var navigation = ChannelBrowserNavigation()

    init(source: String) {
        _loadedURL = State(
            initialValue: validatedHTTPURL(source) ?? URL(string: "about:blank")!
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Circle().fill(.red.opacity(0.8))
                    Circle().fill(.yellow.opacity(0.8))
                    Circle().fill(.green.opacity(0.8))
                }
                .frame(width: 48)
                .accessibilityHidden(true)

                Button(action: navigation.goBack) {
                    Image(systemName: "chevron.left")
                }
                .disabled(!navigation.canGoBack)
                .accessibilityLabel("Back")

                Button(action: navigation.goForward) {
                    Image(systemName: "chevron.right")
                }
                .disabled(!navigation.canGoForward)
                .accessibilityLabel("Forward")

                Button(action: navigation.reload) {
                    Image(systemName: "arrow.clockwise")
                }
                .accessibilityLabel("Reload")

                HStack(spacing: 7) {
                    Image(systemName: "globe")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(loadedURL.absoluteString)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .font(.callout)
                .padding(.horizontal, 11)
                .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
                .background(.quaternary.opacity(0.55))
                .clipShape(Rectangle())

                Link(destination: loadedURL) {
                    Image(systemName: "arrow.up.right")
                }
                .accessibilityLabel("Open in default browser")
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .frame(height: 48)
            .background(.bar)
            .overlay(alignment: .bottom) { Divider() }

            ChannelWebView(url: $loadedURL, navigation: navigation) { url in
                if loadedURL != url { loadedURL = url }
            }
        }
        .clipShape(Rectangle())
        .overlay {
            Rectangle()
                .stroke(.separator, lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.08), radius: 16, y: 8)
    }
}
#endif
