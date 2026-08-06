import Foundation

func ingestX(
    _ request: ItemInputRequest,
    http: InputHTTPClient
) async throws -> ItemDraft {
    let url = try requestURL(request)
    guard let status = xStatus(url) else { throw NativeInputError.unsupportedInput }
    let endpoint = URL(string: "https://api.fxtwitter.com/2/status/\(status.id)")!
    let response = try await http.get(endpoint, headers: [
        "Accept": "application/json", "User-Agent": "Briefly/1.0"
    ])
    guard
        let object = try JSONSerialization.jsonObject(with: response.data) as? [String: Any],
        let tweet = object["status"] as? [String: Any]
    else { throw NativeInputError.unreadableContent }
    return try xDraft(from: tweet, sourceURL: url)
}

func xDraft(from tweet: [String: Any], sourceURL url: URL) throws -> ItemDraft {
    let status = xStatus(url)
    let author = tweet["author"] as? [String: Any]
    let screenName = cleanXArticleText(author?["screen_name"] as? String)
    let actor = status?.actor ?? screenName ?? "x"
    let statusID = status?.id ?? xStringValue(tweet["id"]) ?? ""
    let canonicalURL = statusID.isEmpty
        ? url
        : URL(string: "https://x.com/\(actor)/status/\(statusID)")

    if let article = tweet["article"] as? [String: Any] {
        let title = cleanXArticleText(article["title"] as? String) ?? "X article"
        let rendered = renderXArticle(article)
        let content = rendered.nativeNilIfEmpty ??
            cleanXArticleText(article["preview_text"] as? String)
        guard let content else { throw NativeInputError.unreadableContent }
        return ItemDraft(
            inputID: .x,
            title: title,
            content: content,
            sourceURL: url,
            canonicalURL: canonicalURL,
            faviconURL: URL(string: "https://x.com/favicon.ico")
        )
    }
    let rawText = tweet["raw_text"] as? String ??
        (tweet["raw_text"] as? [String: Any])?["text"] as? String ??
        (tweet["text"] as? String)
    let cleanedText = cleanXArticleText(rawText)
    let text = cleanedText ?? "[Media post]"
    let name = cleanXArticleText(author?["name"] as? String)
    let authorLine = name.flatMap { name in screenName.map { "\(name) (@\($0))" } } ??
        name ?? screenName.map { "@\($0)" } ?? "X user"
    let stats = [
        xCountLabel(tweet["replies"], "reply", "replies"),
        xCountLabel(tweet["reposts"] ?? tweet["retweets"], "repost", "reposts"),
        xCountLabel(tweet["likes"], "like", "likes"),
        xCountLabel(tweet["bookmarks"], "bookmark", "bookmarks"),
        xCountLabel(tweet["views"], "view", "views")
    ].compactMap { $0 }
    let quote = tweet["quote"] as? [String: Any]
    let quotedRaw = quote?["raw_text"] as? String ??
        (quote?["raw_text"] as? [String: Any])?["text"] as? String ??
        quote?["text"] as? String
    let quotedText = cleanXArticleText(quotedRaw)
    let quotedAuthor = cleanXArticleText(
        (quote?["author"] as? [String: Any])?["screen_name"] as? String
    )
    let card = tweet["twitter_card"] as? [String: Any]
    let bindings = card?["binding_values"] as? [String: Any]
    let cardValue = bindings?["card_url"] as? [String: Any]
    let cardURL = cleanXArticleText(
        card?["url"] as? String ?? card?["card_url"] as? String ??
            cardValue?["string_value"] as? String
    )

    var contentLines = [
        authorLine,
        cleanXArticleText(tweet["created_at"] as? String) ?? "",
        "",
        text
    ]
    let replyingTo = cleanXArticleText(tweet["replying_to"] as? String) ??
        cleanXArticleText(
            (tweet["replying_to"] as? [String: Any])?["screen_name"] as? String
        )
    if let replyingTo {
        contentLines.append("Replying to @\(replyingTo)")
    }
    if let quotedText {
        contentLines.append(
            "\n> \(quotedAuthor.map { "@\($0): " } ?? "")" +
                quotedText.replacingOccurrences(of: "\n", with: "\n> ")
        )
    }
    if let cardURL { contentLines.append("\nLink: \(cardURL)") }
    if !stats.isEmpty { contentLines.append("\n\(stats.joined(separator: " · "))") }
    let titleSuffix = cleanedText.map {
        ": \(truncateInputText($0, maximumLength: 90))"
    } ?? ""

    return ItemDraft(
        inputID: .x,
        title: "Post by \(authorLine)\(titleSuffix)",
        content: contentLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines),
        sourceURL: url,
        canonicalURL: canonicalURL,
        faviconURL: URL(string: "https://x.com/favicon.ico")
    )
}

func renderXArticle(_ article: [String: Any]) -> String {
    let content = article["content"] as? [String: Any]
    let blocks = (content?["blocks"] as? [Any] ?? []).compactMap { $0 as? [String: Any] }
    let entities = xEntityMap(content?["entityMap"])
    let mediaURLs = xMediaURLs(article["media_entities"])

    var renderedBlocks = [String]()
    if let coverURL = xCleanText(
        ((article["cover_media"] as? [String: Any])?["media_info"] as? [String: Any])?[
            "original_img_url"
        ] as? String
    ) {
        renderedBlocks.append("![Cover image](\(xMarkdownURL(coverURL)))")
    }

    for block in blocks {
        let rendered = renderXBlock(block, entities: entities, mediaURLs: mediaURLs)
        if !rendered.isEmpty { renderedBlocks.append(rendered) }
    }
    return cleanXArticleText(renderedBlocks.joined(separator: "\n\n")) ?? ""
}

private func renderXBlock(
    _ block: [String: Any],
    entities: [String: [String: Any]],
    mediaURLs: [String: String]
) -> String {
    let type = xCleanText(block["type"]) ?? "unstyled"
    if type == "atomic" {
        return renderXAtomicBlock(block, entities: entities, mediaURLs: mediaURLs)
    }

    let text = renderXInlineText(block, entities: entities)
    if text.isEmpty { return "" }

    let headingLevels = [
        "header-one": 1, "header-two": 2, "header-three": 3,
        "header-four": 4, "header-five": 5, "header-six": 6
    ]
    if let level = headingLevels[type] {
        return "\(String(repeating: "#", count: level)) \(text)"
    }

    let depth = max(0, xInteger(block["depth"]) ?? 0)
    let indentation = String(repeating: "  ", count: depth)
    switch type {
    case "unordered-list-item": return "\(indentation)- \(text)"
    case "ordered-list-item": return "\(indentation)1. \(text)"
    case "blockquote":
        return text.components(separatedBy: "\n").map { "> \($0)" }.joined(separator: "\n")
    case "code-block":
        let fence = text.contains("```") ? "````" : "```"
        return "\(fence)\n\(text)\n\(fence)"
    default: return text
    }
}

private func renderXAtomicBlock(
    _ block: [String: Any],
    entities: [String: [String: Any]],
    mediaURLs: [String: String]
) -> String {
    var media = [String]()
    for range in xRanges(block["entityRanges"], textLength: nil) {
        guard let entity = entities[String(range.key)], entity["type"] as? String == "MEDIA",
              let data = entity["data"] as? [String: Any],
              let items = data["mediaItems"] as? [Any] else { continue }
        for item in items {
            guard let item = item as? [String: Any] else { continue }
            guard let mediaID = xStringValue(item["mediaId"]), let mediaURL = mediaURLs[mediaID] else {
                continue
            }
            let rendered = "![Article image](\(xMarkdownURL(mediaURL)))"
            if !media.contains(rendered) { media.append(rendered) }
        }
    }
    return media.joined(separator: "\n\n")
}

private func renderXInlineText(
    _ block: [String: Any],
    entities: [String: [String: Any]]
) -> String {
    guard let value = block["text"] as? String, !value.isEmpty else { return "" }
    let textLength = value.utf16.count
    let styleRanges = xRanges(block["inlineStyleRanges"], textLength: textLength).compactMap {
        range -> XStyleRange? in
        guard let object = range.object else { return nil }
        let rawStyle = object["value"] ?? object["style"]
        guard let style = xCleanText(rawStyle)?.uppercased(), !style.isEmpty else { return nil }
        return .init(offset: range.offset, length: range.length, value: style)
    }
    let entityRanges = xRanges(block["entityRanges"], textLength: textLength).compactMap {
        range -> XEntityRange? in
        guard let entity = entities[String(range.key)] else { return nil }
        return .init(offset: range.offset, length: range.length, entity: entity)
    }

    var boundaries = Set([0, textLength])
    for range in styleRanges {
        boundaries.insert(range.offset)
        boundaries.insert(range.offset + range.length)
    }
    for range in entityRanges {
        boundaries.insert(range.offset)
        boundaries.insert(range.offset + range.length)
    }
    let sortedBoundaries = boundaries.sorted()
    var segments = [XInlineSegment]()
    for index in 0..<(max(0, sortedBoundaries.count - 1)) {
        let start = sortedBoundaries[index]
        let end = sortedBoundaries[index + 1]
        guard end > start else { continue }
        let styles = styleRanges
            .filter { $0.offset <= start && $0.offset + $0.length >= end }
            .map(\.value)
            .sorted()
        let link = entityRanges.first {
            guard $0.offset <= start && $0.offset + $0.length >= end,
                  $0.entity["type"] as? String == "LINK",
                  let data = $0.entity["data"] as? [String: Any] else { return false }
            return xCleanText(data["url"]) != nil
        }.flatMap { xCleanText(($0.entity["data"] as? [String: Any])?["url"]) }
        let segment = XInlineSegment(
            signature: "\(styles.joined(separator: ","))|\(link ?? "")",
            text: xSubstring(value, offset: start, length: end - start),
            styles: styles,
            link: link
        )
        if segments.last?.signature == segment.signature {
            segments[segments.count - 1].text += segment.text
        } else {
            segments.append(segment)
        }
    }
    return segments.map(renderXInlineSegment).joined()
}

private func renderXInlineSegment(_ segment: XInlineSegment) -> String {
    guard !segment.text.isEmpty,
          !segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        return segment.text
    }
    let leadingWhitespace = String(segment.text.prefix(while: { $0.isWhitespace }))
    let trailingWhitespace = String(segment.text.reversed().prefix(while: { $0.isWhitespace }).reversed())
    let contentStart = segment.text.index(segment.text.startIndex, offsetBy: leadingWhitespace.count)
    let contentEnd = segment.text.index(
        segment.text.endIndex,
        offsetBy: -trailingWhitespace.count
    )
    var content = String(segment.text[contentStart..<contentEnd])

    if segment.styles.contains("CODE") || segment.styles.contains("MONOSPACE") {
        let marker = content.contains("`") ? "``" : "`"
        content = "\(marker)\(content)\(marker)"
    }
    if segment.styles.contains("BOLD") { content = "**\(content)**" }
    if segment.styles.contains("ITALIC") { content = "_\(content)_" }
    if segment.styles.contains("STRIKETHROUGH") { content = "~~\(content)~~" }
    if segment.styles.contains("UNDERLINE") { content = "<u>\(content)</u>" }
    if let link = segment.link {
        content = "[\(content.replacingOccurrences(of: "]", with: "\\]"))](\(xMarkdownURL(link)))"
    }
    return leadingWhitespace + content + trailingWhitespace
}

private struct XRawRange {
    let offset: Int
    let length: Int
    let key: String
    let object: [String: Any]?
}

private struct XStyleRange {
    let offset: Int
    let length: Int
    let value: String
}

private struct XEntityRange {
    let offset: Int
    let length: Int
    let entity: [String: Any]
}

private struct XInlineSegment {
    let signature: String
    var text: String
    let styles: [String]
    let link: String?
}

private func xRanges(_ raw: Any?, textLength: Int?) -> [XRawRange] {
    guard let ranges = raw as? [Any] else { return [] }
    return ranges.compactMap { rawRange in
        guard let object = rawRange as? [String: Any] else { return nil }
        guard let offset = xInteger(object["offset"]), let length = xInteger(object["length"]),
              offset >= 0, length > 0,
              textLength.map({ offset <= $0 && length <= $0 - offset }) ?? true else { return nil }
        return XRawRange(
            offset: offset,
            length: length,
            key: xStringValue(object["key"]) ?? "",
            object: object
        )
    }
}

private func xEntityMap(_ raw: Any?) -> [String: [String: Any]] {
    if let object = raw as? [String: Any] {
        return object.compactMapValues { $0 as? [String: Any] }
    }
    guard let entries = raw as? [Any] else { return [:] }
    return entries.reduce(into: [String: [String: Any]]()) { result, rawEntry in
        guard let entry = rawEntry as? [String: Any] else { return }
        guard let key = xStringValue(entry["key"]), let value = entry["value"] as? [String: Any] else {
            return
        }
        result[key] = value
    }
}

private func xMediaURLs(_ raw: Any?) -> [String: String] {
    guard let media = raw as? [Any] else { return [:] }
    return media.reduce(into: [String: String]()) { result, rawItem in
        guard let item = rawItem as? [String: Any] else { return }
        guard let mediaID = xStringValue(item["media_id"]),
              let info = item["media_info"] as? [String: Any],
              let url = xCleanText(info["original_img_url"] as? String),
              !mediaID.isEmpty else { return }
        result[mediaID] = url
    }
}

private func xSubstring(_ value: String, offset: Int, length: Int) -> String {
    let utf16 = value.utf16
    guard offset >= 0, length >= 0, offset + length <= utf16.count else { return "" }
    let start = utf16.index(utf16.startIndex, offsetBy: offset)
    let end = utf16.index(start, offsetBy: length)
    return String(decoding: utf16[start..<end], as: UTF16.self)
}

private func xStringValue(_ value: Any?) -> String? {
    if let value = value as? String { return value }
    if let value = value as? NSNumber { return value.stringValue }
    return nil
}

private func xInteger(_ value: Any?) -> Int? {
    guard let value = xStringValue(value), let number = Double(value), number.isFinite,
          number.rounded() == number, number >= Double(Int.min), number <= Double(Int.max) else {
        return nil
    }
    return Int(number)
}

private func xCleanText(_ value: Any?) -> String? {
    guard let value = xStringValue(value) else { return nil }
    return value.trimmingCharacters(in: .whitespacesAndNewlines).nativeNilIfEmpty
}

private func cleanXArticleText(_ value: String?) -> String? {
    guard let value else { return nil }
    return value.trimmingCharacters(in: .whitespacesAndNewlines)
        .replacingOccurrences(of: "\u{200B}", with: "")
        .replacingOccurrences(of: "\u{200C}", with: "")
        .replacingOccurrences(of: "\u{200D}", with: "")
        .replacingOccurrences(of: "\u{2060}", with: "")
        .replacingOccurrences(of: "\u{FEFF}", with: "")
        .nativeNilIfEmpty
}

private func xMarkdownURL(_ value: String) -> String {
    value.replacingOccurrences(of: "(", with: "%28")
        .replacingOccurrences(of: ")", with: "%29")
}

private func xCountLabel(_ raw: Any?, _ singular: String, _ plural: String) -> String? {
    guard let string = xStringValue(raw), let number = Double(string), number.isFinite else {
        return nil
    }
    let formatter = NumberFormatter()
    formatter.locale = Locale(identifier: "en_US")
    formatter.numberStyle = .decimal
    formatter.maximumFractionDigits = 3
    formatter.minimumFractionDigits = 0
    let rendered = formatter.string(from: NSNumber(value: number)) ?? string
    return "\(rendered) \(number == 1 ? singular : plural)"
}
