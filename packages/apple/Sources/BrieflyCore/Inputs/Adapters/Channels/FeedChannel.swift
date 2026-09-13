#if os(macOS)
import Foundation

func enumerateFeedChannel(
    source: String,
    maximumItems: Int,
    context: ChannelInputContext
) async throws -> ChannelInputBatch {
    guard let url = httpInputURL(source) else { throw NativeInputError.unsupportedInput }
    return try await loadChannelFeed(
        url,
        fallbackTitle: inputChannelTitle(source),
        channelInput: .feed,
        maximumItems: maximumItems,
        context: context
    )
}

func loadChannelFeed(
    _ url: URL,
    fallbackTitle: String,
    channelInput: ChannelInputID,
    maximumItems: Int,
    context: ChannelInputContext
) async throws -> ChannelInputBatch {
    let response = try await context.http.get(url, headers: [
        "Accept": "application/atom+xml, application/rss+xml, application/xml"
    ], maximumBytes: 20_000_000)
    let feed = try parseFeed(response.data, fallbackTitle: fallbackTitle, baseURL: response.finalURL)
    let resolvedInput: ChannelInputID = feed.kind == .podcast ? .podcast : channelInput
    return inputLimitedBatch(
        try inputBatch(feed, channelInput: resolvedInput),
        maximumItems: maximumItems
    )
}

#endif
