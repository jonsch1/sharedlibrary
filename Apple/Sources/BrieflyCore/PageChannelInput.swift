import CryptoKit
import Foundation

@MainActor
func enumeratePageChannel(
    source: String,
    maximumItems: Int,
    context: ChannelInputContext
) async throws -> ChannelInputBatch {
    guard let url = httpInputURL(source) else { throw NativeInputError.unsupportedInput }
    let response = try await context.http.get(url, headers: [
        "Accept": "application/atom+xml, application/rss+xml, application/xml, text/html;q=0.9"
    ], maximumBytes: 12_000_000)
    if inputLooksLikeFeed(response) {
        let feed = try parseFeed(
            response.data,
            fallbackTitle: inputChannelTitle(source),
            baseURL: response.finalURL
        )
        let channelInput: ChannelInputID = feed.kind == .podcast ? .podcast : .feed
        return inputLimitedBatch(
            try inputBatch(feed, channelInput: channelInput),
            maximumItems: maximumItems
        )
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
    if let discovered = inputDiscoveredFeedURL(in: response.text, relativeTo: response.finalURL) {
        feedURLs.append(discovered)
    }
    for feedURL in NSOrderedSet(array: feedURLs).array.compactMap({ $0 as? URL }) {
        guard let batch = try? await loadChannelFeed(
            feedURL,
            fallbackTitle: inputChannelTitle(source),
            channelInput: youtubeFeedURL(in: "", relativeTo: feedURL) == nil ? .feed : .youtube,
            maximumItems: maximumItems,
            context: context
        ) else { continue }
        return batch
    }

    if let render = context.render,
       let rendered = try? await render(response.finalURL, maximumItems), !rendered.items.isEmpty {
        return inputLimitedBatch(rendered, maximumItems: maximumItems)
    }
    guard let content = inputReadableHTML(response.text) else {
        throw NativeInputError.unreadableContent
    }
    let metadata = inputHTMLMetadata(response.text, baseURL: response.finalURL)
    let title = metadata.title ?? inputChannelTitle(source)
    let digest = SHA256.hash(data: response.data).map { String(format: "%02x", $0) }.joined()
    return ChannelInputBatch(
        inputID: .page,
        title: title,
        kind: .page,
        items: [.init(
            id: digest,
            title: title,
            url: metadata.canonicalURL ?? response.finalURL,
            hints: .init(preferredInput: .webPage, title: title, content: content)
        )]
    )
}
