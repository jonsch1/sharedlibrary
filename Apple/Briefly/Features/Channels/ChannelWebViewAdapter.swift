import SwiftUI
import WebKit

@MainActor
struct ChannelWebView {
    @Binding var url: URL
    let navigation: ChannelBrowserNavigation
    let onNavigate: (URL) -> Void
    let session = ChannelBrowserSession.shared

    func makeView(coordinator: Coordinator) -> WKWebView {
        let view = session.makeWebView()
        view.uiDelegate = coordinator
        view.navigationDelegate = coordinator
        coordinator.onNavigate = onNavigate
        coordinator.requestedURL = url
        coordinator.navigation = navigation
        navigation.update(from: view)
        view.load(URLRequest(url: url))
        return view
    }

    func updateView(_ view: WKWebView, coordinator: Coordinator) {
        coordinator.onNavigate = onNavigate
        coordinator.navigation = navigation
        if coordinator.requestedURL != url {
            coordinator.requestedURL = url
            view.load(URLRequest(url: url))
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator: NSObject, WKUIDelegate, WKNavigationDelegate {
        var requestedURL: URL?
        var onNavigate: (URL) -> Void = { _ in }
        weak var navigation: ChannelBrowserNavigation?

        func webView(_ webView: WKWebView, didStartProvisionalNavigation: WKNavigation!) {
            navigation?.update(from: webView)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            self.navigation?.update(from: webView)
            guard let url = webView.url else { return }
            requestedURL = url
            onNavigate(url)
        }

        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            if navigationAction.targetFrame == nil {
                webView.load(navigationAction.request)
            }
            return nil
        }
    }
}

#if os(macOS)
extension ChannelWebView: NSViewRepresentable {
    func makeNSView(context: Context) -> WKWebView {
        makeView(coordinator: context.coordinator)
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        updateView(nsView, coordinator: context.coordinator)
    }
}
#else
extension ChannelWebView: UIViewRepresentable {
    func makeUIView(context: Context) -> WKWebView {
        makeView(coordinator: context.coordinator)
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        updateView(uiView, coordinator: context.coordinator)
    }
}
#endif

@MainActor
final class NavigationWaiter: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Void, Error>?
    private var timeout: DispatchWorkItem?

    func load(_ url: URL, in webView: WKWebView) async throws {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let timeout = DispatchWorkItem { [weak self, weak webView] in
                webView?.stopLoading()
                self?.finish(.failure(ChannelBrowserError.timeout))
            }
            self.timeout = timeout
            DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: timeout)
            webView.load(URLRequest(url: url))
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finish(.success(()))
    }

    func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: Error
    ) {
        finish(.failure(error))
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        finish(.failure(error))
    }

    private func finish(_ result: Result<Void, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        timeout?.cancel()
        timeout = nil
        continuation.resume(with: result)
    }
}

enum ChannelBrowserError: LocalizedError {
    case emptyPage
    case timeout
    case youtubeUnavailable

    var errorDescription: String? {
        switch self {
        case .emptyPage:
            "The signed-in browser returned no readable text."
        case .timeout:
            "The signed-in browser took too long to load this page."
        case .youtubeUnavailable:
            "YouTube did not expose readable video details."
        }
    }
}
