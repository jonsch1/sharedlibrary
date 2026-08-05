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
    case biorxiv
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
        case .missingBrowserSession:
            "Open the channel browser and sign in before checking this channel."
        }
    }
}
