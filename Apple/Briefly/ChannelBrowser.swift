import SwiftUI
import WebKit

struct BrieflyAccountStatus: Decodable, Equatable {
    let authenticated: Bool
    let entitled: Bool?
    let email: String?
    let accountID: UUID?

    static let signedOut = Self(
        authenticated: false,
        entitled: false,
        email: nil,
        accountID: nil
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

    func accountStatus() async throws -> BrieflyAccountStatus {
        let (data, response) = try await request("api/auth/status")
        guard response.statusCode == 200 else { return .signedOut }
        return try JSONDecoder().decode(BrieflyAccountStatus.self, from: data)
    }

    func signOut() async throws {
        let (_, response) = try await request("api/auth/logout", method: "POST")
        try requireSuccess(response, data: nil, fallback: "Could not sign out.")
    }

    func signInWithApple(identityToken: Data, nonce: String) async throws
        -> BrieflyAccountStatus
    {
        struct Payload: Encodable {
            let identityToken: String
            let nonce: String
        }
        guard let token = String(data: identityToken, encoding: .utf8) else {
            throw BrieflyBackendError.message("Apple returned an invalid identity token.")
        }
        let body = try JSONEncoder().encode(Payload(identityToken: token, nonce: nonce))
        let (data, response) = try await request(
            "api/auth/apple/native",
            method: "POST",
            body: body
        )
        try requireSuccess(response, data: data, fallback: "Could not sign in with Apple.")
        await storeCookies(from: response)
        return try JSONDecoder().decode(BrieflyAccountStatus.self, from: data)
    }

    func syncAppStoreTransaction(_ transactionID: String) async throws
        -> BrieflyAccountStatus
    {
        struct Payload: Encodable { let transactionID: String }
        let body = try JSONEncoder().encode(Payload(transactionID: transactionID))
        let (data, response) = try await request(
            "api/billing/apple/transaction",
            method: "POST",
            body: body
        )
        try requireSuccess(
            response,
            data: data,
            fallback: "Could not verify the App Store subscription."
        )
        return try JSONDecoder().decode(BrieflyAccountStatus.self, from: data)
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
        if method != "GET" {
            request.setValue(Self.origin.absoluteString, forHTTPHeaderField: "Origin")
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

    private func storeCookies(from response: HTTPURLResponse) async {
        let fields = response.allHeaderFields.reduce(into: [String: String]()) {
            guard let key = $1.key as? String, let value = $1.value as? String else { return }
            $0[key] = value
        }
        for cookie in HTTPCookie.cookies(withResponseHeaderFields: fields, for: Self.origin) {
            await withCheckedContinuation { continuation in
                ChannelBrowserSession.shared.dataStore.httpCookieStore.setCookie(cookie) {
                    continuation.resume()
                }
            }
        }
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

private struct RedditPage: Decodable {
    let title: String
    let post: String
    let comments: [String]
    let linkedURL: String
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
        if let videoID = youtubeVideoID(url) {
            return try await extractYouTubeVideo(url: url, videoID: videoID)
        }
        let webView = makeWebView()
        let navigation = NavigationWaiter()
        webView.navigationDelegate = navigation
        try await navigation.load(oldRedditURL(url) ?? url, in: webView)
        try await Task.sleep(nanoseconds: 800_000_000)
        let rejectedConsent = try await webView.evaluateJavaScript("""
            (() => {
              const controls = Array.from(
                document.querySelectorAll('button, input[type="submit"]')
              );
              const reject = controls.find(control =>
                /^(reject all|decline all|alle ablehnen|tout refuser|rifiuta tutto|rechazar todo)$/i
                  .test((control.innerText || control.value || '').trim()));
              reject?.click();
              return Boolean(reject);
            })()
        """) as? Bool ?? false
        if rejectedConsent { try await Task.sleep(for: .seconds(2)) }
        if
            isRedditPost(url),
            let value = try await webView.evaluateJavaScript("""
                (() => JSON.stringify({
                  title: document.querySelector('.thing.link a.title')?.textContent?.trim() || '',
                  post: document.querySelector('.thing.link .usertext-body .md')
                    ?.innerText?.trim() || '',
                  linkedURL: document.querySelector('.thing.link a.title')?.href || '',
                  comments: Array.from(
                    document.querySelectorAll('.commentarea .thing.comment')
                  ).slice(0, 10).map(comment => {
                    const entry = comment.querySelector(':scope > .entry');
                    const author = entry?.querySelector('.author')?.textContent?.trim() || '';
                    const body = entry?.querySelector('.usertext-body .md')?.innerText?.trim() || '';
                    return author && body ? `u/${author}\\n${body}` : '';
                  }).filter(Boolean)
                }))()
            """) as? String,
            let data = value.data(using: .utf8),
            let reddit = try? JSONDecoder().decode(RedditPage.self, from: data)
        {
            let article: String
            if
                let linkedURL = URL(string: reddit.linkedURL),
                !isRedditHost(linkedURL.host ?? "")
            {
                article = (try? await extractPage(from: linkedURL).text) ?? ""
            } else {
                article = ""
            }
            let content = [
                article.isEmpty ? nil : "## Article\n\n\(article)",
                reddit.post.isEmpty ? nil : "## Post\n\n\(reddit.post)",
                reddit.comments.isEmpty ? nil : "## Discussion\n\n" +
                    reddit.comments.enumerated().map {
                        "### Comment \($0.offset + 1)\n\n\($0.element)"
                    }.joined(separator: "\n\n")
            ].compactMap { $0 }.joined(separator: "\n\n")
            if !content.isEmpty {
                let favicon = await downloadFavicon(from: webView, pageURL: url)
                return SignedInChannelPage(
                    title: reddit.title.isEmpty ? webView.title ?? "Reddit post" : reddit.title,
                    text: content,
                    items: [],
                    faviconData: favicon?.data,
                    faviconFileExtension: favicon?.fileExtension
                )
            }
        }
        let isX = url.host?.lowercased() == "x.com" ||
            url.host?.lowercased().hasSuffix(".x.com") == true ||
            url.host?.lowercased().contains("twitter.com") == true
        if
            isX
        {
            _ = try await webView.callAsyncJavaScript("""
                for (let index = 0; index < 8; index += 1) {
                  window.scrollBy(0, Math.max(500, window.innerHeight * 0.85));
                  await new Promise(done => setTimeout(done, 500));
                }
                window.scrollTo(0, 0);
                return true;
            """, contentWorld: .page)
        } else {
            _ = try await webView.callAsyncJavaScript("""
                for (let index = 0; index < 3; index += 1) {
                  window.scrollBy(0, Math.max(500, window.innerHeight * 0.8));
                  await new Promise(done => setTimeout(done, 500));
                }
                window.scrollTo(0, 0);
                return true;
            """, contentWorld: .page)
        }
        let xParts = url.path.split(separator: "/").map(String.init)
        var xStatusText: String?
        if
            isX,
            xParts.count >= 3,
            xParts[1].lowercased() == "status",
            xParts[0].range(of: #"^[A-Za-z0-9_]{1,15}$"#, options: .regularExpression) != nil,
            xParts[2].range(of: #"^\d+$"#, options: .regularExpression) != nil
        {
            xStatusText = try await webView.evaluateJavaScript("""
                (() => {
                  const parsed = Array.from(document.querySelectorAll('article'))
                    .map(article => {
                      const href = article.querySelector('time')?.closest('a')?.href ||
                        Array.from(article.querySelectorAll('a[href*="/status/"]'))
                          .map(link => link.href)
                          .find(value => /\\/status\\/\\d+/.test(value));
                      const match = href &&
                        /^https:\\/\\/[^/]+\\/([^/]+)\\/status\\/(\\d+)/.exec(href);
                      return match ? {
                        author: match[1],
                        id: match[2],
                        text: (article.innerText || '')
                          .replace(/\\n{3,}/g, '\\n\\n')
                          .trim()
                      } : null;
                    })
                    .filter(Boolean);
                  const root = parsed.findIndex(item => item.id === "\(xParts[2])");
                  if (root < 0) return '';
                  const thread = [parsed[root]];
                  for (const item of parsed.slice(root + 1)) {
                    if (item.author.toLowerCase() !== "\(xParts[0].lowercased())") break;
                    thread.push(item);
                  }
                  return thread.map(item => item.text).filter(Boolean).join('\\n\\n');
                })()
            """) as? String
        }
        if
            let text = xStatusText,
            !text.isEmpty,
            let value = try await webView.evaluateJavaScript("""
                (() => JSON.stringify(Array.from(new Set(
                  Array.from(document.querySelectorAll('a[href]'))
                    .map(link => link.href)
                    .filter(href => /\\/article\\/\\d+/.test(href))
                ))))()
            """) as? String,
            let data = value.data(using: .utf8),
            let links = try? JSONDecoder().decode([String].self, from: data)
        {
            var sections = [text]
            for value in links.prefix(3) {
                guard
                    let articleURL = URL(string: value),
                    let article = try? await extractPage(from: articleURL).text,
                    !article.isEmpty
                else {
                    continue
                }
                sections.append("## Article\n\n\(article)")
            }
            xStatusText = sections.joined(separator: "\n\n")
        }
        let useXBody = isX && xParts.count == 1
        let extractedText: String?
        if let xStatusText {
            extractedText = xStatusText
        } else {
            extractedText = try await webView.evaluateJavaScript(useXBody ? """
            (() => (document.body?.innerText || '')
              .replace(/\\n{3,}/g, '\\n\\n')
              .trim()
              .slice(0, 60000))()
        """ : """
            (() => {
              const articles = Array.from(document.querySelectorAll('article'))
                .filter(element => (element.innerText || '').trim().length > 200);
              const candidates = articles.length ? articles :
                Array.from(document.querySelectorAll('main, [role="main"]'))
                  .filter(element => (element.innerText || '').trim().length > 200);
              const root = candidates.sort(
                (left, right) => (right.innerText || '').length -
                  (left.innerText || '').length
              )[0] || document.body;
              const clone = root?.cloneNode(true);
              clone?.querySelectorAll(
                'script, style, noscript, nav, footer, aside, form, button, dialog, [aria-hidden="true"]'
              ).forEach(element => element.remove());
              return (clone?.innerText || '').split(/\\n+/)
                .map(line => line.trim())
                .filter(Boolean)
                .filter((line, index, values) => line !== values[index - 1])
                .join('\\n\\n')
                .slice(0, 60000);
            })()
            """) as? String
        }
        guard let text = extractedText, !text.isEmpty else {
            throw ChannelBrowserError.emptyPage
        }
        var items = [SignedInChannelItem]()
        if
            isX,
            xParts.count == 1,
            let value = try await webView.evaluateJavaScript("""
                (() => JSON.stringify(Array.from(document.querySelectorAll('article'))
                  .map(article => {
                    const text = (article.innerText || '').trim();
                    const pinned = /\\bPinned\\b/i.test(
                      article.querySelector('[data-testid="socialContext"]')?.textContent || ''
                    );
                    const link = Array.from(article.querySelectorAll('a[href*="/status/"]'))
                      .map(node => node.getAttribute('href') || '')
                      .find(href => /\\/status\\/\\d+/.test(href));
                    if (!text || !link || pinned) return null;
                    const url = new URL(link, location.origin).href.split('?')[0];
                    const id = /\\/status\\/(\\d+)/.exec(url)?.[1];
                    if (!id) return null;
                    const time = article.querySelector('time');
                    return {
                      id,
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

    private func extractYouTubeVideo(
        url: URL,
        videoID: String
    ) async throws -> SignedInChannelPage {
        var request = URLRequest(
            url: URL(string: "https://www.youtube.com/youtubei/v1/player?prettyPrint=false")!,
            timeoutInterval: 30
        )
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "context": [
                "client": [
                    "clientName": "IOS",
                    "clientVersion": "21.26.4",
                    "deviceMake": "Apple",
                    "deviceModel": "iPhone16,2",
                    "hl": "en",
                    "osName": "iPhone",
                    "osVersion": "18.3.2.22D82"
                ]
            ],
            "videoId": videoID
        ])
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(
            "com.google.ios.youtube/21.26.4 " +
                "(iPhone16,2; U; CPU iOS 18_3_2 like Mac OS X;)",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("5", forHTTPHeaderField: "X-YouTube-Client-Name")
        request.setValue("21.26.4", forHTTPHeaderField: "X-YouTube-Client-Version")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard
            let response = response as? HTTPURLResponse,
            (200..<300).contains(response.statusCode),
            data.count <= 10_000_000,
            let player = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let video = player["videoDetails"] as? [String: Any],
            let title = (video["title"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            !title.isEmpty
        else {
            throw ChannelBrowserError.youtubeUnavailable
        }
        let author = (video["author"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let description = (video["shortDescription"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let captions = player["captions"] as? [String: Any]
        let renderer = captions?["playerCaptionsTracklistRenderer"] as? [String: Any]
        let tracks = renderer?["captionTracks"] as? [[String: Any]] ?? []
        let track = tracks
            .filter { $0["baseUrl"] is String }
            .sorted { youtubeTrackScore($0) > youtubeTrackScore($1) }
            .first
        let transcript: [String]
        if let value = track?["baseUrl"] as? String {
            transcript = try await fetchYouTubeTranscript(value)
        } else {
            transcript = []
        }
        let content = transcript.isEmpty
            ? [
                "Transcript unavailable for this video.",
                author.isEmpty ? nil : "Channel: \(author)",
                description.isEmpty ? nil : "\nDescription:\n\(description)"
            ].compactMap { $0 }.joined(separator: "\n")
            : "Transcript:\n\(transcript.joined(separator: "\n"))"
        let favicon = await downloadFavicon(
            at: URL(string: "https://www.youtube.com/favicon.ico")!
        )
        return SignedInChannelPage(
            title: title,
            text: content,
            items: [],
            faviconData: favicon?.data,
            faviconFileExtension: favicon?.fileExtension
        )
    }

    private func fetchYouTubeTranscript(_ value: String) async throws -> [String] {
        guard var components = URLComponents(string: value) else { return [] }
        components.queryItems = (components.queryItems ?? [])
            .filter { $0.name != "fmt" } + [URLQueryItem(name: "fmt", value: "json3")]
        guard let url = components.url else { return [] }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.setValue("application/json,text/xml;q=0.9,*/*;q=0.1", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard
            let response = response as? HTTPURLResponse,
            (200..<300).contains(response.statusCode),
            data.count <= 10_000_000,
            let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let events = payload["events"] as? [[String: Any]]
        else {
            return []
        }
        return events.compactMap { event in
            let segments = event["segs"] as? [[String: Any]] ?? []
            let text = segments.compactMap { $0["utf8"] as? String }
                .joined()
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        }
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

    private func downloadFavicon(
        at url: URL
    ) async -> (data: Data, fileExtension: String)? {
        var request = URLRequest(url: url, timeoutInterval: 5)
        request.setValue("image/*", forHTTPHeaderField: "Accept")
        guard
            let (data, response) = try? await URLSession.shared.data(for: request),
            let response = response as? HTTPURLResponse,
            (200..<300).contains(response.statusCode),
            data.count <= 1_000_000,
            let fileExtension = faviconFileExtension(data)
        else {
            return nil
        }
        return (data, fileExtension)
    }
}

private func youtubeVideoID(_ url: URL) -> String? {
    let host = url.host?.lowercased() ?? ""
    let parts = url.path.split(separator: "/").map(String.init)
    let candidate: String?
    if host == "youtu.be" {
        candidate = parts.first
    } else if
        host == "youtube.com" || host.hasSuffix(".youtube.com") ||
        host == "youtube-nocookie.com" || host.hasSuffix(".youtube-nocookie.com")
    {
        if url.path == "/watch" {
            candidate = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "v" }?.value
        } else if ["shorts", "live", "embed"].contains(parts.first ?? "") {
            candidate = parts.dropFirst().first
        } else {
            candidate = nil
        }
    } else {
        candidate = nil
    }
    guard
        let candidate,
        candidate.range(of: #"^[A-Za-z0-9_-]{6,20}$"#, options: .regularExpression) != nil
    else {
        return nil
    }
    return candidate
}

private func isRedditHost(_ host: String) -> Bool {
    let host = host.lowercased()
    return host == "reddit.com" || host.hasSuffix(".reddit.com")
}

private func isRedditPost(_ url: URL) -> Bool {
    isRedditHost(url.host ?? "") &&
        url.path.range(
            of: #"/comments/[A-Za-z0-9]+(?:/|$)"#,
            options: .regularExpression
        ) != nil
}

private func oldRedditURL(_ url: URL) -> URL? {
    guard isRedditPost(url), var components = URLComponents(
        url: url,
        resolvingAgainstBaseURL: false
    ) else {
        return nil
    }
    components.host = "old.reddit.com"
    return components.url
}

private func youtubeTrackScore(_ track: [String: Any]) -> Int {
    let language = (track["languageCode"] as? String)?.lowercased() ?? ""
    return (track["kind"] as? String == "asr" ? 0 : 10) +
        (language == "en" || language.hasPrefix("en-") ? 2 : 0)
}

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
                .background(.quaternary.opacity(0.55))
                .clipShape(RoundedRectangle(cornerRadius: 8))

                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .padding(.horizontal, 12)
            .frame(height: 54)
            .background(.bar)
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
                    .disabled(isExtracting)
                }
                .padding(.horizontal, 14)
                .frame(height: 58)
                .background(.bar)
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

@MainActor
private final class ChannelBrowserNavigation: ObservableObject {
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
