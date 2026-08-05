import Foundation

func inputBatch(_ channel: DiscoveredChannel, channelInput: ChannelInputID) throws -> ChannelInputBatch {
    let itemInput: ItemInputID? = switch channelInput {
    case .youtube: .youtube
    case .podcast: .podcast
    case .reddit: .reddit
    case .arxiv: .arxiv
    default: nil
    }
    let items = channel.items.compactMap { item -> ChannelItemReference? in
        guard let url = httpInputURL(item.url), !item.id.isEmpty else { return nil }
        return .init(
            id: item.id,
            title: cleanInputText(item.title) ?? "Untitled",
            url: url,
            publishedAt: item.publishedAt,
            hints: .init(
                preferredInput: item.preferredInput ?? itemInput ??
                    (channel.kind == .podcast ? .podcast : nil),
                title: cleanInputText(item.title),
                content: item.content,
                mediaURL: httpInputURL(item.mediaURL ?? item.linkedURL),
                transcriptURL: httpInputURL(item.transcriptURL),
                transcriptType: item.transcriptType,
                transcriptLanguage: item.transcriptLanguage
            )
        )
    }
    guard !items.isEmpty else { throw NativeInputError.unreadableContent }
    return .init(inputID: channelInput, title: channel.title, kind: channel.kind, items: items)
}

func inputLimitedBatch(_ batch: ChannelInputBatch, maximumItems: Int) -> ChannelInputBatch {
    var batch = batch
    batch.items = batch.items.filter {
        !$0.id.isEmpty && isNativeHTTPURL($0.url) && $0.url.user == nil && $0.url.password == nil
    }.enumerated().map {
        (item: $0.element, index: $0.offset, date: inputChannelDate($0.element.publishedAt))
    }.sorted {
        if let left = $0.date, let right = $1.date { return left > right }
        return $0.index < $1.index
    }.prefix(max(0, maximumItems)).map { $0.item }
    return batch
}

func inputChannelDate(_ value: String?) -> Date? {
    guard let value else { return nil }
    let iso8601 = ISO8601DateFormatter()
    if let date = iso8601.date(from: value) { return date }
    iso8601.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = iso8601.date(from: value) { return date }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    for format in [
        "EEE, dd MMM yyyy HH:mm:ss Z",
        "EEE, dd MMM yyyy HH:mm Z",
        "EEE, dd MMM yyyy HH:mm:ss zzz",
        "yyyy-MM-dd HH:mm:ss Z",
        "yyyy-MM-dd HH:mm Z",
        "yyyy-MM-dd'T'HH:mm:ssXXXXX",
        "yyyy-MM-dd'T'HH:mm:ss.SSSXXXXX",
        "yyyy-MM-dd'T'HH:mm:ss.SSSSSSXXXXX",
        "yyyy-MM-dd"
    ] {
        formatter.dateFormat = format
        if let date = formatter.date(from: value) { return date }
    }
    return nil
}

func inputLooksLikeFeed(_ response: InputHTTPResponse) -> Bool {
    if response.contentType.contains("rss") || response.contentType.contains("atom") ||
        response.contentType.contains("xml") { return true }
    let prefix = String(decoding: response.data.prefix(2_000), as: UTF8.self)
        .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.init(charactersIn: "\u{FEFF}")))
        .lowercased()
    return prefix.contains("<rss") || prefix.contains("<feed") || prefix.contains("<rdf:rdf")
}

func inputDiscoveredFeedURL(in html: String, relativeTo base: URL) -> URL? {
    inputDiscoveredFeedURLs(in: html, relativeTo: base).first
}

func inputDiscoveredFeedURLs(in html: String, relativeTo base: URL) -> [URL] {
    var urls = [URL]()
    for tag in inputRegexCaptures(html, #"(?is)<link\b[^>]*>"#) {
        let type = inputHTMLAttribute("type", in: tag).lowercased()
        let rel = inputHTMLAttribute("rel", in: tag).lowercased()
        let relations = rel.split(whereSeparator: \.isWhitespace)
        guard relations.contains("alternate"), type.contains("rss") || type.contains("atom"),
              let url = httpInputURL(inputHTMLAttribute("href", in: tag), relativeTo: base) else {
            continue
        }
        if !urls.contains(url) { urls.append(url) }
    }
    return Array(urls.prefix(5))
}

func inputChannelTitle(_ source: String) -> String {
    if source.lowercased().hasPrefix("arxiv:") {
        return String(source.dropFirst("arxiv:".count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nativeNilIfEmpty ?? "arXiv"
    }
    guard let url = URL(string: source) else { return source }
    let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        .replacingOccurrences(of: "/", with: " · ")
    return path.nativeNilIfEmpty ?? url.host?.replacingOccurrences(of: "www.", with: "") ?? source
}
