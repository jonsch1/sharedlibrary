import Foundation

struct DiscoveredChannel {
    struct Item {
        var id: String
        var title: String
        var url: String
        var publishedAt: String? = nil
        var content: String? = nil
        var linkedURL: String? = nil
        var preferredInput: ItemInputID? = nil
        var mediaURL: String? = nil
        var transcriptURL: String? = nil
        var transcriptType: String? = nil
        var transcriptLanguage: String? = nil
    }

    var title: String
    var kind: LibraryChannelKind
    var items: [Item]
}


func normalizedChannelSource(_ value: String) throws -> String {
    let source = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard
        !source.isEmpty,
        source.count <= 2_048,
        validChannelSource(source)
    else {
        throw LibraryError.invalidChannel
    }
    return source
}

func voiceBriefItemKey(_ source: String, _ itemID: String) -> String {
    "\(source)\n\(itemID)"
}

func channelDisplayTitle(_ source: String) -> String {
    guard let url = URL(string: source) else { return source }
    let path = url.path
        .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        .replacingOccurrences(of: "/", with: " · ")
    return path.isEmpty
        ? url.host?.replacingOccurrences(of: "www.", with: "") ?? source
        : path
}

func discoverChannel(
    _ source: String,
    maximumItems: Int
) async throws -> DiscoveredChannel {
    guard let url = httpURL(source) else { throw LibraryError.invalidChannel }
    let requestURL: URL
    if
        url.host?.lowercased().hasSuffix("reddit.com") == true,
        url.path.range(of: #"/r/[^/]+/?$"#, options: .regularExpression) != nil
    {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.path = url.path.trimmingCharacters(
            in: CharacterSet(charactersIn: "/")
        ) + "/.rss"
        components.path = "/" + components.path
        components.queryItems = [URLQueryItem(
            name: "limit",
            value: String(maximumItems)
        )]
        requestURL = components.url!
    } else {
        requestURL = url
    }

    if let feedURL = youtubeFeedURL(in: "", relativeTo: requestURL) {
        let (feedData, _) = try await fetchChannelURL(feedURL)
        return limitedChannel(
            try parseFeed(
                feedData,
                fallbackTitle: channelDisplayTitle(source),
                baseURL: feedURL
            ),
            maximumItems: maximumItems
        )
    }

    let (data, response) = try await fetchChannelURL(requestURL)
    let finalURL = response.url ?? requestURL
    if looksLikeFeed(data: data, response: response) {
        return limitedChannel(
            try parseFeed(
                data,
                fallbackTitle: channelDisplayTitle(source),
                baseURL: finalURL
            ),
            maximumItems: maximumItems
        )
    }
    let html = String(decoding: data, as: UTF8.self)
    if let hackerNews = parseHackerNews(
        html,
        sourceURL: finalURL,
        maximumItems: maximumItems
    ) {
        return hackerNews
    }
    let feedURLs = [
        youtubeFeedURL(in: html, relativeTo: finalURL),
        await applePodcastFeedURL(for: finalURL),
        discoveredFeedURL(in: html, relativeTo: finalURL)
    ].compactMap { $0 }
    for feedURL in NSOrderedSet(array: feedURLs).array.compactMap({ $0 as? URL }) {
        do {
            let (feedData, _) = try await fetchChannelURL(feedURL)
            return limitedChannel(
                try parseFeed(
                    feedData,
                    fallbackTitle: channelDisplayTitle(source),
                    baseURL: feedURL
                ),
                maximumItems: maximumItems
            )
        } catch {
            continue
        }
    }
    let title = regexCapture(
        html,
        pattern: #"(?is)<title[^>]*>\s*(.*?)\s*</title>"#
    ).map(decodeHTML) ?? channelDisplayTitle(source)
    let content = stripHTML(html)
    guard !content.isEmpty else {
        throw LibraryError.channelFailed(
            "The channel did not contain a feed or readable page."
        )
    }
    return DiscoveredChannel(
        title: title,
        kind: .page,
        items: [.init(
            id: finalURL.absoluteString,
            title: title,
            url: finalURL.absoluteString,
            content: content
        )]
    )
}

private func limitedChannel(
    _ channel: DiscoveredChannel,
    maximumItems: Int
) -> DiscoveredChannel {
    var channel = channel
    channel.items = channel.items.enumerated()
        .map { (item: $0.element, index: $0.offset, date: channelDate($0.element.publishedAt)) }
        .sorted {
            if let left = $0.date, let right = $1.date { return left > right }
            return $0.index < $1.index
        }
        .prefix(maximumItems)
        .map(\.item)
    return channel
}

private func channelDate(_ value: String?) -> Date? {
    guard let value else { return nil }
    if let date = ISO8601DateFormatter().date(from: value) { return date }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    for format in ["EEE, dd MMM yyyy HH:mm:ss Z", "EEE, dd MMM yyyy HH:mm Z"] {
        formatter.dateFormat = format
        if let date = formatter.date(from: value) { return date }
    }
    return nil
}

private func fetchChannelURL(_ url: URL) async throws -> (Data, HTTPURLResponse) {
    var request = URLRequest(url: url, timeoutInterval: 30)
    request.setValue(
        "application/atom+xml, application/rss+xml, application/xml, text/html;q=0.9",
        forHTTPHeaderField: "Accept"
    )
    request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
    request.setValue(
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) " +
            "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/123.0 Safari/537.36",
        forHTTPHeaderField: "User-Agent"
    )
    let (data, response) = try await URLSession.shared.data(for: request)
    guard
        let response = response as? HTTPURLResponse,
        (200..<300).contains(response.statusCode)
    else {
        throw LibraryError.channelFailed("The channel returned an invalid response.")
    }
    guard data.count <= 12_000_000 else {
        throw LibraryError.channelFailed("The channel response is larger than 12 MB.")
    }
    return (data, response)
}

private func looksLikeFeed(data: Data, response: HTTPURLResponse) -> Bool {
    let contentType = response.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
    if contentType.contains("rss") ||
        contentType.contains("atom") ||
        contentType.contains("xml") {
        return true
    }
    let prefix = String(decoding: data.prefix(1_000), as: UTF8.self).lowercased()
    return prefix.contains("<rss") ||
        prefix.contains("<feed") ||
        prefix.contains("<rdf:rdf")
}

private func discoveredFeedURL(in html: String, relativeTo base: URL) -> URL? {
    guard let expression = try? NSRegularExpression(pattern: #"(?is)<link\b[^>]*>"#) else {
        return nil
    }
    for match in expression.matches(
        in: html,
        range: NSRange(html.startIndex..., in: html)
    ) {
        guard let range = Range(match.range, in: html) else { continue }
        let tag = String(html[range])
        let type = htmlAttribute("type", in: tag).lowercased()
        guard type.contains("rss") || type.contains("atom") else { continue }
        if
            let href = htmlAttribute("href", in: tag).nilIfEmpty,
            let url = URL(string: decodeHTML(href), relativeTo: base)?.absoluteURL,
            url.scheme == "http" || url.scheme == "https"
        {
            return url
        }
    }
    return nil
}

func youtubeFeedURL(in html: String, relativeTo pageURL: URL) -> URL? {
    let host = pageURL.host?.lowercased() ?? ""
    guard host == "youtube.com" || host.hasSuffix(".youtube.com") else {
        return nil
    }
    let parts = pageURL.path.split(separator: "/").map(String.init)
    let pathID = parts.first == "channel" ? parts.dropFirst().first : nil
    let channelID = pathID ?? regexCapture(
        html,
        pattern: #"(?is)<meta\b(?=[^>]*\bitemprop=["']channelId["'])[^>]*\bcontent=["']([^"']+)["']"#
    ) ?? regexCapture(
        html,
        pattern: #"["']channelId["']\s*:\s*["']([^"']+)["']"#
    )
    guard
        let channelID,
        channelID.range(
            of: #"^[A-Za-z0-9_-]{10,64}$"#,
            options: .regularExpression
        ) != nil
    else {
        return nil
    }
    var components = URLComponents(string: "https://www.youtube.com/feeds/videos.xml")!
    components.queryItems = [URLQueryItem(name: "channel_id", value: channelID)]
    return components.url
}

private func applePodcastFeedURL(for pageURL: URL) async -> URL? {
    guard
        pageURL.host?.lowercased() == "podcasts.apple.com",
        let id = regexCapture(pageURL.path, pattern: #"/id(\d+)(?:/|$)"#)
    else {
        return nil
    }
    var components = URLComponents(string: "https://itunes.apple.com/lookup")!
    components.queryItems = [
        URLQueryItem(name: "id", value: id),
        URLQueryItem(name: "entity", value: "podcast")
    ]
    guard
        let url = components.url,
        let (data, _) = try? await fetchChannelURL(url),
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let results = object["results"] as? [[String: Any]],
        let value = results.first(where: { $0["kind"] as? String == "podcast" })?["feedUrl"]
            as? String,
        let feedURL = httpURL(value)
    else {
        return nil
    }
    return feedURL
}

func parseHackerNews(
    _ html: String,
    sourceURL: URL,
    maximumItems: Int = 5
) -> DiscoveredChannel? {
    guard
        sourceURL.host?.lowercased() == "news.ycombinator.com",
        ["", "/", "/front"].contains(sourceURL.path),
        let rows = try? NSRegularExpression(pattern: #"(?is)<tr\b([^>]*)>(.*?)</tr>"#),
        let links = try? NSRegularExpression(
            pattern: #"(?is)<span\b[^>]*class=["'][^"']*\btitleline\b[^"']*["'][^>]*>.*?<a\b([^>]*)>(.*?)</a>"#
        )
    else {
        return nil
    }
    var items = [DiscoveredChannel.Item]()
    for row in rows.matches(
        in: html,
        range: NSRange(location: 0, length: html.utf16.count)
    ) {
        guard
            row.numberOfRanges == 3,
            let attributesRange = Range(row.range(at: 1), in: html),
            let bodyRange = Range(row.range(at: 2), in: html)
        else {
            continue
        }
        let attributes = String(html[attributesRange])
        let classes = htmlAttribute("class", in: attributes)
            .split(whereSeparator: \.isWhitespace)
        guard classes.contains("athing") else { continue }
        let body = String(html[bodyRange])
        guard
            let link = links.firstMatch(
                in: body,
                range: NSRange(location: 0, length: body.utf16.count)
            ),
            let linkAttributesRange = Range(link.range(at: 1), in: body),
            let titleRange = Range(link.range(at: 2), in: body),
            let href = htmlAttribute(
                "href",
                in: String(body[linkAttributesRange])
            ).nilIfEmpty,
            let itemURL = URL(string: decodeHTML(href), relativeTo: sourceURL)?.absoluteURL,
            httpURL(itemURL.absoluteString) != nil
        else {
            continue
        }
        let id = htmlAttribute("id", in: attributes).nilIfEmpty ?? itemURL.absoluteString
        items.append(.init(
            id: id,
            title: decodeHTML(stripHTML(String(body[titleRange]))),
            url: itemURL.absoluteString
        ))
        if items.count == maximumItems { break }
    }
    return items.isEmpty ? nil : DiscoveredChannel(
        title: "Hacker News front page",
        kind: .feed,
        items: items
    )
}

private func htmlAttribute(_ name: String, in tag: String) -> String {
    regexCapture(
        tag,
        pattern: #"(?is)\b\#(name)\s*=\s*["']([^"']*)["']"#
    ) ?? ""
}

func parseFeed(
    _ data: Data,
    fallbackTitle: String,
    baseURL: URL? = nil
) throws -> DiscoveredChannel {
    let delegate = FeedParser(baseURL: baseURL)
    let parser = XMLParser(data: data)
    parser.delegate = delegate
    guard parser.parse(), !delegate.items.isEmpty else {
        throw LibraryError.channelFailed(
            parser.parserError?.localizedDescription ??
                "The feed did not contain any items."
        )
    }
    return DiscoveredChannel(
        title: delegate.channelTitle.nilIfEmpty ?? fallbackTitle,
        kind: delegate.isPodcast ? .podcast : .feed,
        items: delegate.items
    )
}

private final class FeedParser: NSObject, XMLParserDelegate {
    private let baseURL: URL?
    private var inItem = false
    private var activeElement = ""
    private var text = ""
    private var item = DiscoveredChannel.Item(id: "", title: "", url: "")
    var channelTitle = ""
    var isPodcast = false
    var items = [DiscoveredChannel.Item]()

    init(baseURL: URL?) {
        self.baseURL = baseURL
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        let name = localName(elementName)
        activeElement = name
        text = ""
        if name == "item" || name == "entry" {
            inItem = true
            item = .init(id: "", title: "", url: "")
        } else if inItem, name == "link", let href = attributeDict["href"] {
            if attributeDict["rel"] == "enclosure" {
                item.linkedURL = href
                item.mediaURL = href
                isPodcast = attributeDict["type"]?.lowercased().hasPrefix("audio/") == true || isPodcast
            } else if item.url.isEmpty || attributeDict["rel"] == "alternate" {
                item.url = href
            }
        } else if inItem, name == "enclosure", let url = attributeDict["url"] {
            item.linkedURL = url
            item.mediaURL = url
            isPodcast = attributeDict["type"]?.lowercased().hasPrefix("audio/") == true || isPodcast
        } else if inItem, name == "transcript", let url = attributeDict["url"] {
            let type = nativeTranscriptType(attributeDict["type"], url: url)
            if nativeTranscriptRank(type) > nativeTranscriptRank(item.transcriptType) {
                item.transcriptURL = url
                item.transcriptType = type
                item.transcriptLanguage = attributeDict["language"]
            }
            isPodcast = true
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        text += String(decoding: CDATABlock, as: UTF8.self)
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let name = localName(elementName)
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if inItem {
            switch name {
            case "title":
                item.title = decodeHTML(stripHTML(value))
            case "guid", "id":
                item.id = value
            case "link" where item.url.isEmpty:
                item.url = value
            case "pubdate", "published", "updated":
                item.publishedAt = value.nilIfEmpty
            case "description", "summary", "content", "encoded":
                let content = stripHTML(value)
                if content.count > (item.content?.count ?? 0) {
                    item.content = content.nilIfEmpty
                }
            default:
                break
            }
        } else if name == "title", channelTitle.isEmpty {
            channelTitle = decodeHTML(stripHTML(value))
        }
        if name == "item" || name == "entry" {
            if item.url.isEmpty, httpURL(item.id) != nil {
                item.url = item.id
            }
            if item.url.isEmpty, let mediaURL = item.mediaURL {
                item.url = mediaURL
            }
            if
                let baseURL,
                let url = URL(string: item.url, relativeTo: baseURL)?.absoluteURL
            {
                item.url = url.absoluteString
            }
            if
                let linkedURL = item.linkedURL,
                let url = URL(string: linkedURL, relativeTo: baseURL)?.absoluteURL
            {
                item.linkedURL = url.absoluteString
                item.mediaURL = url.absoluteString
            }
            if
                let transcriptURL = item.transcriptURL,
                let url = URL(string: transcriptURL, relativeTo: baseURL)?.absoluteURL
            {
                item.transcriptURL = url.absoluteString
            }
            if item.id.isEmpty { item.id = item.url }
            if item.title.isEmpty { item.title = item.content?.prefix(100).description ?? "Untitled" }
            if httpURL(item.url) != nil, !item.id.isEmpty {
                items.append(item)
            }
            inItem = false
        }
        activeElement = ""
        text = ""
    }

    private func localName(_ value: String) -> String {
        value.split(separator: ":").last?.lowercased() ?? value.lowercased()
    }
}

private func stripHTML(_ value: String) -> String {
    var text = value
    for pattern in [
        #"(?is)<(script|style)\b[^>]*>.*?</\1>"#,
        #"(?i)<br\s*/?>"#,
        #"(?i)</p\s*>"#,
        #"(?is)<[^>]+>"#
    ] {
        text = text.replacingOccurrences(
            of: pattern,
            with: pattern.contains("br") || pattern.contains("/p") ? "\n" : " ",
            options: .regularExpression
        )
    }
    return decodeHTML(text)
        .replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
        .replacingOccurrences(of: #"\n\s*\n\s*\n+"#, with: "\n\n", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

private func decodeHTML(_ value: String) -> String {
    var text = value
    for (entity, replacement) in [
        ("&amp;", "&"),
        ("&lt;", "<"),
        ("&gt;", ">"),
        ("&quot;", "\""),
        ("&#39;", "'"),
        ("&apos;", "'"),
        ("&nbsp;", " ")
    ] {
        text = text.replacingOccurrences(
            of: entity,
            with: replacement,
            options: .caseInsensitive
        )
    }
    return text
}


func validChannelSource(_ source: String) -> Bool {
    httpURL(source) != nil
}

func validSchedule(_ value: String) -> Bool {
    let normalized = value.lowercased()
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    if normalized == "manual" { return true }
    let patterns = [
        #"^hourly(?: at)? :([0-5][0-9])$"#,
        #"^daily(?: at)? ([01]?[0-9]|2[0-3]):([0-5][0-9])$"#,
        #"^weekly (mon|tue|wed|thu|fri|sat|sun)(?:day)?(?: at)? ([01]?[0-9]|2[0-3]):([0-5][0-9])$"#
    ]
    return patterns.contains {
        normalized.range(of: $0, options: .regularExpression) != nil
    }
}

func mostRecentScheduledDate(_ value: String, at date: Date) -> Date? {
    let normalized = value.lowercased()
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    guard normalized != "manual" else { return nil }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .current

    if normalized.hasPrefix("hourly") {
        guard
            let minuteText = regexCapture(normalized, pattern: #":([0-5][0-9])$"#),
            let minute = Int(minuteText)
        else {
            return nil
        }
        var components = calendar.dateComponents(
            [.year, .month, .day, .hour],
            from: date
        )
        components.minute = minute
        components.second = 0
        guard var candidate = calendar.date(from: components) else { return nil }
        if candidate > date {
            candidate = calendar.date(byAdding: .hour, value: -1, to: candidate)!
        }
        return candidate
    }

    guard
        let time = regexCapture(
            normalized,
            pattern: #"((?:[01]?[0-9]|2[0-3]):[0-5][0-9])$"#
        )
    else {
        return nil
    }
    let parts = time.split(separator: ":").compactMap { Int($0) }
    guard parts.count == 2 else { return nil }
    var components = calendar.dateComponents([.year, .month, .day], from: date)
    components.hour = parts[0]
    components.minute = parts[1]
    components.second = 0
    guard var candidate = calendar.date(from: components) else { return nil }

    if normalized.hasPrefix("daily") {
        if candidate > date {
            candidate = calendar.date(byAdding: .day, value: -1, to: candidate)!
        }
        return candidate
    }

    guard
        let weekdayText = regexCapture(
            normalized,
            pattern: #"^weekly (mon|tue|wed|thu|fri|sat|sun)"#
        ),
        let targetWeekday = [
            "sun": 1,
            "mon": 2,
            "tue": 3,
            "wed": 4,
            "thu": 5,
            "fri": 6,
            "sat": 7
        ][weekdayText]
    else {
        return nil
    }
    let weekday = calendar.component(.weekday, from: date)
    let daysBack = (weekday - targetWeekday + 7) % 7
    candidate = calendar.date(byAdding: .day, value: -daysBack, to: candidate)!
    if candidate > date {
        candidate = calendar.date(byAdding: .day, value: -7, to: candidate)!
    }
    return candidate
}
