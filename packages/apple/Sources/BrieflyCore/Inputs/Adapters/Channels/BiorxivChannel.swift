#if os(macOS)
import Foundation

private struct EuropePMCSearchResponse: Decodable {
    struct ResultList: Decodable {
        struct Result: Decodable {
            let doi: String?
            let title: String?
            let firstPublicationDate: String?
            let abstractText: String?
        }

        let result: [Result]
    }

    let resultList: ResultList
}

func enumerateBiorxivChannel(
    source: String,
    maximumItems: Int,
    context: ChannelInputContext
) async throws -> ChannelInputBatch {
    guard let sourceURL = httpInputURL(source),
          let host = sourceURL.host?.lowercased(),
          host == "biorxiv.org" || host.hasSuffix(".biorxiv.org"),
          sourceURL.path.hasPrefix("/search/"),
          let decodedPath = sourceURL.path.removingPercentEncoding else {
        throw NativeInputError.unsupportedInput
    }
    let rawQuery = String(decodedPath.dropFirst("/search/".count))
    let query = rawQuery.replacingOccurrences(
        of: #"\s+numresults:\d+\s+sort:\S+\s+direction:\S+\s*$"#,
        with: "",
        options: [.regularExpression, .caseInsensitive]
    ).trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else { throw NativeInputError.unsupportedInput }

    var components = URLComponents(
        string: "https://www.ebi.ac.uk/europepmc/webservices/rest/search"
    )!
    components.queryItems = [
        URLQueryItem(
            name: "query",
            value: "(\(query)) AND SRC:PPR AND (DOI:10.1101* OR DOI:10.64898*)"
        ),
        URLQueryItem(name: "format", value: "json"),
        URLQueryItem(name: "resultType", value: "core"),
        URLQueryItem(name: "pageSize", value: String(min(100, max(1, maximumItems)))),
        URLQueryItem(name: "sort_date", value: "y")
    ]
    guard let apiURL = components.url else { throw NativeInputError.unsupportedInput }
    let response = try await context.http.get(
        apiURL,
        headers: ["Accept": "application/json"],
        maximumBytes: 10_000_000
    )
    let decoded = try JSONDecoder().decode(EuropePMCSearchResponse.self, from: response.data)
    let items = decoded.resultList.result.compactMap { result -> ChannelItemReference? in
        guard let doi = result.doi?.trimmingCharacters(in: .whitespacesAndNewlines),
              doi.lowercased().hasPrefix("10.1101/") || doi.lowercased().hasPrefix("10.64898/"),
              let url = URL(string: "https://www.biorxiv.org/content/\(doi)") else {
            return nil
        }
        let title = cleanInputText(result.title) ?? "bioRxiv paper"
        return ChannelItemReference(
            id: doi.lowercased(),
            title: title,
            url: url,
            publishedAt: result.firstPublicationDate,
            hints: .init(
                preferredInput: .biorxiv,
                title: title,
                content: cleanInputText(result.abstractText)
            )
        )
    }
    guard !items.isEmpty else { throw NativeInputError.unreadableContent }
    return inputLimitedBatch(
        ChannelInputBatch(
            inputID: .biorxiv,
            title: "bioRxiv · \(query)",
            kind: .feed,
            items: items
        ),
        maximumItems: maximumItems
    )
}

#endif
