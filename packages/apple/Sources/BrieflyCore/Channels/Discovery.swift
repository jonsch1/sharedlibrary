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
    let isArxivQuery = source.lowercased().hasPrefix("arxiv:") &&
        !String(source.dropFirst("arxiv:".count)).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    guard
        !source.isEmpty,
        source.count <= 2_048,
        (isArxivQuery || validChannelSource(source))
    else {
        throw LibraryError.invalidChannel
    }
    return source
}

func channelItemKey(_ source: String, _ itemID: String) -> String {
    "\(source)\n\(itemID)"
}

func channelDisplayTitle(_ source: String) -> String {
    if source.lowercased().hasPrefix("arxiv:") {
        return String(source.dropFirst("arxiv:".count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty ?? "arXiv"
    }
    guard let url = URL(string: source) else { return source }
    let path = url.path
        .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        .replacingOccurrences(of: "/", with: " · ")
    return path.isEmpty
        ? url.host?.replacingOccurrences(of: "www.", with: "") ?? source
        : path
}

struct ChannelDiscovery {
    func discover(
        _ source: String,
        maximumItems: Int
    ) async throws -> DiscoveredChannel {
        #if os(macOS)
        let batch = try await NativeChannelInputRouter().enumerate(
            source: source,
            maximumItems: maximumItems
        )
        return DiscoveredChannel(
            title: batch.title,
            kind: batch.kind,
            items: batch.items.map { item in
                .init(
                    id: item.id,
                    title: item.title,
                    url: item.url.absoluteString,
                    publishedAt: item.publishedAt,
                    content: item.hints.content,
                    linkedURL: item.hints.mediaURL?.absoluteString,
                    preferredInput: item.hints.preferredInput,
                    mediaURL: item.hints.mediaURL?.absoluteString,
                    transcriptURL: item.hints.transcriptURL?.absoluteString,
                    transcriptType: item.hints.transcriptType,
                    transcriptLanguage: item.hints.transcriptLanguage
                )
            }
        )
        #else
        throw LibraryError.processingUnavailable
        #endif
    }
}

#if os(macOS)
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

func parseHackerNews(
    _ html: String,
    sourceURL: URL,
    maximumItems: Int = 5
) -> DiscoveredChannel? {
    guard
        maximumItems > 0,
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
        if items.count >= maximumItems { break }
    }
    return items.isEmpty ? nil : DiscoveredChannel(
        title: "Hacker News front page",
        kind: .feed,
        items: items
    )
}

private func htmlAttribute(_ name: String, in tag: String) -> String {
    inputHTMLAttribute(name, in: tag)
}

#endif

func validChannelSource(_ source: String) -> Bool {
    let value = source.trimmingCharacters(in: .whitespacesAndNewlines)
    if value.lowercased().hasPrefix("arxiv:") {
        return !String(value.dropFirst("arxiv:".count))
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    return httpURL(value) != nil
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
