import SwiftUI
import WebKit

struct BrieflyAccountStatus: Decodable, Equatable {
    struct Google: Decodable, Equatable {
        let configured: Bool?
        let connected: Bool?
    }

    struct ICloud: Decodable, Equatable {
        let configured: Bool?
        let connected: Bool?
    }

    let authenticated: Bool
    let entitled: Bool?
    let email: String?
    let syncProvider: String?
    let google: Google?
    let icloud: ICloud?

    static let signedOut = Self(
        authenticated: false,
        entitled: false,
        email: nil,
        syncProvider: nil,
        google: nil,
        icloud: nil
    )
}

struct BrieflyShareLinkStatus: Decodable, Equatable {
    let shared: Bool
    let token: String?
    let url: String?
    let status: String?
    let error: String?
}

struct BrieflyShareSource: Encodable {
    struct Text: Encodable {
        let variant: String
        let markdown: String
    }

    let filename: String
    let title: String
    let excerpt: String
    let topicIDs: [String]
    let topicNames: [String]
    let tags: [String]
    let sourceURL: String?
    let createdAt: String?
    let updatedAt: String?
    let texts: [Text]
}

@MainActor
final class BrieflyBackend {
    static let shared = BrieflyBackend()
    static let origin = URL(string: "https://www.readbriefly.fyi")!

    var accountURL: URL {
        var components = URLComponents(
            url: Self.origin.appending(path: "account"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [URLQueryItem(name: "desktop", value: "1")]
        components.fragment = "sync"
        return components.url!
    }

    func signInURL(provider: String) -> URL {
        Self.origin
            .appending(path: "api/auth/\(provider)/start")
            .appending(
                queryItems: [URLQueryItem(name: "return_to", value: "/?desktop=1")]
            )
    }

    func accountStatus() async throws -> BrieflyAccountStatus {
        let (data, response) = try await request("api/auth/status")
        guard response.statusCode == 200 else { return .signedOut }
        return try JSONDecoder().decode(BrieflyAccountStatus.self, from: data)
    }

    func signOut() async throws {
        let (_, response) = try await request("api/auth/logout", method: "POST")
        try requireSuccess(response, data: nil, fallback: "Could not sign out.")
    }

    func runManagedAI(prompt: String, format: String) async throws -> String {
        struct Payload: Encodable {
            let prompt: String
            let format: String
        }
        struct Result: Decodable {
            let output: String?
        }
        let body = try JSONEncoder().encode(Payload(prompt: prompt, format: format))
        let (data, response) = try await request(
            "api/ai/process",
            method: "POST",
            body: body
        )
        try requireSuccess(
            response,
            data: data,
            fallback: "Briefly AI could not process this request."
        )
        guard
            let output = try JSONDecoder().decode(Result.self, from: data).output?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            !output.isEmpty
        else {
            throw BrieflyBackendError.message("Briefly AI returned no output.")
        }
        return output
    }

    func shareStatus(captureID: String) async throws -> BrieflyShareLinkStatus {
        let encoded = captureID.addingPercentEncoding(
            withAllowedCharacters: .urlQueryAllowed
        ) ?? captureID
        let path = "api/share-links?captureID=\(encoded)"
        let (data, response) = try await request(path)
        try requireSuccess(response, data: data, fallback: "Could not read the share link.")
        return try JSONDecoder().decode(BrieflyShareLinkStatus.self, from: data)
    }

    func publishShare(
        captureID: String,
        source: BrieflyShareSource
    ) async throws -> BrieflyShareLinkStatus {
        struct Payload: Encodable {
            let captureID: String
            let source: BrieflyShareSource
        }
        let body = try JSONEncoder().encode(Payload(captureID: captureID, source: source))
        let (data, response) = try await request(
            "api/share-links",
            method: "POST",
            body: body
        )
        try requireSuccess(response, data: data, fallback: "Could not create the share link.")
        return try JSONDecoder().decode(BrieflyShareLinkStatus.self, from: data)
    }

    func revokeShare(token: String) async throws {
        let allowed = CharacterSet.alphanumerics.union(
            CharacterSet(charactersIn: "_-")
        )
        guard
            token.count == 32,
            token.unicodeScalars.allSatisfy(allowed.contains)
        else {
            throw BrieflyBackendError.message("Invalid share link.")
        }
        let (data, response) = try await request(
            "api/share-links/\(token)",
            method: "DELETE"
        )
        try requireSuccess(response, data: data, fallback: "Could not revoke the share link.")
    }

    private func request(
        _ path: String,
        method: String = "GET",
        body: Data? = nil
    ) async throws -> (Data, HTTPURLResponse) {
        guard let url = URL(string: path, relativeTo: Self.origin)?.absoluteURL else {
            throw BrieflyBackendError.message("The Briefly service URL is invalid.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let cookies = await cookies(for: url)
        for (field, value) in HTTPCookie.requestHeaderFields(with: cookies) {
            request.setValue(value, forHTTPHeaderField: field)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw BrieflyBackendError.message("Briefly returned an invalid response.")
        }
        return (data, response)
    }

    private func cookies(for url: URL) async -> [HTTPCookie] {
        let cookies = await withCheckedContinuation {
            (continuation: CheckedContinuation<[HTTPCookie], Never>) in
            ChannelBrowserSession.shared.dataStore.httpCookieStore.getAllCookies {
                continuation.resume(returning: $0)
            }
        }
        guard let host = url.host?.lowercased() else { return [] }
        return cookies.filter {
            let domain = $0.domain
                .trimmingCharacters(in: CharacterSet(charactersIn: "."))
                .lowercased()
            return host == domain || host.hasSuffix(".\(domain)")
        }
    }

    private func requireSuccess(
        _ response: HTTPURLResponse,
        data: Data?,
        fallback: String
    ) throws {
        guard (200..<300).contains(response.statusCode) else {
            let value = data.flatMap {
                try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
            }
            throw BrieflyBackendError.message(
                value?["error"] as? String ??
                    value?["message"] as? String ??
                    fallback
            )
        }
    }
}

enum BrieflyBackendError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let value): value
        }
    }
}

struct SignedInChannelItem: Decodable {
    let id: String
    let title: String
    let url: String
    let publishedAt: String?
    let content: String
}

struct SignedInChannelPage {
    let title: String
    let text: String
    let items: [SignedInChannelItem]
    let faviconData: Data?
    let faviconFileExtension: String?
}

@MainActor
final class ChannelBrowserSession {
    static let shared = ChannelBrowserSession()

    let dataStore = WKWebsiteDataStore(
        forIdentifier: UUID(uuidString: "F5D5198E-24BC-4E08-AAC0-D275EE8620D1")!
    )

    func makeWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore
        return WKWebView(frame: .zero, configuration: configuration)
    }

    func extractText(from url: URL) async throws -> String {
        try await extractPage(from: url).text
    }

    func extractPage(from url: URL) async throws -> SignedInChannelPage {
        let webView = makeWebView()
        let navigation = NavigationWaiter()
        webView.navigationDelegate = navigation
        try await navigation.load(url, in: webView)
        try await Task.sleep(nanoseconds: 800_000_000)
        if
            url.host?.lowercased() == "x.com" ||
            url.host?.lowercased().hasSuffix(".x.com") == true
        {
            _ = try await webView.evaluateJavaScript("""
                new Promise(async resolve => {
                  for (let index = 0; index < 8; index += 1) {
                    window.scrollBy(0, Math.max(500, window.innerHeight * 0.85));
                    await new Promise(done => setTimeout(done, 500));
                  }
                  window.scrollTo(0, 0);
                  resolve(true);
                })
            """)
        }
        if
            let host = url.host?.lowercased(),
            host == "youtu.be" ||
                host == "youtube.com" ||
                host.hasSuffix(".youtube.com")
        {
            _ = try? await webView.evaluateJavaScript("""
                (() => {
                  const buttons = Array.from(document.querySelectorAll('button'));
                  const transcript = buttons.find(button =>
                    /transcript/i.test(
                      `${button.getAttribute('aria-label') || ''} ${button.innerText || ''}`
                    ));
                  transcript?.click();
                  return Boolean(transcript);
                })()
            """)
            try await Task.sleep(for: .seconds(1))
        }
        let result = try await webView.evaluateJavaScript("""
            (() => (document.body?.innerText || '')
              .replace(/\\n{3,}/g, '\\n\\n')
              .trim())()
        """)
        guard let text = result as? String, !text.isEmpty else {
            throw ChannelBrowserError.emptyPage
        }
        var items = [SignedInChannelItem]()
        if
            url.host?.lowercased() == "x.com" ||
            url.host?.lowercased().hasSuffix(".x.com") == true,
            let value = try await webView.evaluateJavaScript("""
                (() => JSON.stringify(Array.from(document.querySelectorAll('article'))
                  .map(article => {
                    const text = (article.innerText || '').trim();
                    const link = Array.from(article.querySelectorAll('a[href*="/status/"]'))
                      .map(node => node.getAttribute('href') || '')
                      .find(href => /\\/status\\/\\d+/.test(href));
                    if (!text || !link) return null;
                    const url = new URL(link, location.origin).href.split('?')[0];
                    const time = article.querySelector('time');
                    return {
                      id: url,
                      title: text.split('\\n').find(Boolean)?.slice(0, 180) || 'X post',
                      url,
                      publishedAt: time?.dateTime || null,
                      content: text.slice(0, 20000)
                    };
                  })
                  .filter(Boolean)
                  .filter((item, index, all) =>
                    all.findIndex(candidate => candidate.id === item.id) === index)
                  .slice(0, 100)))()
            """) as? String,
            let data = value.data(using: .utf8)
        {
            items = (try? JSONDecoder().decode([SignedInChannelItem].self, from: data)) ?? []
        }
        let favicon = await downloadFavicon(from: webView, pageURL: url)
        return SignedInChannelPage(
            title: webView.title ?? url.host ?? "Signed-in channel",
            text: text,
            items: items,
            faviconData: favicon?.data,
            faviconFileExtension: favicon?.fileExtension
        )
    }

    private func downloadFavicon(
        from webView: WKWebView,
        pageURL: URL
    ) async -> (data: Data, fileExtension: String)? {
        let preferred = try? await webView.evaluateJavaScript("""
            (() => {
              const icon = Array.from(document.querySelectorAll('link[rel]'))
                .find(node => /(^|\\s)icon(\\s|$)/i.test(node.rel || ''));
              return icon?.href || '';
            })()
        """) as? String
        let fallback = URL(string: "/favicon.ico", relativeTo: pageURL)?.absoluteURL
        let candidates = [
            preferred.flatMap { URL(string: $0) },
            fallback
        ].compactMap { $0 }
        let cookies = await withCheckedContinuation { continuation in
            dataStore.httpCookieStore.getAllCookies {
                continuation.resume(returning: $0)
            }
        }
        for url in candidates where ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
            do {
                var request = URLRequest(url: url, timeoutInterval: 5)
                request.setValue("image/*", forHTTPHeaderField: "Accept")
                let matching = cookies.filter {
                    url.host?.hasSuffix($0.domain.trimmingCharacters(
                        in: CharacterSet(charactersIn: ".")
                    )) == true
                }
                for (field, value) in HTTPCookie.requestHeaderFields(with: matching) {
                    request.setValue(value, forHTTPHeaderField: field)
                }
                let (data, response) = try await URLSession.shared.data(for: request)
                guard
                    let response = response as? HTTPURLResponse,
                    (200..<300).contains(response.statusCode),
                    data.count <= 1_000_000,
                    let fileExtension = faviconFileExtension(data)
                else {
                    continue
                }
                return (data, fileExtension)
            } catch {
                continue
            }
        }
        return nil
    }
}

struct ChannelLoginView: View {
    @Environment(\.dismiss) private var dismiss
    let onCapture: ((URL, SignedInChannelPage) -> Void)?
    let navigationTitle: String
    @State private var address: String
    @State private var loadedURL: URL
    @State private var preview = ""
    @State private var extractedPage: SignedInChannelPage?
    @State private var errorMessage = ""
    @State private var isExtracting = false

    init(
        initialAddress: String = "https://x.com",
        navigationTitle: String = "Signed-in browser",
        onCapture: ((URL, SignedInChannelPage) -> Void)? = nil
    ) {
        let url = validatedHTTPURL(initialAddress) ?? URL(string: "https://x.com")!
        self.onCapture = onCapture
        self.navigationTitle = navigationTitle
        _address = State(initialValue: url.absoluteString)
        _loadedURL = State(initialValue: url)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack {
                    TextField("https://example.com", text: $address)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                        .onSubmit(loadAddress)
                    Button("Go", action: loadAddress)
                    Button {
                        Task { await testHiddenSession() }
                    } label: {
                        if isExtracting {
                            ProgressView()
                        } else {
                            Label("Test hidden session", systemImage: "eye.slash")
                        }
                    }
                    .disabled(isExtracting)
                    if onCapture != nil, extractedPage != nil {
                        Button {
                            guard
                                let url = validatedHTTPURL(address),
                                let extractedPage
                            else {
                                return
                            }
                            onCapture?(url, extractedPage)
                            dismiss()
                        } label: {
                            Label("Save page", systemImage: "square.and.arrow.down")
                        }
                    }
                }
                .padding(12)

                ChannelWebView(url: loadedURL)

                if !preview.isEmpty || !errorMessage.isEmpty {
                    ScrollView {
                        Text(errorMessage.isEmpty ? preview : errorMessage)
                            .font(.caption.monospaced())
                            .foregroundStyle(
                                errorMessage.isEmpty ? Color.secondary : Color.red
                            )
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                    }
                    .frame(height: 120)
                    .background(.quaternary)
                }
            }
            .navigationTitle(navigationTitle)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 720, minHeight: 560)
        #endif
    }

    private func loadAddress() {
        guard let url = validatedHTTPURL(address) else {
            errorMessage = "Enter a valid HTTP(S) URL."
            return
        }
        errorMessage = ""
        preview = ""
        extractedPage = nil
        loadedURL = url
    }

    private func testHiddenSession() async {
        guard let url = validatedHTTPURL(address) else {
            errorMessage = "Enter a valid HTTP(S) URL."
            return
        }
        isExtracting = true
        defer { isExtracting = false }
        do {
            let page = try await ChannelBrowserSession.shared.extractPage(from: url)
            extractedPage = page
            preview = String(page.text.prefix(2_000))
            errorMessage = ""
        } catch {
            extractedPage = nil
            preview = ""
            errorMessage = error.localizedDescription
        }
    }
}

private func faviconFileExtension(_ data: Data) -> String? {
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

private func validatedHTTPURL(_ value: String) -> URL? {
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

@MainActor
private struct ChannelWebView {
    let url: URL
    let session = ChannelBrowserSession.shared

    func makeView(coordinator: Coordinator) -> WKWebView {
        let view = session.makeWebView()
        view.uiDelegate = coordinator
        view.load(URLRequest(url: url))
        return view
    }

    func updateView(_ view: WKWebView) {
        if view.url != url {
            view.load(URLRequest(url: url))
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator: NSObject, WKUIDelegate {
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
        updateView(nsView)
    }
}
#else
extension ChannelWebView: UIViewRepresentable {
    func makeUIView(context: Context) -> WKWebView {
        makeView(coordinator: context.coordinator)
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        updateView(uiView)
    }
}
#endif

@MainActor
private final class NavigationWaiter: NSObject, WKNavigationDelegate {
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

private enum ChannelBrowserError: LocalizedError {
    case emptyPage
    case timeout

    var errorDescription: String? {
        switch self {
        case .emptyPage:
            "The signed-in browser returned no readable text."
        case .timeout:
            "The signed-in browser took too long to load this page."
        }
    }
}
