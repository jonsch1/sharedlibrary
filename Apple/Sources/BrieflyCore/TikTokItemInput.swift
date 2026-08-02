import Foundation

func ingestTikTok(
    _ request: ItemInputRequest,
    http: InputHTTPClient
) async throws -> ItemDraft {
    let url = try requestURL(request)
    guard isTikTokURL(url) else { throw NativeInputError.unsupportedInput }
    let encoded = url.absoluteString.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
    let response = try await http.get(
        URL(string: "https://www.tiktok.com/oembed?url=\(encoded)")!,
        headers: ["Accept": "application/json"]
    )
    guard let value = try JSONSerialization.jsonObject(with: response.data) as? [String: Any] else {
        throw NativeInputError.unreadableContent
    }
    let caption = cleanInputText(value["title"] as? String)
    let author = cleanInputText(value["author_name"] as? String)
    guard caption != nil || author != nil else { throw NativeInputError.unreadableContent }
    return ItemDraft(
        inputID: .tiktok,
        title: author.map { "TikTok by \($0)" } ?? "TikTok post",
        content: [
            author.map { "Author: \($0)" }, caption,
            cleanInputText(value["thumbnail_url"] as? String).map { "Thumbnail: \($0)" }
        ].compactMap { $0 }.joined(separator: "\n\n"),
        sourceURL: url,
        canonicalURL: url,
        faviconURL: URL(string: "https://www.tiktok.com/favicon.ico")
    )
}
