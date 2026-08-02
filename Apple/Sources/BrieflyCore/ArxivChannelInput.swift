import Foundation

func enumerateArxivChannel(
    source: String,
    maximumItems: Int,
    context: ChannelInputContext
) async throws -> ChannelInputBatch {
    guard let url = httpInputURL(source), url.host?.lowercased() == "arxiv.org" else {
        throw NativeInputError.unsupportedInput
    }
    let parts = url.path.split(separator: "/").map(String.init)
    guard parts.first == "list", parts.count > 1 else {
        throw NativeInputError.unsupportedInput
    }
    var components = URLComponents(string: "https://export.arxiv.org/api/query")!
    components.queryItems = [
        URLQueryItem(name: "search_query", value: "cat:\(parts[1])"),
        URLQueryItem(name: "start", value: "0"),
        URLQueryItem(name: "max_results", value: String(maximumItems)),
        URLQueryItem(name: "sortBy", value: "submittedDate"),
        URLQueryItem(name: "sortOrder", value: "descending")
    ]
    return try await loadChannelFeed(
        components.url!,
        fallbackTitle: inputChannelTitle(source),
        channelInput: .arxiv,
        maximumItems: maximumItems,
        context: context
    )
}
