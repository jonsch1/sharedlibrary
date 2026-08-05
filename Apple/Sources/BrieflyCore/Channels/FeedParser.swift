import Foundation

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
    private var text = ""
    private var item = DiscoveredChannel.Item(id: "", title: "", url: "")
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

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

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
            case "title": item.title = decodeHTML(stripHTML(value))
            case "guid", "id": item.id = value
            case "link" where item.url.isEmpty: item.url = value
            case "pubdate", "published", "updated": item.publishedAt = value.nilIfEmpty
            case "description", "summary", "content", "encoded":
                let content = stripHTML(value)
                if content.count > (item.content?.count ?? 0) { item.content = content.nilIfEmpty }
            default: break
            }
        } else if name == "title", channelTitle.isEmpty {
            channelTitle = decodeHTML(stripHTML(value))
        }
        if name == "item" || name == "entry" {
            if item.url.isEmpty, httpURL(item.id) != nil { item.url = item.id }
            if item.url.isEmpty, let mediaURL = item.mediaURL { item.url = mediaURL }
            if let baseURL, let url = URL(string: item.url, relativeTo: baseURL)?.absoluteURL {
                item.url = url.absoluteString
            }
            if let linkedURL = item.linkedURL,
               let url = URL(string: linkedURL, relativeTo: baseURL)?.absoluteURL {
                item.linkedURL = url.absoluteString
                item.mediaURL = url.absoluteString
            }
            if let transcriptURL = item.transcriptURL,
               let url = URL(string: transcriptURL, relativeTo: baseURL)?.absoluteURL {
                item.transcriptURL = url.absoluteString
            }
            if item.id.isEmpty { item.id = item.url }
            if item.title.isEmpty { item.title = item.content?.prefix(100).description ?? "Untitled" }
            if httpURL(item.url) != nil, !item.id.isEmpty { items.append(item) }
            inItem = false
        }
        text = ""
    }

    private func localName(_ value: String) -> String {
        value.split(separator: ":").last?.lowercased() ?? value.lowercased()
    }
}

func stripHTML(_ value: String) -> String {
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

func decodeHTML(_ value: String) -> String {
    var text = value
    for (entity, replacement) in [
        ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""),
        ("&#39;", "'"), ("&apos;", "'"), ("&nbsp;", " ")
    ] {
        text = text.replacingOccurrences(of: entity, with: replacement, options: .caseInsensitive)
    }
    return text
}
