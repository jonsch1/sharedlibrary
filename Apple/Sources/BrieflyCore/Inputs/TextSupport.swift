import Foundation

func nativeFirstUsefulLine(_ text: String) -> String {
    let trimming = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{FEFF}"))
    return text.components(separatedBy: .newlines)
        .map { $0.trimmingCharacters(in: trimming) }
        .first(where: { !$0.isEmpty })
        .map { String($0.trimmingCharacters(in: CharacterSet(charactersIn: "# ")).prefix(80)) } ??
        "Clipboard capture"
}

func inputRegexCapture(_ value: String, _ pattern: String, group: Int = 1) -> String? {
    guard let regex = try? NSRegularExpression(pattern: pattern),
          let match = regex.firstMatch(in: value, range: NSRange(location: 0, length: value.utf16.count)),
          match.numberOfRanges > group, let range = Range(match.range(at: group), in: value) else { return nil }
    return String(value[range])
}

func inputRegexCaptures(_ value: String, _ pattern: String) -> [String] {
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
    return regex.matches(in: value, range: NSRange(location: 0, length: value.utf16.count)).compactMap {
        let group = $0.numberOfRanges > 1 ? 1 : 0
        guard let range = Range($0.range(at: group), in: value) else { return nil }
        return String(value[range])
    }
}

func inputHTMLAttribute(_ name: String, in tag: String) -> String {
    let escapedName = NSRegularExpression.escapedPattern(for: name)
    let pattern = #"(?is)(?:^|\s)"# + escapedName + #"\s*=\s*(?:[\"']([^\"']*)[\"']|([^\s>]+))"#
    guard let regex = try? NSRegularExpression(pattern: pattern),
          let match = regex.firstMatch(in: tag, range: NSRange(location: 0, length: tag.utf16.count)) else {
        return ""
    }
    for group in 1..<match.numberOfRanges {
        guard match.range(at: group).location != NSNotFound,
              let range = Range(match.range(at: group), in: tag) else { continue }
        return String(tag[range])
    }
    return ""
}

func cleanInputText(_ value: String?) -> String? {
    guard let value else { return nil }
    let result = inputDecodeHTML(value)
        .replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
        .replacingOccurrences(of: #"\n\s*\n\s*\n+"#, with: "\n\n", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    return result.nativeNilIfEmpty
}

func inputUsefulText(_ value: String?, minimumLength: Int) -> String? {
    guard let text = cleanInputText(value), text.count >= minimumLength else { return nil }
    return text
}

func inputCountLabel(_ raw: Any?, _ singular: String, _ plural: String) -> String? {
    let count = (raw as? NSNumber)?.intValue ?? (raw as? String).flatMap(Int.init)
    guard let count else { return nil }
    return "\(count) \(count == 1 ? singular : plural)"
}

func truncateInputText(_ value: String, maximumLength: Int) -> String {
    guard maximumLength > 0, value.utf16.count > maximumLength else { return value }
    let prefix = value.utf16.prefix(maximumLength - 1)
    return String(decoding: prefix, as: UTF16.self)
        .trimmingCharacters(in: .whitespacesAndNewlines) + "…"
}

func inputDecodeHTML(_ value: String) -> String {
    var text = value
    for (entity, replacement) in [("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"), ("&nbsp;", " ")] {
        text = text.replacingOccurrences(of: entity, with: replacement, options: .caseInsensitive)
    }
    guard let regex = try? NSRegularExpression(pattern: #"&#(?:x([0-9A-Fa-f]+)|(\d+));"#) else { return text }
    for match in regex.matches(in: text, range: NSRange(location: 0, length: text.utf16.count)).reversed() {
        guard let range = Range(match.range, in: text) else { continue }
        let hexadecimal = match.range(at: 1).location != NSNotFound
        let group = hexadecimal ? 1 : 2
        guard let valueRange = Range(match.range(at: group), in: text),
              let value = UInt32(text[valueRange], radix: hexadecimal ? 16 : 10), let scalar = UnicodeScalar(value) else { continue }
        text.replaceSubrange(range, with: String(Character(scalar)))
    }
    return text
}

extension String {
    var nativeNilIfEmpty: String? { isEmpty ? nil : self }
}
