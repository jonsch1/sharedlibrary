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
            URLQueryItem(name: "search_query", value: arxivAPIQuery(query)),
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
    let searchQuery: String
    if parts.first == "list", parts.count > 1 {
        searchQuery = "cat:\(parts[1])"
    } else if parts.first == "search",
              let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "query" })?.value?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !query.isEmpty {
        searchQuery = arxivAPIQuery(query.replacingOccurrences(of: "+", with: " "))
    } else {
        throw NativeInputError.unsupportedInput
    }
    var components = URLComponents(string: "https://export.arxiv.org/api/query")!
    components.queryItems = [
        URLQueryItem(name: "search_query", value: searchQuery),
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

func arxivAPIQuery(_ value: String) -> String {
    guard let expression = try? NSRegularExpression(
        pattern: #"\"[^\"]+\"|\b(?:ANDNOT|AND|OR)\b|[()]|[^\s()]+"#,
        options: .caseInsensitive
    ) else {
        return "all:\(value)"
    }
    let range = NSRange(value.startIndex..., in: value)
    return expression.matches(in: value, range: range).compactMap { match in
        guard let tokenRange = Range(match.range, in: value) else { return nil }
        let token = String(value[tokenRange])
        let upper = token.uppercased()
        if ["AND", "OR", "ANDNOT", "(", ")"].contains(upper) { return upper }
        if token.contains(":") { return token }
        return "all:\(token)"
    }.joined(separator: " ")
}
