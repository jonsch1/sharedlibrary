import Foundation

enum MarkdownRunStyle {
    case hidden
    case bold
    case italic
    case code
    case link
    case quote
    case heading(Int)
}
func markdownRuns(in text: String) -> [(NSRange, MarkdownRunStyle)] {
    let fullRange = NSRange(location: 0, length: text.utf16.count)
    var runs = [(NSRange, MarkdownRunStyle)]()

    func matches(_ pattern: String) -> [NSTextCheckingResult] {
        (try? NSRegularExpression(pattern: pattern))?.matches(
            in: text,
            range: fullRange
        ) ?? []
    }

    func addWrapped(_ match: NSTextCheckingResult, content: NSRange) {
        guard content.location != NSNotFound else { return }
        let prefix = NSRange(
            location: match.range.location,
            length: content.location - match.range.location
        )
        let suffix = NSRange(
            location: NSMaxRange(content),
            length: NSMaxRange(match.range) - NSMaxRange(content)
        )
        if prefix.length > 0 { runs.append((prefix, .hidden)) }
        if suffix.length > 0 { runs.append((suffix, .hidden)) }
    }

    for match in matches(#"\*\*([^*\n]+)\*\*|__([^_\n]+)__"#) {
        let content = match.range(at: 1).location == NSNotFound
            ? match.range(at: 2)
            : match.range(at: 1)
        runs.append((content, .bold))
        addWrapped(match, content: content)
    }
    for match in matches(#"(?<!\*)\*([^*\n]+)\*(?!\*)|(?<!_)_([^_\n]+)_(?!_)"#) {
        let content = match.range(at: 1).location == NSNotFound
            ? match.range(at: 2)
            : match.range(at: 1)
        runs.append((content, .italic))
        addWrapped(match, content: content)
    }
    for match in matches(#"`([^`\n]+)`"#) {
        let content = match.range(at: 1)
        runs.append((content, .code))
        addWrapped(match, content: content)
    }
    for match in matches(#"\[([^\]\n]+)\]\(([^)\n]+)\)"#) {
        let label = match.range(at: 1)
        runs.append((label, .link))
        addWrapped(match, content: label)
    }
    for match in matches(#"(?m)^>[ \t]+([^\n]*)$"#) {
        let content = match.range(at: 1)
        runs.append((content, .quote))
        let prefix = NSRange(
            location: match.range.location,
            length: content.location - match.range.location
        )
        runs.append((prefix, .hidden))
    }
    for match in matches(#"(?m)^(#{1,3})[ \t]+([^\n]+)$"#) {
        let marker = match.range(at: 1)
        let content = match.range(at: 2)
        runs.append((content, .heading(marker.length)))
        let prefix = NSRange(
            location: match.range.location,
            length: content.location - match.range.location
        )
        runs.append((prefix, .hidden))
    }
    return runs
}

func applyMarkdownStyling(
    to storage: NSMutableAttributedString,
    text: String,
    highlightedPassages: [String],
    baseAttributes: [NSAttributedString.Key: Any],
    attributesFor: (MarkdownRunStyle) -> [NSAttributedString.Key: Any],
    highlightAttributes: [NSAttributedString.Key: Any]
) {
    let range = NSRange(location: 0, length: text.utf16.count)
    storage.setAttributes(baseAttributes, range: range)
    for (range, style) in markdownRuns(in: text) {
        storage.addAttributes(attributesFor(style), range: range)
    }

    let source = text as NSString
    for passage in highlightedPassages where !passage.isEmpty {
        var searchRange = NSRange(location: 0, length: source.length)
        while searchRange.length > 0 {
            let found = source.range(of: passage, options: [], range: searchRange)
            guard found.location != NSNotFound else { break }
            storage.addAttributes(highlightAttributes, range: found)
            let next = NSMaxRange(found)
            searchRange = NSRange(location: next, length: source.length - next)
        }
    }
}

func highlightedPassages(in markdown: String) -> [String] {
    var passages = [String]()
    var quote = [String]()
    for line in markdown.components(separatedBy: .newlines) + [""] {
        if line.hasPrefix("> ") {
            quote.append(String(line.dropFirst(2)))
        } else if !quote.isEmpty {
            passages.append(quote.joined(separator: "\n"))
            quote.removeAll(keepingCapacity: true)
        }
    }
    return passages
}

func highlightedPassage(
    in source: NSString,
    passages: [String],
    intersecting selection: NSRange
) -> String? {
    for passage in passages where !passage.isEmpty {
        var searchRange = NSRange(location: 0, length: source.length)
        while searchRange.length > 0 {
            let found = source.range(of: passage, options: [], range: searchRange)
            guard found.location != NSNotFound else { break }
            if NSIntersectionRange(found, selection).length > 0 { return passage }
            let next = NSMaxRange(found)
            searchRange = NSRange(location: next, length: source.length - next)
        }
    }
    return nil
}
