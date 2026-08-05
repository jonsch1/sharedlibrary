import Foundation

struct LibraryMarkdownImportService {
    let topics: SQLiteTopicRepository
    let voiceBriefs: SQLiteVoiceBriefRepository
    let markdown: SQLiteMarkdownRepository
    let channelState: LibraryChannelStateRepository
    let fileManager: FileManager

    func ingest(from root: URL) throws -> Int {
        let topics = try readTopics(from: root).map {
            LibraryTopicDefinition(id: $0.key, title: $0.value)
        }
        if !topics.isEmpty { try self.topics.replace(topics) }
        let imported = try markdown.ingest(from: root)
        let voiceBriefDirectory = root.appending(path: "voice-briefs", directoryHint: .isDirectory)
        if let urls = try? fileManager.contentsOfDirectory(
            at: voiceBriefDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) {
            for url in urls where
                url.pathExtension.lowercased() == "md" &&
                url.deletingPathExtension().lastPathComponent.lowercased() != "readme"
            {
                let parsed = parseMarkdown(try String(contentsOf: url, encoding: .utf8))
                _ = try voiceBriefs.save(LibraryVoiceBriefDraft(
                    id: parsed.scalar("id") ?? "file:\(url.lastPathComponent)",
                    title: parsed.scalar("name") ?? parsed.scalar("title") ??
                        url.deletingPathExtension().lastPathComponent,
                    schedule: parsed.scalar("schedule") ?? "manual",
                    length: parsed.scalar("length") ?? "",
                    sources: parsed.array("sources"),
                    prioritizeForMe: parsed.scalar("prioritize_for_me")?.lowercased() == "true"
                ))
            }
        }
        if
            let data = try? Data(contentsOf: channelState.channelStateURL(for: root)),
            let state = try? JSONDecoder().decode(VoiceBriefWatcherState.self, from: data),
            state.schemaVersion == 1
        {
            try channelState.write(state)
        }
        return imported
    }

    private func readTopics(from root: URL) throws -> [String: String] {
        let url = root.appending(path: "topics.md")
        guard fileManager.fileExists(atPath: url.path) else { return [:] }
        let lines = try String(contentsOf: url, encoding: .utf8)
            .components(separatedBy: .newlines)
        var currentID: String?
        var result = [String: String]()
        for line in lines {
            if let value = regexCapture(line, pattern: #"^\s*-\s+id:\s*(.+?)\s*$"#) {
                currentID = unquote(value)
            } else if
                let id = currentID,
                let value = regexCapture(line, pattern: #"^\s+title:\s*(.+?)\s*$"#)
            {
                result[id] = unquote(value)
                currentID = nil
            }
        }
        return result
    }

}

struct ParsedMarkdown {
    var metadata: [String: [String]]
    var frontmatter: String?
    var body: String

    func scalar(_ key: String) -> String? {
        metadata[key]?.first.flatMap { $0.isEmpty ? nil : $0 }
    }

    func array(_ key: String) -> [String] {
        metadata[key] ?? []
    }
}

func parseMarkdown(_ text: String) -> ParsedMarkdown {
    guard text.hasPrefix("---\n") || text.hasPrefix("---\r\n") else {
        return ParsedMarkdown(metadata: [:], frontmatter: nil, body: text)
    }
    let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
    guard
        let end = normalized.range(
            of: "\n---",
            range: normalized.index(normalized.startIndex, offsetBy: 4)..<normalized.endIndex
        )
    else {
        return ParsedMarkdown(metadata: [:], frontmatter: nil, body: text)
    }
    let metadataText = String(
        normalized[normalized.index(normalized.startIndex, offsetBy: 4)..<end.lowerBound]
    )
    let endIndex = normalized.index(end.lowerBound, offsetBy: 4)
    var body = String(normalized[endIndex...])
    body = body.trimmingCharacters(in: .whitespacesAndNewlines)
    var metadata = [String: [String]]()
    var activeList: String?
    for line in metadataText.components(separatedBy: "\n") {
        if
            let colon = line.firstIndex(of: ":"),
            !line[..<colon].contains(where: \.isWhitespace)
        {
            let key = String(line[..<colon])
            let value = String(line[line.index(after: colon)...])
                .trimmingCharacters(in: .whitespaces)
            metadata[key] = parseValues(value)
            activeList = value.isEmpty ? key : nil
        } else if
            let activeList,
            let value = regexCapture(line, pattern: #"^\s+-\s*(.*?)\s*$"#)
        {
            metadata[activeList, default: []].append(unquote(value))
        }
    }
    return ParsedMarkdown(
        metadata: metadata,
        frontmatter: String(normalized[..<endIndex]),
        body: body
    )
}

private func parseValues(_ value: String) -> [String] {
    let trimmed = value.trimmingCharacters(in: .whitespaces)
    if trimmed.isEmpty || trimmed == "[]" { return [] }
    if
        trimmed.hasPrefix("["),
        let data = trimmed.data(using: .utf8),
        let decoded = try? JSONDecoder().decode([String].self, from: data)
    {
        return decoded
    }
    return [unquote(trimmed)]
}


private func unquote(_ value: String) -> String {
    let trimmed = value.trimmingCharacters(in: .whitespaces)
    if
        trimmed.hasPrefix("\""),
        let data = trimmed.data(using: .utf8),
        let decoded = try? JSONDecoder().decode(String.self, from: data)
    {
        return decoded
    }
    return trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "'"))
}

private func quoted(_ value: String) -> String {
    let data = try? JSONEncoder().encode(value)
    return data.flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
}


private func serializeMetadata(_ metadata: [String: [String]]) -> String {
    let arrays: Set<String> = [
        "tags",
        "topics",
        "source_ids",
        "source_urls"
    ]
    let preferred = [
        "id",
        "type",
        "title",
        "created_at",
        "updated_at",
        "tags",
        "topics",
        "source_url",
        "media_url",
        "audio_path",
        "voice_brief_id",
        "voice_brief_title",
        "source_ids",
        "source_urls"
    ]
    let keys = preferred.filter { metadata[$0] != nil } +
        metadata.keys.filter { !preferred.contains($0) }.sorted()
    let lines = keys.flatMap { key -> [String] in
        let values = metadata[key] ?? []
        if arrays.contains(key) || values.count != 1 {
            return values.isEmpty
                ? ["\(key): []"]
                : ["\(key):"] + values.map { "  - \(quoted($0))" }
        }
        return ["\(key): \(quoted(values[0]))"]
    }
    return (["---"] + lines + ["---"]).joined(separator: "\n")
}

private func writeAtomically(_ text: String, to url: URL) throws {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try Data(text.utf8).write(to: url, options: .atomic)
}
