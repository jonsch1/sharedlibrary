#if os(macOS)
import Foundation

func enumerateYouTubeChannel(
    source: String,
    maximumItems: Int,
    context: ChannelInputContext
) async throws -> ChannelInputBatch {
    guard let pageURL = httpInputURL(source) else { throw NativeInputError.unsupportedInput }
    if let feedURL = youtubeFeedURL(in: "", relativeTo: pageURL) {
        return try await loadChannelFeed(
            feedURL,
            fallbackTitle: inputChannelTitle(source),
            channelInput: .youtube,
            maximumItems: maximumItems,
            context: context
        )
    }
    let response = try await context.http.get(pageURL, maximumBytes: 20_000_000)
    if inputLooksLikeFeed(response) {
        if let batch = try? await loadChannelFeed(
            response.finalURL,
            fallbackTitle: inputChannelTitle(source),
            channelInput: .youtube,
            maximumItems: maximumItems,
            context: context
        ) { return batch }
    }
    if let feedURL = youtubeFeedURL(in: response.text, relativeTo: response.finalURL) {
        return try await loadChannelFeed(
            feedURL,
            fallbackTitle: inputChannelTitle(source),
            channelInput: .youtube,
            maximumItems: maximumItems,
            context: context
        )
    }
    if let render = context.render {
        return inputLimitedBatch(try await render(response.finalURL, maximumItems), maximumItems: maximumItems)
    }
    throw NativeInputError.unreadableContent
}

#endif
