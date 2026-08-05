import Foundation

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
    if canonicalItemIdentity(episode.link) == canonicalItemIdentity(url) { score += 100 }
    let pageTitle = cleanInputText(title)?.lowercased()
    let episodeTitle = cleanInputText(episode.title)?.lowercased()
    if let pageTitle, let episodeTitle,
       pageTitle.contains(episodeTitle) || episodeTitle.contains(pageTitle) { score += 20 }
    return score
}

func podcastFeedURLs(
    html: String,
    pageURL: URL,
    http: InputHTTPClient
) async throws -> [URL] {
    var urls = inputRegexCaptures(html, #"(?is)<link\b[^>]*>"#).compactMap { tag -> URL? in
        let type = inputHTMLAttribute("type", in: tag).lowercased()
        let rel = inputHTMLAttribute("rel", in: tag).lowercased()
        guard rel.split(whereSeparator: \.isWhitespace).contains("alternate"),
              type.contains("rss") || type.contains("atom") else { return nil }
        return httpInputURL(inputDecodeHTML(inputHTMLAttribute("href", in: tag)), relativeTo: pageURL)
    }
    urls.append(contentsOf: inputRegexCaptures(
        html,
        #"(?is)<a\b[^>]*href=[\"']([^\"']+)[\"'][^>]*>[^<]*\brss\b[^<]*</a>"#
    ).compactMap { httpInputURL(inputDecodeHTML($0), relativeTo: pageURL) })
    if pageURL.host?.lowercased() == "podcasts.apple.com",
       let id = inputRegexCapture(pageURL.path, #"/id(\d+)(?:/|$)"#) {
        var components = URLComponents(string: "https://itunes.apple.com/lookup")!
        components.queryItems = [URLQueryItem(name: "id", value: id), URLQueryItem(name: "entity", value: "podcast")]
        if let endpoint = components.url,
           let response = try? await http.get(endpoint, headers: ["Accept": "application/json"]),
           let object = try? JSONSerialization.jsonObject(with: response.data) as? [String: Any],
           let results = object["results"] as? [[String: Any]],
           let feed = results.compactMap({ $0["feedUrl"] as? String }).compactMap({ httpInputURL($0) }).first {
            urls.insert(feed, at: 0)
        }
    }
    return Array(NSOrderedSet(array: urls).array.compactMap { $0 as? URL })
}


func parsePodcastTranscript(_ value: String, type: String?) -> String {
    let lower = type?.lowercased() ?? ""
    if lower.contains("json"), let data = value.data(using: .utf8),
       let object = try? JSONSerialization.jsonObject(with: data) {
        if let payload = object as? [String: Any], let segments = payload["segments"] as? [[String: Any]] {
            var previousSpeaker: String?
            return segments.compactMap { segment -> String? in
                guard let body = cleanInputText(segment["body"] as? String) else { return nil }
                let speaker = cleanInputText(segment["speaker"] as? String)
                defer { previousSpeaker = speaker }
                return speaker != nil && speaker != previousSpeaker ? "\(speaker!): \(body)" : body
            }.joined(separator: " ")
        }
        var lines = [String]()
        func collect(_ value: Any) {
            if let object = value as? [String: Any] {
                for key in ["text", "body", "transcript"] {
                    if let text = cleanInputText(object[key] as? String) { lines.append(text) }
                }
                object.values.forEach(collect)
            } else if let array = value as? [Any] { array.forEach(collect) }
        }
        collect(object)
        return Array(NSOrderedSet(array: lines).array.compactMap { $0 as? String }).joined(separator: "\n")
    }
    if lower.contains("html") { return inputReadableHTML(value) ?? "" }
    let lines = value.components(separatedBy: .newlines).filter {
        let text = $0.trimmingCharacters(in: .whitespacesAndNewlines)
        return !text.isEmpty && text != "WEBVTT" &&
            text.range(of: #"^\d+$"#, options: .regularExpression) == nil &&
            !text.contains(" --> ")
    }
    return cleanInputText(lines.joined(separator: "\n")) ?? ""
}

func parseNativePodcastFeed(_ data: Data, baseURL: URL?) -> PodcastFeed? {
    let delegate = PodcastFeedParser(baseURL: baseURL)
    let parser = XMLParser(data: data)
    parser.delegate = delegate
    guard parser.parse(), !delegate.episodes.isEmpty, delegate.isPodcast else { return nil }
    return PodcastFeed(title: delegate.feedTitle.nativeNilIfEmpty, episodes: delegate.episodes)
}

final class PodcastFeedParser: NSObject, XMLParserDelegate {
    private let baseURL: URL?
    private var inItem = false
    private var element = ""
    private var text = ""
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
        let attributes = attributeDict
        let name = localName(elementName)
        element = name
        text = ""
        if name == "item" || name == "entry" {
            inItem = true
            episode = PodcastEpisode()
        } else if inItem, name == "enclosure", let raw = attributes["url"] {
            episode.mediaURL = httpInputURL(raw, relativeTo: baseURL)
            isPodcast = attributes["type"]?.lowercased().hasPrefix("audio/") == true || isPodcast
        } else if inItem, name == "transcript", let raw = attributes["url"] {
            let type = nativeTranscriptType(attributes["type"], url: raw)
            if nativeTranscriptRank(type) > nativeTranscriptRank(episode.transcriptType) {
                episode.transcriptURL = httpInputURL(raw, relativeTo: baseURL)
                episode.transcriptType = type
                episode.transcriptLanguage = attributes["language"]
            }
            isPodcast = true
        } else if inItem, name == "link", let raw = attributes["href"] {
            if attributes["rel"] == "enclosure" {
                episode.mediaURL = httpInputURL(raw, relativeTo: baseURL)
                isPodcast = attributes["type"]?.lowercased().hasPrefix("audio/") == true || isPodcast
            } else {
                episode.link = httpInputURL(raw, relativeTo: baseURL)
            }
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
    func parser(_ parser: XMLParser, foundCDATA data: Data) { text += String(decoding: data, as: UTF8.self) }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let name = localName(elementName)
        let value = cleanInputText(text)
        if inItem {
            switch name {
            case "title": episode.title = value
            case "description", "summary", "encoded":
                if (value?.count ?? 0) > (episode.description?.count ?? 0) {
                    episode.description = value.map(inputStripHTML).flatMap(cleanInputText)
                }
            case "guid", "id": episode.guid = value
            case "link" where episode.link == nil: episode.link = httpInputURL(value, relativeTo: baseURL)
            default: break
            }
        } else if name == "title", feedTitle.isEmpty { feedTitle = value ?? "" }
        if name == "item" || name == "entry" {
            if episode.link == nil { episode.link = httpInputURL(episode.guid, relativeTo: baseURL) }
            if episode.mediaURL != nil || episode.transcriptURL != nil { isPodcast = true }
            episodes.append(episode)
            inItem = false
        }
        element = ""
        text = ""
    }

    private func localName(_ value: String) -> String {
        value.split(separator: ":").last?.lowercased() ?? value.lowercased()
    }
}

func nativeTranscriptType(_ declared: String?, url: String) -> String {
    if let value = declared?.split(separator: ";").first?.lowercased(), !value.isEmpty {
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
    case "text/vtt": 5
    case "text/html": 4
    case "application/json": 3
    case "application/x-subrip", "application/srt": 2
    case "text/plain": 1
    default: 0
    }
}

