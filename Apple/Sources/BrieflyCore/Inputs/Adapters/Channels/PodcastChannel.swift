import Foundation

func enumeratePodcastChannel(
    source: String,
    maximumItems: Int,
    context: ChannelInputContext
) async throws -> ChannelInputBatch {
    guard let pageURL = httpInputURL(source) else { throw NativeInputError.unsupportedInput }
    let response = try await context.http.get(pageURL, maximumBytes: 12_000_000)
    if inputLooksLikeFeed(response) {
        return try await loadChannelFeed(
            response.finalURL,
            fallbackTitle: inputChannelTitle(source),
            channelInput: .podcast,
            maximumItems: maximumItems,
            context: context
        )
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
    throw NativeInputError.unreadableContent
}
