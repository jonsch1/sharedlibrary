import Foundation

func ingestBluesky(
    _ request: ItemInputRequest,
    http: InputHTTPClient
) async throws -> ItemDraft {
    let url = try requestURL(request)
    guard let post = blueskyPost(url) else { throw NativeInputError.unsupportedInput }
    var did = post.actor
    if !did.hasPrefix("did:") {
        var components = URLComponents(string:
            "https://public.api.bsky.app/xrpc/com.atproto.identity.resolveHandle"
        )!
        components.queryItems = [URLQueryItem(name: "handle", value: post.actor)]
        let response = try await http.get(components.url!, headers: ["Accept": "application/json"])
        guard
            let object = try JSONSerialization.jsonObject(with: response.data) as? [String: Any],
            let resolved = cleanInputText(object["did"] as? String)
        else { throw NativeInputError.unreadableContent }
        did = resolved
    }
    var components = URLComponents(string:
        "https://public.api.bsky.app/xrpc/app.bsky.feed.getPostThread"
    )!
    components.queryItems = [
        URLQueryItem(name: "uri", value: "at://\(did)/app.bsky.feed.post/\(post.rkey)"),
        URLQueryItem(name: "depth", value: "0")
    ]
    let response = try await http.get(components.url!, headers: ["Accept": "application/json"])
    guard
        let object = try JSONSerialization.jsonObject(with: response.data) as? [String: Any],
        let thread = object["thread"] as? [String: Any],
        let value = thread["post"] as? [String: Any],
        let record = value["record"] as? [String: Any],
        let text = cleanInputText(record["text"] as? String)
    else { throw NativeInputError.unreadableContent }
    let author = value["author"] as? [String: Any]
    let handle = cleanInputText(author?["handle"] as? String) ?? post.actor
    let display = cleanInputText(author?["displayName"] as? String)
    let authorLine = display.map { "\($0) (@\(handle))" } ?? "@\(handle)"
    let stats = [
        inputCountLabel(value["replyCount"], "reply", "replies"),
        inputCountLabel(value["repostCount"], "repost", "reposts"),
        inputCountLabel(value["quoteCount"], "quote", "quotes"),
        inputCountLabel(value["likeCount"], "like", "likes"),
        inputCountLabel(value["bookmarkCount"], "bookmark", "bookmarks")
    ].compactMap { $0 }
    return ItemDraft(
        inputID: .bluesky,
        title: "Bluesky post by \(authorLine): \(String(text.prefix(90)))",
        content: [
            authorLine, cleanInputText(record["createdAt"] as? String), "", text,
            stats.isEmpty ? nil : stats.joined(separator: " | "),
            cleanInputText(value["uri"] as? String).map { "Bluesky URI: \($0)" },
            cleanInputText(value["cid"] as? String).map { "CID: \($0)" }
        ].compactMap { $0 }.joined(separator: "\n"),
        sourceURL: url,
        canonicalURL: url,
        faviconURL: URL(string: "https://bsky.app/static/favicon-32x32.png")
    )
}
