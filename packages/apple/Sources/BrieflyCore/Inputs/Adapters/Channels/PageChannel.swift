#if os(macOS)
import CryptoKit
import Foundation

@MainActor
func enumeratePageChannel(
    source: String,
    maximumItems: Int,
    context: ChannelInputContext
) async throws -> ChannelInputBatch {
    guard let url = httpInputURL(source) else { throw NativeInputError.unsupportedInput }
    let response: InputHTTPResponse
    do {
        response = try await context.http.get(url, headers: [
            "Accept": "application/atom+xml, application/rss+xml, application/xml, text/html;q=0.9"
        ], maximumBytes: 20_000_000)
    } catch {
        if let render = context.render,
           let rendered = try? await render(url, maximumItems), !rendered.items.isEmpty {
            return inputLimitedBatch(rendered, maximumItems: maximumItems)
        }
        throw error
    }
    if inputLooksLikeFeed(response) {
        if let feed = try? parseFeed(
            response.data,
            fallbackTitle: inputChannelTitle(source),
            baseURL: response.finalURL
        ) {
            let channelInput: ChannelInputID = feed.kind == .podcast ? .podcast : .feed
            return inputLimitedBatch(
                try inputBatch(feed, channelInput: channelInput),
                maximumItems: maximumItems
            )
        }
    }

    var feedURLs = [URL]()
    if let youtube = youtubeFeedURL(in: response.text, relativeTo: response.finalURL) {
        feedURLs.append(youtube)
    }
    feedURLs.append(contentsOf: try await podcastFeedURLs(
        html: response.text,
        pageURL: response.finalURL,
        http: context.http
    ))
    feedURLs.append(contentsOf: inputDiscoveredFeedURLs(in: response.text, relativeTo: response.finalURL))
    let candidates = NSOrderedSet(array: feedURLs).array.compactMap({ $0 as? URL }).prefix(5)
    for feedURL in candidates {
        guard let batch = try? await loadChannelFeed(
            feedURL,
            fallbackTitle: inputChannelTitle(source),
            channelInput: isYouTubeFeedURL(feedURL) ? .youtube : .feed,
            maximumItems: maximumItems,
            context: context
        ) else { continue }
        return batch
    }

    if let render = context.render,
       let rendered = try? await render(response.finalURL, maximumItems), !rendered.items.isEmpty {
        return inputLimitedBatch(rendered, maximumItems: maximumItems)
    }
    try assertInputTextDocument(response)
    let metadata = inputHTMLMetadata(response.text, baseURL: response.finalURL)
    guard let content = inputUsefulText(inputReadableHTML(response.text), minimumLength: 1) ??
            inputUsefulText(inputStructuredText(response.text), minimumLength: 1) ??
            metadata.description else {
        throw NativeInputError.unreadableContent
    }
    let title = metadata.title ?? inputChannelTitle(source)
    let digest = SHA256.hash(data: response.data).map { String(format: "%02x", $0) }.joined()
    return ChannelInputBatch(
        inputID: .page,
        title: title,
        kind: .page,
        items: [.init(
            id: digest,
            title: title,
            url: response.finalURL,
            hints: .init(preferredInput: .webPage, title: title, content: content)
        )]
    )
}

func isYouTubeFeedURL(_ url: URL) -> Bool {
    url.host?.lowercased() == "www.youtube.com" &&
        url.path.lowercased() == "/feeds/videos.xml"
}

#endif
