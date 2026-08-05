import Foundation

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
            if [.x, .threads, .tiktok].contains(selected), case .url = request.source {
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
