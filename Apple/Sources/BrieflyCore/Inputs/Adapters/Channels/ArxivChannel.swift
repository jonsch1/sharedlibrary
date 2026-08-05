import Foundation

func enumerateArxivChannel(
    source: String,
    maximumItems: Int,
    context: ChannelInputContext
) async throws -> ChannelInputBatch {
    if source.lowercased().hasPrefix("arxiv:") {
        let query = String(source.dropFirst("arxiv:".count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { throw NativeInputError.unsupportedInput }
        var components = URLComponents(string: "https://export.arxiv.org/api/query")!
        components.queryItems = [
            URLQueryItem(name: "search_query", value: "all:\(query)"),
            URLQueryItem(name: "start", value: "0"),
            URLQueryItem(name: "max_results", value: "50"),
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
    guard let url = httpInputURL(source),
          ["arxiv.org", "www.arxiv.org"].contains(url.host?.lowercased() ?? "") else {
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
