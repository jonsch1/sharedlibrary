import Foundation

func enumerateHackerNewsChannel(
    source: String,
    maximumItems: Int,
    context: ChannelInputContext
) async throws -> ChannelInputBatch {
    guard let url = httpInputURL(source) else { throw NativeInputError.unsupportedInput }
    let response = try await context.http.get(url, maximumBytes: 20_000_000)
    guard let channel = parseHackerNews(
        response.text,
        sourceURL: response.finalURL,
        maximumItems: maximumItems
    ) else { throw NativeInputError.unreadableContent }
    return try inputBatch(channel, channelInput: .hackerNews)
}
