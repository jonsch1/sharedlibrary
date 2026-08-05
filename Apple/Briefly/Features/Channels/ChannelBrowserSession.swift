import BrieflyCore
import Foundation
import WebKit

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
