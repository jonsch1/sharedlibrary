import BrieflyCore
import Foundation
import WebKit

@MainActor
final class ChannelBrowserSession {
    static let shared = ChannelBrowserSession()

    let dataStore: WKWebsiteDataStore

    private init(arguments: [String] = ProcessInfo.processInfo.arguments) {
        dataStore = arguments.contains("--app-review-testing")
            ? .nonPersistent()
            : WKWebsiteDataStore(
                forIdentifier: UUID(uuidString: "F5D5198E-24BC-4E08-AAC0-D275EE8620D1")!
            )
    }

    func makeWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore
        return WKWebView(frame: .zero, configuration: configuration)
    }

    func extractText(from url: URL) async throws -> String {
        try await extractPage(from: url).text
    }

    func extractPage(from url: URL) async throws -> SignedInChannelPage {
        let request = ItemInputRequest(source: .url(url))
        let router = NativeItemInputRouter()
        if router.inputID(for: request) == .youtube {
            let draft = try await router.ingest(request)
            return SignedInChannelPage(
                title: draft.title,
                text: draft.content,
                items: [],
                faviconData: draft.faviconData,
                faviconFileExtension: draft.faviconFileExtension
            )
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
        let host = url.host?.lowercased() ?? ""
        let isBiorxivSearch = (host == "biorxiv.org" || host.hasSuffix(".biorxiv.org")) &&
            url.path.hasPrefix("/search/")
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
            isBiorxivSearch,
            let value = try await webView.evaluateJavaScript("""
                (() => JSON.stringify(Array.from(document.querySelectorAll('a[href]'))
                  .map(link => {
                    const itemURL = new URL(link.getAttribute('href') || '', location.href);
                    if (!/^\\/content\\/10\\.\\d{4,9}\\/[^/?#]+v\\d+$/.test(itemURL.pathname)) {
                      return null;
                    }
                    itemURL.search = '';
                    itemURL.hash = '';
                    const title = (link.textContent || '').replace(/\\s+/g, ' ').trim();
                    if (!title) return null;
                    const row = link.closest(
                      'li.search-result, article, .highwire-article-citation, li'
                    ) || link.parentElement;
                    return {
                      id: itemURL.pathname.replace(/^\\/content\\//, ''),
                      title: title.slice(0, 500),
                      url: itemURL.href,
                      publishedAt: null,
                      content: (row?.innerText || title).trim().slice(0, 20000)
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
        if
            items.isEmpty,
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
