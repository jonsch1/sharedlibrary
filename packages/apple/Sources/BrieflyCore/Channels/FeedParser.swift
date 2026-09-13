#if os(macOS)
import Foundation

private let feedPodcastNamespaceURLs: Set<String> = [
    "http://www.itunes.com/dtds/podcast-1.0.dtd",
    "https://podcastindex.org/namespace/1.0",
    "https://github.com/podcastindex-org/podcast-namespace/blob/main/docs/1.0.md"
]

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
            parser.parserError?.localizedDescription ?? "The feed did not contain any items."
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
    private var elementStack = [String]()
    private var textBuffers = [String]()
    private var item = DiscoveredChannel.Item(id: "", title: "", url: "")
    private var itemDateRank = 0
    var channelTitle = ""
    var isPodcast = false
    var items = [DiscoveredChannel.Item]()

    init(baseURL: URL?) { self.baseURL = baseURL }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        let name = localName(elementName)
        elementStack.append(name)
        textBuffers.append("")
        let attributes = attributeDict.reduce(into: [String: String]()) { result, pair in
            result[pair.key.lowercased()] = pair.value
        }
        let qualifiedName = (qName ?? elementName).lowercased()
        if attributes.keys.contains(where: {
            $0 == "xmlns:itunes" || $0 == "xmlns:podcast"
        }) || qualifiedName.hasPrefix("itunes:") || qualifiedName.hasPrefix("podcast:") ||
            feedPodcastNamespaceURLs.contains(namespaceURI?.lowercased() ?? "") {
            isPodcast = true
        }
        if name == "item" || name == "entry" {
            inItem = true
            item = .init(id: "", title: "", url: "")
            itemDateRank = 0
        } else if inItem, name == "link", let href = attributes["href"],
                  let url = httpInputURL(href, relativeTo: baseURL) {
            let relation = attributes["rel"]?.lowercased()
            if relation == "enclosure" {
                item.linkedURL = url.absoluteString
                item.mediaURL = url.absoluteString
                isPodcast = attributes["type"]?.lowercased().hasPrefix("audio/") == true || isPodcast
            } else if relation == nil || relation == "" || relation == "alternate" {
                if item.url.isEmpty { item.url = url.absoluteString }
            }
        } else if inItem, name == "enclosure", let rawURL = attributes["url"],
                  let url = httpInputURL(rawURL, relativeTo: baseURL) {
            item.linkedURL = url.absoluteString
            item.mediaURL = url.absoluteString
            isPodcast = attributes["type"]?.lowercased().hasPrefix("audio/") == true || isPodcast
        } else if inItem, name == "transcript", let rawURL = attributes["url"] {
            let type = nativeTranscriptType(attributes["type"], url: rawURL)
            if nativeTranscriptRank(type) > nativeTranscriptRank(item.transcriptType),
               let url = httpInputURL(rawURL, relativeTo: baseURL) {
                item.transcriptURL = url.absoluteString
                item.transcriptType = type
                item.transcriptLanguage = attributes["language"]
            }
            isPodcast = true
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        for index in textBuffers.indices { textBuffers[index] += string }
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        let value = String(decoding: CDATABlock, as: UTF8.self)
        for index in textBuffers.indices { textBuffers[index] += value }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let name = localName(elementName)
        let value = textBuffers.popLast() ?? ""
        _ = elementStack.popLast()
        let normalized = cleanInputText(value)
        if inItem {
            switch name {
            case "title": item.title = normalized.map(inputStripHTML).flatMap(cleanInputText) ?? ""
            case "guid", "id": item.id = normalized ?? ""
            case "link" where item.url.isEmpty:
                item.url = httpInputURL(normalized, relativeTo: baseURL)?.absoluteString ?? ""
            case "pubdate", "published", "updated", "date":
                let rank = ["pubdate", "published"].contains(name) ? 2 : 1
                if rank >= itemDateRank, let date = normalizedFeedDate(normalized) {
                    item.publishedAt = date
                    itemDateRank = rank
                }
            case "description", "summary", "content", "encoded":
                let content = cleanInputText(inputStripHTML(value))
                if (content?.count ?? 0) > (item.content?.count ?? 0) { item.content = content }
            default: break
            }
        } else if name == "title", channelTitle.isEmpty {
            channelTitle = normalized.map(inputStripHTML).flatMap(cleanInputText) ?? ""
        }
        if name == "item" || name == "entry" {
            if item.url.isEmpty, let url = httpInputURL(item.id) {
                item.url = url.absoluteString
            }
            if item.url.isEmpty, let mediaURL = item.mediaURL { item.url = mediaURL }
            if let url = httpInputURL(item.url, relativeTo: baseURL) {
                item.url = url.absoluteString
            }
            if item.id.isEmpty { item.id = item.url }
            if item.title.isEmpty {
                item.title = item.url
            }
            if httpInputURL(item.url) != nil, !item.id.isEmpty { items.append(item) }
            inItem = false
        }
    }

    private func localName(_ value: String) -> String {
        value.split(separator: ":").last?.lowercased() ?? value.lowercased()
    }
}

private func normalizedFeedDate(_ value: String?) -> String? {
    guard let value, let date = inputChannelDate(value) else { return nil }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
}

func stripHTML(_ value: String) -> String {
    var text = value
    for pattern in [
        #"(?is)<(script|style|noscript|template|svg|canvas|iframe|object|embed|nav|header|footer|form|aside)\b[^>]*>.*?</\1\s*>"#,
        #"(?i)<br\s*/?>"#,
        #"(?i)</(?:p|div|article|section|h[1-6]|li|blockquote|pre)\s*>"#,
        #"(?is)<[^>]+>"#
    ] {
        text = text.replacingOccurrences(
            of: pattern,
            with: pattern.contains("br") || pattern.contains("?:p") ? "\n" : " ",
            options: .regularExpression
        )
    }
    return decodeHTML(text)
        .replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
        .replacingOccurrences(of: #"\n\s*\n\s*\n+"#, with: "\n\n", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

func decodeHTML(_ value: String) -> String { inputDecodeHTML(value) }

#endif
