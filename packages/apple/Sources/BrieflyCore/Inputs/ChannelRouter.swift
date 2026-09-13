#if os(macOS)
import Foundation

public struct NativeChannelInputRouter: Sendable {
    public init() {}

    public func inputID(for source: String) -> ChannelInputID {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().hasPrefix("arxiv:") { return .arxiv }
        guard let url = URL(string: trimmed) else { return .page }
        let host = url.host?.lowercased() ?? ""
        if host == "news.ycombinator.com" { return .hackerNews }
        if (host == "arxiv.org" || host == "www.arxiv.org"),
           url.path.hasPrefix("/list/") || url.path == "/search" || url.path.hasPrefix("/search/") {
            return .arxiv
        }
        if (host == "biorxiv.org" || host.hasSuffix(".biorxiv.org")),
           url.path.hasPrefix("/search/") {
            return .biorxiv
        }
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
        guard !source.isEmpty else { throw NativeInputError.emptyInput }
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
        case .biorxiv:
            return try await enumerateBiorxivChannel(source: source, maximumItems: limit, context: context)
        case .hackerNews:
            return try await enumerateHackerNewsChannel(source: source, maximumItems: limit, context: context)
        case .page:
            return try await enumeratePageChannel(source: source, maximumItems: limit, context: context)
        }
    }
}

#endif
