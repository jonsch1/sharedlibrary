import Foundation

private let podcastNamespaceURLs: Set<String> = [
    "https://podcastindex.org/namespace/1.0",
    "https://github.com/podcastindex-org/podcast-namespace/blob/main/docs/1.0.md"
]

struct PodcastEpisode {
    var title: String?
    var description: String?
    var guid: String?
    var link: URL?
    var mediaURL: URL?
    var transcriptURL: URL?
    var transcriptType: String?
    var transcriptLanguage: String?

    var hints: ItemInputHints {
        .init(
            preferredInput: .podcast,
            title: title,
            content: description,
            mediaURL: mediaURL,
            transcriptURL: transcriptURL,
            transcriptType: transcriptType,
            transcriptLanguage: transcriptLanguage
        )
    }
}

struct PodcastFeed {
    var title: String?
    var episodes: [PodcastEpisode]
}

func looksLikeNativePodcastPage(_ html: String, url: URL) -> Bool {
    url.host?.lowercased() == "podcasts.apple.com" ||
        html.range(of: #"[\"']PodcastEpisode[\"']"#, options: .regularExpression) != nil ||
        html.range(of: #"(?is)<audio\b"#, options: .regularExpression) != nil ||
        html.range(
            of: #"(?is)property=[\"']og:(?:audio|type)[\"'][^>]*content=[\"'][^\"']*(?:audio|podcast)"#,
            options: .regularExpression
        ) != nil
}

func podcastEpisodeScore(_ episode: PodcastEpisode, url: URL, title: String?) -> Int {
    var score = 0
    if samePodcastURL(episode.link, url) ||
        canonicalItemIdentity(episode.link) == canonicalItemIdentity(url) {
        score += 100
    }

    let pageTitle = cleanPodcastTitle(title)
    let episodeTitle = cleanPodcastTitle(episode.title)
    if let pageTitle, let episodeTitle {
        if pageTitle == episodeTitle {
            score += 20
        } else if pageTitle.contains(episodeTitle) || episodeTitle.contains(pageTitle) {
            score += 10
        }
    }

    if let guid = episode.guid?.lowercased(),
       guid.contains(url.absoluteString.lowercased()) {
        score += 2
    }
    return score
}

func podcastFeedURLs(
    html: String,
    pageURL: URL,
    http: InputHTTPClient
) async throws -> [URL] {
    var urls = inputDiscoveredFeedURLs(in: html, relativeTo: pageURL)
    urls.append(contentsOf: inputRegexCaptures(
        html,
        #"(?is)<a\b[^>]*href=[\"']([^\"']+)[\"'][^>]*>[\s\S]*?\b(?:rss|atom)\b[\s\S]*?</a>"#
    ).compactMap {
        httpInputURL(inputDecodeHTML($0), relativeTo: pageURL)
    })

    if pageURL.host?.lowercased() == "podcasts.apple.com",
       let id = inputRegexCapture(pageURL.path, #"/id(\d+)(?:/|$)"#) {
        var components = URLComponents(string: "https://itunes.apple.com/lookup")!
        components.queryItems = [
            URLQueryItem(name: "id", value: id),
            URLQueryItem(name: "entity", value: "podcast")
        ]
        if let endpoint = components.url,
           let response = try? await http.get(endpoint, headers: ["Accept": "application/json"]),
           let object = try? JSONSerialization.jsonObject(with: response.data) as? [String: Any],
           let results = object["results"] as? [[String: Any]],
           let feed = results.first(where: {
               ($0["kind"] as? String) == "podcast" && $0["feedUrl"] is String
           }),
           let feedURL = httpInputURL(feed["feedUrl"] as? String) {
            urls.insert(feedURL, at: 0)
        }
    }

    var unique = [URL]()
    for url in urls where !unique.contains(where: { samePodcastURL($0, url) }) {
        unique.append(url)
    }
    return Array(unique.prefix(3))
}

func parsePodcastTranscript(_ value: String, type: String?) -> String {
    let lower = type?.split(separator: ";", maxSplits: 1).first
        .map(String.init).map { $0.lowercased() } ?? ""

    if lower.contains("json"),
       let data = value.data(using: .utf8),
       let object = try? JSONSerialization.jsonObject(with: data) {
        if let segments = podcastTranscriptSegments(in: object), !segments.isEmpty {
            var previousSpeaker: String?
            let lines = segments.compactMap { segment -> String? in
                let body = podcastTranscriptText(in: segment)
                guard let body else { return nil }
                let speaker = ["speaker", "speaker_name", "speakerName"]
                    .compactMap { cleanInputText(segment[$0] as? String) }
                    .first
                let line = speaker != nil && speaker != previousSpeaker
                    ? "\(speaker!): \(body)"
                    : body
                previousSpeaker = speaker
                return line
            }
            if !lines.isEmpty { return lines.joined(separator: " ") }
        }

        var lines = [String]()
        var seen = Set<String>()
        func collect(_ value: Any) {
            if let object = value as? [String: Any] {
                for key in ["text", "body", "transcript", "content"] {
                    if let text = cleanInputText(object[key] as? String), seen.insert(text).inserted {
                        lines.append(text)
                    }
                }
                object.values.forEach(collect)
            } else if let array = value as? [Any] {
                array.forEach(collect)
            }
        }
        collect(object)
        return lines.joined(separator: "\n")
    }

    if lower.contains("html") {
        return inputReadableHTML(value) ?? ""
    }

    if lower.contains("vtt") || lower.contains("subrip") || lower.contains("srt") ||
        value.range(of: #"(?im)^\s*(?:WEBVTT|\d+)\s*$"#, options: .regularExpression) != nil {
        return parseTimedPodcastTranscript(value)
    }
    return cleanInputText(value) ?? ""
}

private func podcastTranscriptSegments(in value: Any) -> [[String: Any]]? {
    guard let object = value as? [String: Any] else { return nil }
    for key in ["segments", "utterances", "paragraphs", "cues"] {
        if let values = object[key] as? [[String: Any]], !values.isEmpty { return values }
        if let values = object[key] as? [Any] {
            let segments = values.compactMap { $0 as? [String: Any] }
            if !segments.isEmpty { return segments }
        }
    }
    return nil
}

private func podcastTranscriptText(in segment: [String: Any]) -> String? {
    for key in ["body", "text", "transcript", "content"] {
        if let value = cleanInputText(segment[key] as? String) { return value }
    }
    return nil
}

private func parseTimedPodcastTranscript(_ value: String) -> String {
    let normalized = value
        .replacingOccurrences(of: "\r\n", with: "\n")
        .replacingOccurrences(of: "\r", with: "\n")
        .replacingOccurrences(of: "\u{FEFF}", with: "")
    let timestampPattern = #"^\s*(?:\d{1,2}:)?\d{2}:\d{2}[.,]\d{3}\s+-->"#
    let blocks = normalized.components(separatedBy: "\n\n")
    return blocks.compactMap { block in
        let rawLines = block.components(separatedBy: .newlines)
        guard !rawLines.isEmpty else { return nil }
        let first = rawLines.first?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() ?? ""
        if first.hasPrefix("WEBVTT") || first.hasPrefix("NOTE") || first.hasPrefix("STYLE") ||
            first.hasPrefix("REGION") {
            return nil
        }
        let lines = rawLines.filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            return !trimmed.isEmpty &&
                trimmed.range(of: #"^\d+$"#, options: .regularExpression) == nil &&
                trimmed.range(of: timestampPattern, options: .regularExpression) == nil &&
                !trimmed.contains(" --> ")
        }
        guard !lines.isEmpty else { return nil }
        let transcript = lines.joined(separator: " ")
            .replacingOccurrences(of: #"<v\s+([^>]+)>"#, with: "$1: ", options: .regularExpression)
        return cleanInputText(inputStripHTML(inputDecodeHTML(transcript)))
    }.joined(separator: "\n")
}

func parseNativePodcastFeed(_ data: Data, baseURL: URL?) -> PodcastFeed? {
    let delegate = PodcastFeedParser(baseURL: baseURL)
    let parser = XMLParser(data: data)
    parser.shouldProcessNamespaces = true
    parser.delegate = delegate
    guard parser.parse(), !delegate.episodes.isEmpty, delegate.isPodcast else { return nil }
    return PodcastFeed(title: delegate.feedTitle.nativeNilIfEmpty, episodes: delegate.episodes)
}

private struct NativePodcastElement {
    let name: String
    let qualifiedName: String
    let namespaceURI: String?
    let attributes: [String: String]
    var text: String
}

final class PodcastFeedParser: NSObject, XMLParserDelegate {
    private let baseURL: URL?
    private var stack = [NativePodcastElement]()
    private var inItem = false
    private var episode = PodcastEpisode()
    var feedTitle = ""
    var episodes = [PodcastEpisode]()
    var isPodcast = false

    init(baseURL: URL?) { self.baseURL = baseURL }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        let attributes = Dictionary(uniqueKeysWithValues: attributeDict.map {
            ($0.key.lowercased(), $0.value)
        })
        let qualifiedName = (qName ?? elementName).lowercased()
        let name = localName(qualifiedName)
        stack.append(NativePodcastElement(
            name: name,
            qualifiedName: qualifiedName,
            namespaceURI: namespaceURI?.lowercased(),
            attributes: attributes,
            text: ""
        ))

        if attributes.keys.contains(where: { $0 == "xmlns:itunes" || $0 == "xmlns:podcast" }) ||
            qualifiedName.hasPrefix("itunes:") || qualifiedName.hasPrefix("podcast:") ||
            podcastNamespaceURLs.contains(namespaceURI?.lowercased() ?? "") {
            isPodcast = true
        }

        if name == "item" || name == "entry" {
            inItem = true
            episode = PodcastEpisode()
            return
        }
        guard inItem else { return }

        if name == "enclosure", let raw = attributes["url"] {
            episode.mediaURL = httpInputURL(raw, relativeTo: baseURL)
            if attributes["type"]?.lowercased().hasPrefix("audio/") == true ||
                isLikelyPodcastMediaURL(raw) {
                isPodcast = true
            }
        } else if name == "transcript",
                  isPodcastTranscriptElement(qualifiedName: qualifiedName, namespaceURI: namespaceURI),
                  let raw = attributes["url"],
                  let transcriptURL = httpInputURL(raw, relativeTo: baseURL) {
            let type = nativeTranscriptType(attributes["type"], url: raw)
            if nativeTranscriptRank(type) > nativeTranscriptRank(episode.transcriptType) {
                episode.transcriptURL = transcriptURL
                episode.transcriptType = type
                episode.transcriptLanguage = cleanInputText(attributes["language"])
            }
            isPodcast = true
        } else if name == "link", let raw = attributes["href"] {
            if attributes["rel"]?.lowercased() == "enclosure" {
                episode.mediaURL = httpInputURL(raw, relativeTo: baseURL)
                if attributes["type"]?.lowercased().hasPrefix("audio/") == true ||
                    isLikelyPodcastMediaURL(raw) {
                    isPodcast = true
                }
            } else if episode.link == nil {
                episode.link = httpInputURL(raw, relativeTo: baseURL)
            }
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        for index in stack.indices { stack[index].text += string }
    }

    func parser(_ parser: XMLParser, foundCDATA data: Data) {
        let value = String(decoding: data, as: UTF8.self)
        for index in stack.indices { stack[index].text += value }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        guard let element = stack.popLast() else { return }
        let value = cleanInputText(element.text)

        if element.name == "item" || element.name == "entry" {
            if episode.link == nil { episode.link = httpInputURL(episode.guid, relativeTo: baseURL) }
            if episode.mediaURL != nil || episode.transcriptURL != nil { isPodcast = true }
            episodes.append(episode)
            inItem = false
            return
        }

        if inItem {
            switch element.name {
            case "title": episode.title = value
            case "description", "summary", "encoded":
                if (value?.count ?? 0) > (episode.description?.count ?? 0) {
                    episode.description = value.map(inputStripHTML).flatMap(cleanInputText)
                }
            case "guid", "id": episode.guid = value
            case "link" where episode.link == nil:
                episode.link = httpInputURL(value, relativeTo: baseURL)
            default: break
            }
        } else if element.name == "title", feedTitle.isEmpty {
            feedTitle = value ?? ""
        }
    }

    private func localName(_ value: String) -> String {
        value.split(separator: ":").last.map(String.init)?.lowercased() ?? value.lowercased()
    }

    private func isPodcastTranscriptElement(
        qualifiedName: String,
        namespaceURI: String?
    ) -> Bool {
        guard localName(qualifiedName) == "transcript" else { return false }
        let prefix = qualifiedName.split(separator: ":").first.map(String.init)
        return prefix == "podcast" || podcastNamespaceURLs.contains(namespaceURI?.lowercased() ?? "")
    }
}

private func isLikelyPodcastMediaURL(_ raw: String) -> Bool {
    let path = URL(string: raw)?.path.lowercased() ?? raw.lowercased()
    return [".mp3", ".m4a", ".mp4", ".m4b", ".oga", ".ogg", ".wav", ".aac", ".opus", ".m3u8"]
        .contains(where: path.hasSuffix)
}

func nativeTranscriptType(_ declared: String?, url: String) -> String {
    if let value = declared?.split(separator: ";").first.map(String.init)
        .map({ $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }), !value.isEmpty {
        return value
    }
    switch URL(string: url)?.pathExtension.lowercased() {
    case "vtt": return "text/vtt"
    case "srt": return "application/x-subrip"
    case "json": return "application/json"
    case "html", "htm": return "text/html"
    default: return "text/plain"
    }
}

func nativeTranscriptRank(_ value: String?) -> Int {
    switch value?.lowercased() {
    case "text/vtt", "text/x-vtt": 5
    case "text/html": 4
    case "application/json": 3
    case "application/x-subrip", "application/srt": 2
    case "text/plain": 1
    default: 0
    }
}
private func cleanPodcastTitle(_ value: String?) -> String? {
    guard let value = cleanInputText(value) else { return nil }
    return value
        .replacingOccurrences(
            of: #"\s*[|–—-]\s*(?:Apple )?Podcasts?$"#,
            with: "",
            options: .regularExpression
        )
        .nativeNilIfEmpty
        .map { $0.lowercased() }
}

private func samePodcastURL(_ left: URL?, _ right: URL) -> Bool {
    guard let left,
          var leftComponents = URLComponents(url: left, resolvingAgainstBaseURL: false),
          var rightComponents = URLComponents(url: right, resolvingAgainstBaseURL: false) else {
        return false
    }
    leftComponents.fragment = nil
    rightComponents.fragment = nil
    leftComponents.queryItems?.sort { $0.name == $1.name ? ($0.value ?? "") < ($1.value ?? "") : $0.name < $1.name }
    rightComponents.queryItems?.sort { $0.name == $1.name ? ($0.value ?? "") < ($1.value ?? "") : $0.name < $1.name }
    return leftComponents.url?.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) ==
        rightComponents.url?.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
}
