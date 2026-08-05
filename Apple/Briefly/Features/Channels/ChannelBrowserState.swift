import Combine
import Foundation
import WebKit

@MainActor
final class ChannelBrowserNavigation: ObservableObject {
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false
    weak var webView: WKWebView?

    func update(from webView: WKWebView) {
        self.webView = webView
        if canGoBack != webView.canGoBack { canGoBack = webView.canGoBack }
        if canGoForward != webView.canGoForward { canGoForward = webView.canGoForward }
    }

    func goBack() { webView?.goBack() }
    func goForward() { webView?.goForward() }
    func reload() { webView?.reload() }
}

func faviconFileExtension(_ data: Data) -> String? {
    let bytes = [UInt8](data.prefix(12))
    if bytes.starts(with: [0x89, 0x50, 0x4e, 0x47]) { return "png" }
    if bytes.starts(with: [0xff, 0xd8, 0xff]) { return "jpg" }
    if bytes.starts(with: Array("GIF8".utf8)) { return "gif" }
    if bytes.starts(with: [0x00, 0x00, 0x01, 0x00]) { return "ico" }
    if
        bytes.starts(with: Array("RIFF".utf8)),
        bytes.dropFirst(8).starts(with: Array("WEBP".utf8))
    {
        return "webp"
    }
    return nil
}

func validatedHTTPURL(_ value: String) -> URL? {
    guard
        let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
        let scheme = url.scheme?.lowercased(),
        scheme == "http" || scheme == "https",
        url.host != nil
    else {
        return nil
    }
    return url
}
