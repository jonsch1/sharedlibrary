import Foundation

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
