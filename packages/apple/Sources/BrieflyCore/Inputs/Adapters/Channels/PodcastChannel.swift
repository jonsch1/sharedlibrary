import Foundation

func enumeratePodcastChannel(
    source: String,
    maximumItems: Int,
    context: ChannelInputContext
) async throws -> ChannelInputBatch {
    guard let pageURL = httpInputURL(source) else { throw NativeInputError.unsupportedInput }
    let response = try await context.http.get(pageURL, maximumBytes: 20_000_000)
    if inputLooksLikeFeed(response) {
        if let batch = try? await loadChannelFeed(
            response.finalURL,
            fallbackTitle: inputChannelTitle(source),
            channelInput: .podcast,
            maximumItems: maximumItems,
            context: context
        ) { return batch }
    }
    for feedURL in try await podcastFeedURLs(
        html: response.text,
        pageURL: response.finalURL,
        http: context.http
    ) {
        if let batch = try? await loadChannelFeed(
            feedURL,
            fallbackTitle: inputChannelTitle(source),
            channelInput: .podcast,
            maximumItems: maximumItems,
            context: context
        ) { return batch }
    }
    if let render = context.render,
       let rendered = try? await render(response.finalURL, maximumItems), !rendered.items.isEmpty {
        return inputLimitedBatch(rendered, maximumItems: maximumItems)
    }
    throw NativeInputError.unreadableContent
}
