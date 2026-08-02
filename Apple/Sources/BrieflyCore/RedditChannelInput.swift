import Foundation

func enumerateRedditChannel(
    source: String,
    maximumItems: Int,
    context: ChannelInputContext
) async throws -> ChannelInputBatch {
    guard let url = httpInputURL(source) else { throw NativeInputError.unsupportedInput }
    guard url.path.range(of: #"/r/[^/]+/?$"#, options: .regularExpression) != nil else {
        return try await enumeratePageChannel(
            source: source,
            maximumItems: maximumItems,
            context: context
        )
    }
    var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
    components.path = "/" + url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/.rss"
    components.queryItems = [URLQueryItem(name: "limit", value: String(maximumItems))]
    return try await loadChannelFeed(
        components.url!,
        fallbackTitle: inputChannelTitle(source),
        channelInput: .reddit,
        maximumItems: maximumItems,
        context: context
    )
}
