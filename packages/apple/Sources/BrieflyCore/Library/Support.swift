import Foundation

func regexCapture(_ value: String, pattern: String) -> String? {
    guard
        let expression = try? NSRegularExpression(pattern: pattern),
        let match = expression.firstMatch(
            in: value,
            range: NSRange(value.startIndex..., in: value)
        ),
        let range = Range(match.range(at: 1), in: value)
    else {
        return nil
    }
    return String(value[range])
}

func json(_ value: Any) throws -> String {
    let data = try JSONSerialization.data(
        withJSONObject: value,
        options: [.prettyPrinted, .sortedKeys]
    )
    guard let text = String(data: data, encoding: .utf8) else {
        throw LibraryError.invalidProcessingPrompt
    }
    return text
}

func firstHeading(_ text: String) -> String? {
    text.components(separatedBy: .newlines)
        .first { $0.hasPrefix("# ") }
        .map { String($0.dropFirst(2)).trimmingCharacters(in: .whitespaces) }
}

func fileExtension(for mimeType: String) -> String {
    switch mimeType {
    case "image/svg+xml": "svg"
    case "image/jpeg": "jpg"
    case "audio/mp4": "m4a"
    default: mimeType.split(separator: "/").last.map(String.init) ?? "bin"
    }
}

func firstUsefulLine(_ text: String) -> String {
    text.components(separatedBy: .newlines)
        .map {
            String(
                $0.trimmingCharacters(in: .whitespaces)
                    .drop(while: { $0 == "#" })
            )
            .trimmingCharacters(in: .whitespaces)
        }
        .first(where: { !$0.isEmpty })
        .map { String($0.prefix(80)) } ?? "Clipboard capture"
}

func httpURL(_ value: String) -> URL? {
    guard
        !value.contains(where: \.isWhitespace),
        let url = URL(string: value),
        url.scheme == "http" || url.scheme == "https",
        url.host != nil,
        url.user == nil,
        url.password == nil
    else {
        return nil
    }
    return url
}

func libraryExcerpt(_ text: String) -> String {
    // The result is at most 240 characters; do not run every regex over a full document.
    var result = String(text.prefix(4_096))
    for (pattern, replacement) in [
        (#"```[\s\S]*?```"#, " "),
        (#"!\[[^\]]*\]\([^)]+\)"#, " "),
        (#"\[([^\]]+)\]\([^)]+\)"#, "$1"),
        (#"[#>*_~`-]"#, " "),
        (#"\s+"#, " ")
    ] {
        result = result.replacingOccurrences(
            of: pattern,
            with: replacement,
            options: .regularExpression
        )
    }
    result = result.trimmingCharacters(in: .whitespacesAndNewlines)
    return result.count > 240 ? "\(result.prefix(237).trimmingCharacters(in: .whitespaces))…" : result
}

func normalizedDocumentType(_ type: String) -> String {
    switch type {
    case "voice_brief_episode": "document"
    case "voice_brief_source": "link"
    default: type
    }
}

func normalizedDocumentTags(_ tags: [String]) -> [String] {
    tags.filter { $0.lowercased() != "voice-brief" }
}

func slug(_ value: String) -> String {
    let folded = value.folding(
        options: [.diacriticInsensitive, .caseInsensitive],
        locale: .current
    )
    let components = folded.components(separatedBy: CharacterSet.alphanumerics.inverted)
    let value = components.filter { !$0.isEmpty }.joined(separator: "-").lowercased()
    return String(value.prefix(64)).isEmpty ? "capture" : String(value.prefix(64))
}

func titleize(_ value: String) -> String {
    value.replacingOccurrences(of: "-", with: " ")
        .replacingOccurrences(of: "_", with: " ")
        .capitalized
}

func validFavicon(_ data: Data, fileExtension: String) -> Bool {
    let bytes = [UInt8](data.prefix(12))
    switch fileExtension {
    case "png":
        return bytes.starts(with: [0x89, 0x50, 0x4e, 0x47])
    case "jpg":
        return bytes.starts(with: [0xff, 0xd8, 0xff])
    case "gif":
        return bytes.starts(with: Array("GIF8".utf8))
    case "ico":
        return bytes.starts(with: [0x00, 0x00, 0x01, 0x00])
    case "webp":
        return bytes.starts(with: Array("RIFF".utf8)) &&
            bytes.dropFirst(8).starts(with: Array("WEBP".utf8))
    case "svg":
        let prefix = String(decoding: data.prefix(1_024), as: UTF8.self).lowercased()
        return prefix.contains("<svg")
    default:
        return false
    }
}


extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

extension Date {
    var iso8601: String {
        ISO8601DateFormatter().string(from: self)
    }
}
