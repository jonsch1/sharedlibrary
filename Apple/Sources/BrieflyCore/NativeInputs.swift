import Foundation

public enum ItemInputID: String, CaseIterable, Codable, Sendable {
    case text
    case pdf
    case arxiv
    case biorxiv
    case youtube
    case podcast
    case reddit
    case x
    case bluesky
    case threads
    case tiktok
    case webPage = "web-page"
}

public enum ChannelInputID: String, CaseIterable, Codable, Sendable {
    case feed
    case youtube
    case podcast
    case reddit
    case x
    case arxiv
    case hackerNews = "hacker-news"
    case page
}

public struct ItemInputHints: Sendable {
    public var preferredInput: ItemInputID?
    public var title: String?
    public var content: String?
    public var mediaURL: URL?
    public var transcriptURL: URL?
    public var transcriptType: String?
    public var transcriptLanguage: String?

    public init(
        preferredInput: ItemInputID? = nil,
        title: String? = nil,
        content: String? = nil,
        mediaURL: URL? = nil,
        transcriptURL: URL? = nil,
        transcriptType: String? = nil,
        transcriptLanguage: String? = nil
    ) {
        self.preferredInput = preferredInput
        self.title = title
        self.content = content
        self.mediaURL = mediaURL
        self.transcriptURL = transcriptURL
        self.transcriptType = transcriptType
        self.transcriptLanguage = transcriptLanguage
    }
}

public enum ItemInputSource: Sendable {
    case text(String)
    case file(URL)
    case url(URL)
}

public struct ItemInputRequest: Sendable {
    public var source: ItemInputSource
    public var hints: ItemInputHints
    public var retainAudio: Bool

    public init(
        source: ItemInputSource,
        hints: ItemInputHints = .init(),
        retainAudio: Bool = false
    ) {
        self.source = source
        self.hints = hints
        self.retainAudio = retainAudio
    }
}

public struct ItemDraft: Sendable {
    public var inputID: ItemInputID
    public var title: String
    public var content: String
    public var sourceURL: URL?
    public var canonicalURL: URL?
    public var mediaURL: URL?
    public var faviconURL: URL?
    public var faviconData: Data?
    public var faviconFileExtension: String?
    public var audioData: Data?
    public var audioMimeType: String?
    public var audioSourceURL: URL?
    public var transcriptAvailable: Bool
    public var transcriptLanguage: String?
    public var transcriptError: String?

    public init(
        inputID: ItemInputID,
        title: String,
        content: String,
        sourceURL: URL? = nil,
        canonicalURL: URL? = nil,
        mediaURL: URL? = nil,
        faviconURL: URL? = nil,
        faviconData: Data? = nil,
        faviconFileExtension: String? = nil,
        audioData: Data? = nil,
        audioMimeType: String? = nil,
        audioSourceURL: URL? = nil,
        transcriptAvailable: Bool = false,
        transcriptLanguage: String? = nil,
        transcriptError: String? = nil
    ) {
        self.inputID = inputID
        self.title = title
        self.content = content
        self.sourceURL = sourceURL
        self.canonicalURL = canonicalURL
        self.mediaURL = mediaURL
        self.faviconURL = faviconURL
        self.faviconData = faviconData
        self.faviconFileExtension = faviconFileExtension
        self.audioData = audioData
        self.audioMimeType = audioMimeType
        self.audioSourceURL = audioSourceURL
        self.transcriptAvailable = transcriptAvailable
        self.transcriptLanguage = transcriptLanguage
        self.transcriptError = transcriptError
    }

    public var canonicalKey: String? {
        canonicalItemIdentity(canonicalURL ?? sourceURL)
    }
}

public struct InputHTTPResponse: Sendable {
    public let data: Data
    public let finalURL: URL
    public let contentType: String
    public let statusCode: Int

    public init(
        data: Data,
        finalURL: URL,
        contentType: String = "text/html",
        statusCode: Int = 200
    ) {
        self.data = data
        self.finalURL = finalURL
        self.contentType = contentType
        self.statusCode = statusCode
    }

    public var text: String { String(decoding: data, as: UTF8.self) }
}

public struct InputHTTPClient: Sendable {
    public let send: @Sendable (URLRequest, Int) async throws -> InputHTTPResponse

    public init(
        send: @escaping @Sendable (URLRequest, Int) async throws -> InputHTTPResponse
    ) {
        self.send = send
    }

    public static let live = Self { request, maximumBytes in
        let (data, rawResponse) = try await URLSession.shared.data(for: request)
        guard let response = rawResponse as? HTTPURLResponse else {
            throw NativeInputError.invalidResponse
        }
        guard (200..<300).contains(response.statusCode) else {
            throw NativeInputError.requestFailed(response.statusCode)
        }
        guard data.count <= maximumBytes else { throw NativeInputError.responseTooLarge }
        return InputHTTPResponse(
            data: data,
            finalURL: response.url ?? request.url!,
            contentType: response.value(forHTTPHeaderField: "Content-Type")?
                .lowercased() ?? "",
            statusCode: response.statusCode
        )
    }

    public func get(
        _ url: URL,
        headers: [String: String] = [:],
        maximumBytes: Int = 20_000_000
    ) async throws -> InputHTTPResponse {
        var request = URLRequest(url: url, timeoutInterval: 120)
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) " +
                "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/123.0 Safari/537.36",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        return try await send(request, maximumBytes)
    }

    public func post(
        _ url: URL,
        body: Data,
        headers: [String: String] = [:],
        maximumBytes: Int = 20_000_000
    ) async throws -> InputHTTPResponse {
        var request = URLRequest(url: url, timeoutInterval: 120)
        request.httpMethod = "POST"
        request.httpBody = body
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        return try await send(request, maximumBytes)
    }
}

public struct RenderedInputPage: Sendable {
    public var title: String
    public var content: String
    public var sourceURL: URL
    public var faviconData: Data?
    public var faviconFileExtension: String?

    public init(
        title: String,
        content: String,
        sourceURL: URL,
        faviconData: Data? = nil,
        faviconFileExtension: String? = nil
    ) {
        self.title = title
        self.content = content
        self.sourceURL = sourceURL
        self.faviconData = faviconData
        self.faviconFileExtension = faviconFileExtension
    }
}

public struct InputTranscript: Sendable {
    public let text: String
    public let language: String?

    public init(text: String, language: String? = nil) {
        self.text = text
        self.language = language
    }
}

public struct ItemInputContext: Sendable {
    public var http: InputHTTPClient
    public var render: (@MainActor @Sendable (URL) async throws -> RenderedInputPage)?
    public var firecrawl: (@MainActor @Sendable (URL) async throws -> ItemDraft)?
    public var transcribe: (@MainActor @Sendable (URL) async throws -> InputTranscript)?
    public var downloadAudio: (@MainActor @Sendable (URL) async throws -> (Data, String))?

    public init(
        http: InputHTTPClient = .live,
        render: (@MainActor @Sendable (URL) async throws -> RenderedInputPage)? = nil,
        firecrawl: (@MainActor @Sendable (URL) async throws -> ItemDraft)? = nil,
        transcribe: (@MainActor @Sendable (URL) async throws -> InputTranscript)? = nil,
        downloadAudio: (@MainActor @Sendable (URL) async throws -> (Data, String))? = nil
    ) {
        self.http = http
        self.render = render
        self.firecrawl = firecrawl
        self.transcribe = transcribe
        self.downloadAudio = downloadAudio
    }
}

public struct ChannelItemReference: Sendable {
    public var id: String
    public var title: String
    public var url: URL
    public var publishedAt: String?
    public var hints: ItemInputHints

    public init(
        id: String,
        title: String,
        url: URL,
        publishedAt: String? = nil,
        hints: ItemInputHints = .init()
    ) {
        self.id = id
        self.title = title
        self.url = url
        self.publishedAt = publishedAt
        self.hints = hints
    }
}

public struct ChannelInputBatch: Sendable {
    public var inputID: ChannelInputID
    public var title: String
    public var kind: LibraryChannelKind
    public var items: [ChannelItemReference]

    public init(
        inputID: ChannelInputID,
        title: String,
        kind: LibraryChannelKind,
        items: [ChannelItemReference]
    ) {
        self.inputID = inputID
        self.title = title
        self.kind = kind
        self.items = items
    }
}

public struct ChannelInputContext: Sendable {
    public var http: InputHTTPClient
    public var render: (@MainActor @Sendable (URL, Int) async throws -> ChannelInputBatch)?

    public init(
        http: InputHTTPClient = .live,
        render: (@MainActor @Sendable (URL, Int) async throws -> ChannelInputBatch)? = nil
    ) {
        self.http = http
        self.render = render
    }
}

public enum NativeInputError: LocalizedError, Equatable {
    case emptyInput
    case unsupportedInput
    case invalidResponse
    case requestFailed(Int)
    case responseTooLarge
    case unreadableContent
    case missingBrowserSession

    public var errorDescription: String? {
        switch self {
        case .emptyInput: "The input is empty."
        case .unsupportedInput: "Briefly does not support this input."
        case .invalidResponse: "The input returned an invalid response."
        case .requestFailed(let status): "The input returned HTTP \(status)."
        case .responseTooLarge: "The input is too large to capture."
        case .unreadableContent: "The input did not contain readable content."
        case .missingBrowserSession: "Open the channel browser and sign in before checking this channel."
        }
    }
}

public struct NativeItemInputRouter: Sendable {
    public init() {}

    public func inputID(for request: ItemInputRequest) -> ItemInputID {
        if let preferred = request.hints.preferredInput { return preferred }
        switch request.source {
        case .text: return .text
        case .file: return .pdf
        case .url(let url):
            if isArxivURL(url) { return .arxiv }
            if isBiorxivURL(url) { return .biorxiv }
            if youtubeVideoID(url) != nil { return .youtube }
            if blueskyPost(url) != nil { return .bluesky }
            if threadsPost(url) != nil { return .threads }
            if isTikTokURL(url) { return .tiktok }
            if xStatus(url) != nil { return .x }
            if redditPostID(url) != nil { return .reddit }
            return .webPage
        }
    }

    @MainActor
    public func ingest(
        _ request: ItemInputRequest,
        context: ItemInputContext = .init()
    ) async throws -> ItemDraft {
        let selected = inputID(for: request)
        let draft: ItemDraft
        do {
            switch selected {
            case .text:
                draft = try ingestText(request)
            case .pdf:
                draft = try ingestPDF(request)
            case .arxiv:
                draft = try await ingestArxiv(request, http: context.http)
            case .biorxiv:
                draft = try await ingestBiorxiv(request, http: context.http)
            case .youtube:
                draft = try await ingestYouTube(request, context: context)
            case .podcast:
                draft = try await ingestPodcast(request, context: context)
            case .reddit:
                draft = try await ingestReddit(request, context: context)
            case .x:
                draft = try await ingestX(request, http: context.http)
            case .bluesky:
                draft = try await ingestBluesky(request, http: context.http)
            case .threads:
                draft = try await ingestThreads(request, http: context.http)
            case .tiktok:
                draft = try await ingestTikTok(request, http: context.http)
            case .webPage:
                draft = try await ingestWebPage(request, context: context)
            }
        } catch {
            if [.x, .threads, .tiktok].contains(selected),
               case .url = request.source {
                draft = try await ingestWebPage(request, context: context)
            } else if case .url(let url) = request.source {
                if let firecrawl = context.firecrawl, let fallback = try? await firecrawl(url) {
                    draft = fallback
                } else if let hint = request.hints.content?.nativeNilIfEmpty {
                    draft = ItemDraft(
                        inputID: .webPage,
                        title: request.hints.title?.nativeNilIfEmpty ?? url.host ?? "Web page",
                        content: hint,
                        sourceURL: url,
                        canonicalURL: url
                    )
                } else {
                    throw error
                }
            } else {
                throw error
            }
        }
        return try await attachFaviconAndAudio(to: draft, request: request, context: context)
    }
}

public struct NativeChannelInputRouter: Sendable {
    public init() {}

    public func inputID(for source: String) -> ChannelInputID {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed) else { return .page }
        let host = url.host?.lowercased() ?? ""
        if host == "news.ycombinator.com" { return .hackerNews }
        if host == "arxiv.org", url.path.hasPrefix("/list/") { return .arxiv }
        if host == "youtube.com" || host.hasSuffix(".youtube.com") { return .youtube }
        if host == "podcasts.apple.com" { return .podcast }
        if host == "reddit.com" || host.hasSuffix(".reddit.com") { return .reddit }
        if host == "x.com" || host.hasSuffix(".twitter.com") || host == "twitter.com" { return .x }
        return .page
    }

    @MainActor
    public func enumerate(
        source: String,
        maximumItems: Int = 5,
        context: ChannelInputContext = .init()
    ) async throws -> ChannelInputBatch {
        let source = source.trimmingCharacters(in: .whitespacesAndNewlines)
        let limit = min(100, max(1, maximumItems))
        switch inputID(for: source) {
        case .feed:
            return try await enumerateFeedChannel(source: source, maximumItems: limit, context: context)
        case .youtube:
            return try await enumerateYouTubeChannel(source: source, maximumItems: limit, context: context)
        case .podcast:
            return try await enumeratePodcastChannel(source: source, maximumItems: limit, context: context)
        case .reddit:
            return try await enumerateRedditChannel(source: source, maximumItems: limit, context: context)
        case .x:
            return try await enumerateXChannel(source: source, maximumItems: limit, context: context)
        case .arxiv:
            return try await enumerateArxivChannel(source: source, maximumItems: limit, context: context)
        case .hackerNews:
            return try await enumerateHackerNewsChannel(source: source, maximumItems: limit, context: context)
        case .page:
            return try await enumeratePageChannel(source: source, maximumItems: limit, context: context)
        }
    }
}

func attachFaviconAndAudio(
    to value: ItemDraft,
    request: ItemInputRequest,
    context: ItemInputContext
) async throws -> ItemDraft {
    var draft = value
    if draft.faviconData == nil, let url = draft.faviconURL,
       let response = try? await context.http.get(url, maximumBytes: 1_000_000),
       !response.data.isEmpty {
        draft.faviconData = response.data
        draft.faviconFileExtension = inputFileExtension(
            contentType: response.contentType,
            url: response.finalURL,
            data: response.data
        )
    }
    if request.retainAudio, let source = draft.audioSourceURL ?? draft.mediaURL ?? draft.sourceURL,
       let downloadAudio = context.downloadAudio {
        let (data, mimeType) = try await downloadAudio(source)
        draft.audioData = data
        draft.audioMimeType = mimeType
    }
    return draft
}

public func canonicalItemIdentity(_ value: URL?) -> String? {
    guard let value, var components = URLComponents(url: value, resolvingAgainstBaseURL: false),
          let rawHost = components.host else { return nil }
    let host = rawHost.lowercased().replacingOccurrences(
        of: #"^www\."#,
        with: "",
        options: .regularExpression
    )
    let parts = components.path.split(separator: "/").map(String.init)
    if host == "x.com" || host.hasSuffix(".x.com") || host == "twitter.com" ||
        host.hasSuffix(".twitter.com"),
       let status = parts.firstIndex(where: { $0.lowercased() == "status" }),
       parts.indices.contains(status + 1), Int(parts[status + 1]) != nil {
        return "x:status:\(parts[status + 1])"
    }
    if host == "redd.it", let id = parts.first?.lowercased(), !id.isEmpty {
        return "reddit:post:\(id)"
    }
    if host == "reddit.com" || host.hasSuffix(".reddit.com"),
       let comments = parts.firstIndex(where: { $0.lowercased() == "comments" }),
       parts.indices.contains(comments + 1) {
        return "reddit:post:\(parts[comments + 1].lowercased())"
    }
    if host == "bsky.app", parts.count == 4, parts[0] == "profile", parts[2] == "post" {
        return "bluesky:post:\(parts[1]):\(parts[3])"
    }
    if host == "youtu.be", let id = parts.first { return "youtube:video:\(id)" }
    if host == "youtube.com" || host.hasSuffix(".youtube.com") ||
        host == "youtube-nocookie.com" || host.hasSuffix(".youtube-nocookie.com"),
       let id = components.queryItems?.first(where: { $0.name == "v" })?.value ??
        (["shorts", "live", "embed"].contains(parts.first ?? "") ? parts.dropFirst().first : nil) {
        return "youtube:video:\(id)"
    }
    components.host = host
    components.fragment = nil
    if components.path.count > 1 {
        components.path = components.path.replacingOccurrences(
            of: #"/+$"#,
            with: "",
            options: .regularExpression
        )
    }
    let queryItems = components.queryItems?.filter {
        !$0.name.lowercased().hasPrefix("utm_") &&
            !["fbclid", "gclid", "mc_cid", "mc_eid"].contains($0.name.lowercased())
    }.sorted { $0.name == $1.name ? ($0.value ?? "") < ($1.value ?? "") : $0.name < $1.name }
    components.queryItems = queryItems?.isEmpty == true ? nil : queryItems
    return components.url?.absoluteString
}

struct InputHTMLMetadata {
    var title: String?
    var description: String?
    var canonicalURL: URL?
    var faviconURL: URL?
}

func inputBatch(
    _ channel: DiscoveredChannel,
    channelInput: ChannelInputID
) throws -> ChannelInputBatch {
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
            title: item.title,
            url: url,
            publishedAt: item.publishedAt,
            hints: .init(
                preferredInput: itemInput ?? (channel.kind == .podcast ? .podcast : nil),
                title: item.title,
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

func inputLimitedBatch(
    _ batch: ChannelInputBatch,
    maximumItems: Int
) -> ChannelInputBatch {
    var batch = batch
    batch.items = batch.items.enumerated().map {
        (item: $0.element, index: $0.offset, date: inputChannelDate($0.element.publishedAt))
    }.sorted {
        if let left = $0.date, let right = $1.date { return left > right }
        return $0.index < $1.index
    }.prefix(maximumItems).map(\.item)
    return batch
}

func inputChannelDate(_ value: String?) -> Date? {
    guard let value else { return nil }
    if let date = ISO8601DateFormatter().date(from: value) { return date }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    for format in ["EEE, dd MMM yyyy HH:mm:ss Z", "EEE, dd MMM yyyy HH:mm Z"] {
        formatter.dateFormat = format
        if let date = formatter.date(from: value) { return date }
    }
    return nil
}

func inputLooksLikeFeed(_ response: InputHTTPResponse) -> Bool {
    if response.contentType.contains("rss") || response.contentType.contains("atom") ||
        response.contentType.contains("xml") { return true }
    let prefix = String(decoding: response.data.prefix(1_000), as: UTF8.self).lowercased()
    return prefix.contains("<rss") || prefix.contains("<feed") || prefix.contains("<rdf:rdf")
}

func inputDiscoveredFeedURL(in html: String, relativeTo base: URL) -> URL? {
    inputRegexCaptures(html, #"(?is)<link\b[^>]*>"#).compactMap { tag -> URL? in
        let type = inputHTMLAttribute("type", in: tag).lowercased()
        guard type.contains("rss") || type.contains("atom") else { return nil }
        return httpInputURL(inputHTMLAttribute("href", in: tag), relativeTo: base)
    }.first
}

func inputHTMLAttribute(_ name: String, in tag: String) -> String {
    inputRegexCapture(
        tag,
        #"(?is)\b"# + NSRegularExpression.escapedPattern(for: name) + #"\s*=\s*[\"']([^\"']*)[\"']"#
    ) ?? ""
}

func inputChannelTitle(_ source: String) -> String {
    guard let url = URL(string: source) else { return source }
    let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        .replacingOccurrences(of: "/", with: " · ")
    return path.nativeNilIfEmpty ?? url.host?.replacingOccurrences(of: "www.", with: "") ?? source
}

func requestURL(_ request: ItemInputRequest) throws -> URL {
    guard case .url(let url) = request.source,
          ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else {
        throw NativeInputError.unsupportedInput
    }
    guard url.user == nil, url.password == nil else { throw NativeInputError.unsupportedInput }
    return url
}

func nativeFirstUsefulLine(_ text: String) -> String {
    let trimming = CharacterSet.whitespacesAndNewlines.union(
        CharacterSet(charactersIn: "\u{FEFF}")
    )
    return text.components(separatedBy: .newlines)
        .map { $0.trimmingCharacters(in: trimming) }
        .first(where: { !$0.isEmpty })
        .map { String($0.trimmingCharacters(in: CharacterSet(charactersIn: "# ")).prefix(80)) } ??
        "Clipboard capture"
}

func isArxivURL(_ url: URL) -> Bool {
    let host = url.host?.lowercased() ?? ""
    return host == "arxiv.org" || host.hasSuffix(".arxiv.org") || host == "markxiv.org"
}

func isBiorxivURL(_ url: URL) -> Bool {
    biorxivArticlePath(url) != nil
}

func biorxivArticlePath(_ url: URL) -> String? {
    let host = url.host?.lowercased() ?? ""
    guard host == "biorxiv.org" || host.hasSuffix(".biorxiv.org") else { return nil }
    var path = url.path
    while path.hasSuffix("/") { path.removeLast() }
    for suffix in [".full.pdf", ".abstract", ".full"] where path.hasSuffix(suffix) {
        path.removeLast(suffix.count)
        break
    }
    let parts = path.split(separator: "/", omittingEmptySubsequences: true)
    guard parts.count == 3, parts[0] == "content", parts[1].hasPrefix("10."),
          !parts[2].isEmpty else { return nil }
    return "/" + parts.joined(separator: "/")
}

func youtubeVideoID(_ url: URL) -> String? {
    let host = url.host?.lowercased().replacingOccurrences(of: "www.", with: "") ?? ""
    let parts = url.path.split(separator: "/").map(String.init)
    let value: String?
    if host == "youtu.be" {
        value = parts.first
    } else if host == "youtube.com" || host.hasSuffix(".youtube.com") ||
        host == "youtube-nocookie.com" || host.hasSuffix(".youtube-nocookie.com") {
        value = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .first(where: { $0.name == "v" })?.value ??
            (["shorts", "live", "embed"].contains(parts.first ?? "") ? parts.dropFirst().first : nil)
    } else {
        value = nil
    }
    guard let value, value.range(of: #"^[A-Za-z0-9_-]{6,32}$"#, options: .regularExpression) != nil else {
        return nil
    }
    return value
}

func redditPostID(_ url: URL) -> String? {
    let host = url.host?.lowercased() ?? ""
    let parts = url.path.split(separator: "/").map(String.init)
    if host == "redd.it" { return parts.first?.nativeNilIfEmpty }
    guard host == "reddit.com" || host.hasSuffix(".reddit.com"),
          let index = parts.firstIndex(where: { $0.lowercased() == "comments" }),
          parts.indices.contains(index + 1) else { return nil }
    return parts[index + 1].nativeNilIfEmpty
}

func xStatus(_ url: URL) -> (actor: String, id: String)? {
    let host = url.host?.lowercased() ?? ""
    let parts = url.path.split(separator: "/").map(String.init)
    guard host == "x.com" || host.hasSuffix(".x.com") || host == "twitter.com" ||
        host.hasSuffix(".twitter.com"),
          let index = parts.firstIndex(where: { $0.lowercased() == "status" }), index > 0,
          parts.indices.contains(index + 1), Int(parts[index + 1]) != nil else { return nil }
    return (parts[index - 1], parts[index + 1])
}

func blueskyPost(_ url: URL) -> (actor: String, rkey: String)? {
    let parts = url.path.split(separator: "/").map(String.init)
    guard url.host?.lowercased() == "bsky.app", parts.count == 4,
          parts[0] == "profile", parts[2] == "post" else { return nil }
    return (parts[1], parts[3])
}

func threadsPost(_ url: URL) -> (actor: String, id: String)? {
    let host = url.host?.lowercased() ?? ""
    let parts = url.path.split(separator: "/").map(String.init)
    guard host == "threads.net" || host.hasSuffix(".threads.net") ||
        host == "threads.com" || host.hasSuffix(".threads.com"),
          parts.count >= 3, parts[0].hasPrefix("@"), ["post", "t"].contains(parts[1]) else {
        return nil
    }
    return (String(parts[0].dropFirst()), parts[2])
}

func isTikTokURL(_ url: URL) -> Bool {
    let host = url.host?.lowercased() ?? ""
    return host == "tiktok.com" || host.hasSuffix(".tiktok.com") || host == "vm.tiktok.com"
}

func inputRegexCapture(_ value: String, _ pattern: String, group: Int = 1) -> String? {
    guard let regex = try? NSRegularExpression(pattern: pattern),
          let match = regex.firstMatch(
            in: value,
            range: NSRange(location: 0, length: value.utf16.count)
          ), match.numberOfRanges > group,
          let range = Range(match.range(at: group), in: value) else { return nil }
    return String(value[range])
}

func cleanInputText(_ value: String?) -> String? {
    guard let value else { return nil }
    let result = inputDecodeHTML(value)
        .replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
        .replacingOccurrences(of: #"\n\s*\n\s*\n+"#, with: "\n\n", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    return result.nativeNilIfEmpty
}

func httpInputURL(_ value: String?, relativeTo base: URL? = nil) -> URL? {
    guard let value = cleanInputText(value),
          let url = URL(string: value, relativeTo: base)?.absoluteURL,
          ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil,
          url.user == nil, url.password == nil else {
        return nil
    }
    return url
}

func inputCountLabel(_ raw: Any?, _ singular: String, _ plural: String) -> String? {
    let count = (raw as? NSNumber)?.intValue ?? (raw as? String).flatMap(Int.init)
    guard let count else { return nil }
    return "\(count) \(count == 1 ? singular : plural)"
}

func inputHTMLMetadata(_ html: String, baseURL: URL) -> InputHTMLMetadata {
    let metaTags = inputRegexCaptures(html, #"(?is)<meta\b[^>]*>"#)
    func meta(_ names: [String]) -> String? {
        metaTags.first { tag in
            let key = inputHTMLAttribute("property", in: tag).nativeNilIfEmpty ??
                inputHTMLAttribute("name", in: tag)
            return names.contains(key.lowercased())
        }.map { inputDecodeHTML(inputHTMLAttribute("content", in: $0)) }.flatMap(cleanInputText)
    }
    let title = meta(["og:title", "twitter:title"]) ??
        inputRegexCapture(html, #"(?is)<title[^>]*>(.*?)</title>"#)
        .map { inputDecodeHTML(inputStripHTML($0)) }
    let description = meta(["og:description", "description", "twitter:description"])
    let links = inputRegexCaptures(html, #"(?is)<link\b[^>]*>"#)
    let canonical = links.first {
        inputHTMLAttribute("rel", in: $0).lowercased().split(whereSeparator: \.isWhitespace)
            .contains("canonical")
    }.map { inputHTMLAttribute("href", in: $0) }
    let icon = links.first {
        let relations = inputHTMLAttribute("rel", in: $0).lowercased()
            .split(whereSeparator: \.isWhitespace)
        return relations.contains("icon") || relations.contains("shortcut")
    }.map { inputHTMLAttribute("href", in: $0) }
    return .init(
        title: cleanInputText(title),
        description: cleanInputText(description),
        canonicalURL: httpInputURL(canonical, relativeTo: baseURL),
        faviconURL: httpInputURL(icon, relativeTo: baseURL) ?? URL(string: "/favicon.ico", relativeTo: baseURL)?.absoluteURL
    )
}

func inputReadableHTML(_ html: String) -> String? {
    var value = inputRegexCapture(html, #"(?is)<article\b[^>]*>([\s\S]*?)</article>"#) ??
        inputRegexCapture(html, #"(?is)<main\b[^>]*>([\s\S]*?)</main>"#) ?? html
    for pattern in [
        #"(?is)<(script|style|svg|noscript|nav|footer|form)\b[^>]*>.*?</\1>"#,
        #"(?i)<br\s*/?>"#,
        #"(?i)</(?:p|div|article|section|h[1-6]|li)\s*>"#,
        #"(?is)<[^>]+>"#
    ] {
        value = value.replacingOccurrences(
            of: pattern,
            with: pattern.contains("br") || pattern.contains("?:p") ? "\n" : " ",
            options: .regularExpression
        )
    }
    return cleanInputText(value)
}

func inputStripHTML(_ value: String) -> String {
    value.replacingOccurrences(of: #"(?is)<[^>]+>"#, with: " ", options: .regularExpression)
}

func inputDecodeHTML(_ value: String) -> String {
    var text = value
    for (entity, replacement) in [
        ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""),
        ("&#39;", "'"), ("&apos;", "'"), ("&nbsp;", " ")
    ] {
        text = text.replacingOccurrences(of: entity, with: replacement, options: .caseInsensitive)
    }
    guard let regex = try? NSRegularExpression(pattern: #"&#(?:x([0-9A-Fa-f]+)|(\d+));"#) else {
        return text
    }
    for match in regex.matches(
        in: text,
        range: NSRange(location: 0, length: text.utf16.count)
    ).reversed() {
        guard let range = Range(match.range, in: text) else { continue }
        let hexadecimal = match.range(at: 1).location != NSNotFound
        let group = hexadecimal ? 1 : 2
        guard let valueRange = Range(match.range(at: group), in: text),
              let value = UInt32(text[valueRange], radix: hexadecimal ? 16 : 10),
              let scalar = UnicodeScalar(value) else { continue }
        text.replaceSubrange(range, with: String(Character(scalar)))
    }
    return text
}

func looksLikeInputInterstitial(_ value: String) -> Bool {
    let text = value.lowercased()
    return ["enable javascript", "checking your browser", "just a moment", "access denied"]
        .contains(where: text.contains)
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
        if bytes.starts(with: Array("RIFF".utf8)) && bytes.dropFirst(8).starts(with: Array("WEBP".utf8)) {
            return "webp"
        }
        return url.pathExtension.nativeNilIfEmpty ?? "bin"
    }
}

func inputRegexCaptures(_ value: String, _ pattern: String) -> [String] {
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
    return regex.matches(in: value, range: NSRange(location: 0, length: value.utf16.count)).compactMap {
        let group = $0.numberOfRanges > 1 ? 1 : 0
        guard let range = Range($0.range(at: group), in: value) else { return nil }
        return String(value[range])
    }
}

extension String {
    var nativeNilIfEmpty: String? { isEmpty ? nil : self }
}
