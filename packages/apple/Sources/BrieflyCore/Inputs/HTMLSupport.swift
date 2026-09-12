import Foundation

struct InputHTMLMetadata {
    var title: String?
    var description: String?
    var articleBody: String?
    var siteName: String?
    var canonicalURL: URL?
    var faviconURL: URL?
}

private func inputJSONLDEntries(_ html: String) -> [[String: Any]] {
    guard let regex = try? NSRegularExpression(
        pattern: #"(?is)<script\b([^>]*)>([\s\S]*?)</script\s*>"#
    ) else { return [] }
    var entries = [[String: Any]]()
    for match in regex.matches(in: html, range: NSRange(location: 0, length: html.utf16.count)) {
        guard let attributesRange = Range(match.range(at: 1), in: html),
              let bodyRange = Range(match.range(at: 2), in: html),
              inputHTMLAttribute("type", in: String(html[attributesRange]))
                .lowercased().contains("ld+json") else { continue }
        let body = String(html[bodyRange])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = body.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data) else { continue }
        inputFlattenJSONLD(value, into: &entries)
    }
    return entries
}

private func inputFlattenJSONLD(_ value: Any, into entries: inout [[String: Any]]) {
    if let values = value as? [Any] {
        values.forEach { inputFlattenJSONLD($0, into: &entries) }
    } else if let object = value as? [String: Any] {
        entries.append(object)
        if let graph = object["@graph"] { inputFlattenJSONLD(graph, into: &entries) }
    }
}

private func inputJSONLDText(_ value: Any?) -> String? {
    if let value = value as? String { return cleanInputText(value) }
    if let object = value as? [String: Any] {
        for key in ["@value", "value", "name"] {
            if let result = inputJSONLDText(object[key]) { return result }
        }
    }
    return nil
}

private func inputJSONLDPublisherName(_ value: Any?) -> String? {
    if let values = value as? [Any] {
        return values.compactMap(inputJSONLDPublisherName).first
    }
    guard let object = value as? [String: Any] else { return nil }
    return inputJSONLDText(object["name"])
}

func inputHTMLMetadata(_ html: String, baseURL: URL) -> InputHTMLMetadata {
    let metaTags = inputRegexCaptures(html, #"(?is)<meta\b[^>]*>"#)
    let jsonLD = inputJSONLDEntries(html)
    func meta(_ names: [String]) -> String? {
        metaTags.first { tag in
            let key = inputHTMLAttribute("property", in: tag).nativeNilIfEmpty ??
                inputHTMLAttribute("name", in: tag)
            return names.contains(key.lowercased())
        }.map { inputDecodeHTML(inputHTMLAttribute("content", in: $0)) }.flatMap(cleanInputText)
    }
    let documentTitle = inputRegexCapture(
        html,
        #"(?is)<title[^>]*>(.*?)</title>"#
    ).map { inputDecodeHTML(inputStripHTML($0)) }.flatMap(cleanInputText)
    let title = meta(["og:title", "twitter:title"]) ??
        jsonLD.compactMap { inputJSONLDText($0["headline"]) }.first ??
        jsonLD.compactMap { inputJSONLDText($0["name"]) }.first ??
        documentTitle
    let description = meta(["og:description", "description", "twitter:description"]) ??
        jsonLD.compactMap { inputJSONLDText($0["description"]) }.first
    let siteName = meta(["og:site_name", "application-name"]) ??
        jsonLD.compactMap { inputJSONLDPublisherName($0["publisher"]) }.first
    let articleBody = jsonLD.compactMap { inputJSONLDText($0["articleBody"]) }.first
    let links = inputRegexCaptures(html, #"(?is)<link\b[^>]*>"#)
    let canonical = links.first {
        inputHTMLAttribute("rel", in: $0).lowercased().split(whereSeparator: \.isWhitespace).contains("canonical")
    }.map { inputHTMLAttribute("href", in: $0) }
    let icon = links.first {
        let relations = inputHTMLAttribute("rel", in: $0).lowercased().split(whereSeparator: \.isWhitespace)
        return relations.contains("icon") || relations.contains("shortcut") ||
            relations.contains(where: { $0.hasSuffix("-icon") })
    }.map { inputHTMLAttribute("href", in: $0) }
    return .init(
        title: cleanInputText(title),
        description: cleanInputText(description),
        articleBody: cleanInputText(articleBody),
        siteName: cleanInputText(siteName),
        canonicalURL: httpInputURL(canonical, relativeTo: baseURL),
        faviconURL: httpInputURL(icon, relativeTo: baseURL) ?? URL(string: "/favicon.ico", relativeTo: baseURL)?.absoluteURL
    )
}

func inputReadableHTML(_ html: String) -> String? {
    var candidates = [(html: String, weight: Int)]()
    for tag in ["article", "main"] {
        let pattern = #"(?is)<"# + tag + #"\b[^>]*>([\s\S]*?)</"# + tag + #"\s*>"#
        candidates += inputRegexCaptures(html, pattern).map { (html: $0, weight: tag == "article" ? 5_000 : 4_500) }
    }
    let contentPattern = #"(?is)<(?:div|section)\b[^>]*(?:class|id)\s*=\s*[\"'][^\"']*(?:article|content|post|story|entry|prose|body|text)[^\"']*[\"'][^>]*>([\s\S]*?)</(?:div|section)\s*>"#
    candidates += inputRegexCaptures(html, contentPattern).map { (html: $0, weight: 3_500) }
    candidates.append((html: html, weight: 0))

    let scored: [(text: String, score: Int)] = candidates.compactMap { candidate in
        guard let text = inputHTMLToText(candidate.html), !text.isEmpty else { return nil }
        let punctuation = text.reduce(into: 0) { count, character in
            if ".!?;:".contains(character) { count += 1 }
        }
        let score = candidate.weight + min(text.count, 20_000) / 10 + punctuation * 2
        return (text: text, score: score)
    }
    return scored.max { $0.score < $1.score }?.text
}

func inputStructuredText(_ html: String) -> String? {
    let safeHTML = inputRemoveNonTextHTML(html)
    var segments = [String]()
    guard let regex = try? NSRegularExpression(
        pattern: #"(?is)<(h[1-6]|p|li|blockquote|pre)\b[^>]*>([\s\S]*?)</\1\s*>"#
    ) else { return inputHTMLToText(safeHTML) }
    for match in regex.matches(in: safeHTML, range: NSRange(location: 0, length: safeHTML.utf16.count)) {
        guard let tagRange = Range(match.range(at: 1), in: safeHTML),
              let fragmentRange = Range(match.range(at: 2), in: safeHTML),
              let text = inputHTMLToText(String(safeHTML[fragmentRange])), !text.isEmpty else {
            continue
        }
        let tag = String(safeHTML[tagRange]).lowercased()
        let value = tag == "li" ? "• \(text)" : text
        if !segments.contains(value) { segments.append(value) }
    }
    return segments.isEmpty ? inputHTMLToText(safeHTML) : segments.joined(separator: "\n")
}

func inputStripHTML(_ value: String) -> String {
    value.replacingOccurrences(of: #"(?is)<[^>]+>"#, with: " ", options: .regularExpression)
}

private func inputRemoveNonTextHTML(_ html: String) -> String {
    var value = html
    for pattern in [
        #"(?is)<!--.*?-->"#,
        #"(?is)<(script|style|noscript|template|svg|canvas|iframe|object|embed|nav|header|footer|form|aside|head)\b[^>]*>.*?</\1\s*>"#
    ] {
        value = value.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
    }
    return value
}

private func inputHTMLToText(_ html: String) -> String? {
    var value = inputRemoveNonTextHTML(html)
    value = value.replacingOccurrences(of: #"(?i)<br\s*/?>"#, with: "\n", options: .regularExpression)
    value = value.replacingOccurrences(
        of: #"(?i)<li\b[^>]*>"#, with: "\n• ", options: .regularExpression
    )
    value = value.replacingOccurrences(
        of: #"(?i)</(?:p|div|article|section|h[1-6]|li|blockquote|pre)\s*>"#,
        with: "\n",
        options: .regularExpression
    )
    value = value.replacingOccurrences(of: #"(?is)<[^>]+>"#, with: " ", options: .regularExpression)
    return cleanInputText(value)
}

func inputIsBinaryContentType(_ contentType: String) -> Bool {
    let value = contentType.lowercased()
    return [
        "application/pdf", "application/zip", "application/octet-stream",
        "audio/", "image/", "video/"
    ].contains(where: value.contains)
}

func inputLooksBinary(_ data: Data) -> Bool {
    let sample = [UInt8](data.prefix(4_096))
    guard !sample.isEmpty else { return false }
    if sample.contains(0) { return true }
    let suspicious = sample.reduce(into: 0) { count, byte in
        if byte < 8 || (byte > 13 && byte < 32) { count += 1 }
    }
    return Double(suspicious) / Double(sample.count) > 0.1
}

func assertInputTextDocument(_ response: InputHTTPResponse) throws {
    if inputIsBinaryContentType(response.contentType) ||
        response.data.starts(with: [0x50, 0x4B, 0x03, 0x04]) || inputLooksBinary(response.data) {
        throw NativeInputError.unsupportedInput
    }
}

func looksLikeInputInterstitial(_ value: String) -> Bool {
    let text = value.lowercased()
    return [
        "enable javascript", "checking your browser", "just a moment", "access denied",
        "recaptcha", "please wait for verification", "verify that you are human",
        "verify you are human", "page not found", "gateway timeout", "gateway time-out"
    ].contains(where: text.contains)
}

func looksLikeInputShell(title: String?, content: String) -> Bool {
    guard let title = cleanInputText(title)?.lowercased(), !title.isEmpty,
          let content = cleanInputText(content)?.lowercased(),
          content.split(whereSeparator: \.isWhitespace).count < 10 else { return false }
    return title == content
}

func usableNativeFallbackDraft(_ value: ItemDraft) -> ItemDraft? {
    var draft = value
    draft.title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
    draft.content = draft.content.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !draft.title.isEmpty, !draft.content.isEmpty,
          !looksLikeInputInterstitial("\(draft.title)\n\(draft.content)"),
          !looksLikeInputShell(title: draft.title, content: draft.content) else {
        return nil
    }
    return draft
}

func inputFileExtension(contentType: String, url: URL, data: Data) -> String {
    let type = contentType.split(separator: ";").first.map(String.init) ?? ""
    switch type {
    case "image/png": return "png"
    case "image/jpeg": return "jpg"
    case "image/gif": return "gif"
    case "image/webp": return "webp"
    case "image/x-icon", "image/vnd.microsoft.icon": return "ico"
    case "image/svg+xml": return "svg"
    case "audio/mp4": return "m4a"
    case "audio/mpeg": return "mp3"
    default:
        let bytes = [UInt8](data.prefix(12))
        if bytes.starts(with: [0x89, 0x50, 0x4e, 0x47]) { return "png" }
        if bytes.starts(with: [0xff, 0xd8, 0xff]) { return "jpg" }
        if bytes.starts(with: Array("GIF8".utf8)) { return "gif" }
        if bytes.starts(with: [0x00, 0x00, 0x01, 0x00]) { return "ico" }
        if bytes.starts(with: Array("RIFF".utf8)) && bytes.dropFirst(8).starts(with: Array("WEBP".utf8)) { return "webp" }
        return url.pathExtension.nativeNilIfEmpty ?? "bin"
    }
}
