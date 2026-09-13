#if os(macOS)
import Foundation

func ingestTikTok(
    _ request: ItemInputRequest,
    http: InputHTTPClient
) async throws -> ItemDraft {
    let url = try requestURL(request)
    guard isTikTokURL(url) else { throw NativeInputError.unsupportedInput }
    var endpoint = URLComponents(string: "https://www.tiktok.com/oembed")!
    endpoint.queryItems = [URLQueryItem(name: "url", value: url.absoluteString)]
    let response = try await http.get(
        endpoint.url!,
        headers: ["Accept": "application/json"]
    )
    guard let value = try JSONSerialization.jsonObject(with: response.data) as? [String: Any] else {
        throw NativeInputError.unreadableContent
    }
    let caption = cleanTikTokText(value["title"] as? String)
    let author = cleanTikTokText(value["author_name"] as? String)
    guard caption != nil || author != nil else { throw NativeInputError.unreadableContent }
    return ItemDraft(
        inputID: .tiktok,
        title: author.map { "TikTok by \($0)" } ?? "TikTok post",
        content: [
            author.map { "Author: \($0)" }, caption,
            (value["thumbnail_url"] as? String).map { "Thumbnail: \($0)" }
        ].compactMap { $0 }.joined(separator: "\n\n"),
        sourceURL: url,
        canonicalURL: url,
        faviconURL: URL(string: "https://www.tiktok.com/favicon.ico")
    )
}

private func cleanTikTokText(_ value: String?) -> String? {
    guard let value else { return nil }
    return value
        .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .nativeNilIfEmpty
}

#endif
