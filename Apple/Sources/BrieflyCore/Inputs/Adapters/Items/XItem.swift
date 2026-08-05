import Foundation

func ingestX(
    _ request: ItemInputRequest,
    http: InputHTTPClient
) async throws -> ItemDraft {
    let url = try requestURL(request)
    guard let status = xStatus(url) else { throw NativeInputError.unsupportedInput }
    let endpoint = URL(string:
        "https://api.fxtwitter.com/\(status.actor.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? status.actor)/status/\(status.id)"
    )!
    let response = try await http.get(endpoint, headers: [
        "Accept": "application/json", "User-Agent": "Briefly/1.0"
    ])
    guard
        let object = try JSONSerialization.jsonObject(with: response.data) as? [String: Any],
        let tweet = object["tweet"] as? [String: Any]
    else { throw NativeInputError.unreadableContent }
    if let article = tweet["article"] as? [String: Any] {
        let title = cleanInputText(article["title"] as? String) ?? "X article"
        let content = renderXArticle(article)
        guard !content.isEmpty else { throw NativeInputError.unreadableContent }
        return ItemDraft(
            inputID: .x,
            title: title,
            content: content,
            sourceURL: url,
            canonicalURL: URL(string: "https://x.com/\(status.actor)/status/\(status.id)"),
            faviconURL: URL(string: "https://x.com/favicon.ico")
        )
    }
    let rawText = tweet["raw_text"] as? String ??
        (tweet["raw_text"] as? [String: Any])?["text"] as? String
    let text = cleanInputText(rawText) ??
        cleanInputText(tweet["text"] as? String) ?? "[Media post]"
    let author = tweet["author"] as? [String: Any]
    let name = cleanInputText(author?["name"] as? String)
    let screenName = cleanInputText(author?["screen_name"] as? String)
    let authorLine = name.flatMap { name in screenName.map { "\(name) (@\($0))" } } ??
        name ?? screenName.map { "@\($0)" } ?? "X user"
    let stats = [
        inputCountLabel(tweet["replies"], "reply", "replies"),
        inputCountLabel(tweet["retweets"], "repost", "reposts"),
        inputCountLabel(tweet["likes"], "like", "likes"),
        inputCountLabel(tweet["bookmarks"], "bookmark", "bookmarks"),
        inputCountLabel(tweet["views"], "view", "views")
    ].compactMap { $0 }
    let quote = tweet["quote"] as? [String: Any]
    let quotedRaw = quote?["raw_text"] as? String ??
        (quote?["raw_text"] as? [String: Any])?["text"] as? String ??
        quote?["text"] as? String
    let quotedText = cleanInputText(quotedRaw)
    let quotedAuthor = cleanInputText(
        (quote?["author"] as? [String: Any])?["screen_name"] as? String
    )
    let card = tweet["twitter_card"] as? [String: Any]
    let bindings = card?["binding_values"] as? [String: Any]
    let cardValue = bindings?["card_url"] as? [String: Any]
    let cardURL = cleanInputText(
        card?["url"] as? String ?? card?["card_url"] as? String ??
            cardValue?["string_value"] as? String
    )
    return ItemDraft(
        inputID: .x,
        title: "Post by \(authorLine): \(String(text.prefix(90)))",
        content: [
            authorLine, cleanInputText(tweet["created_at"] as? String), "", text,
            cleanInputText(tweet["replying_to"] as? String).map { "Replying to @\($0)" },
            quotedText.map {
                "\n> \(quotedAuthor.map { "@\($0): " } ?? "")" +
                    $0.replacingOccurrences(of: "\n", with: "\n> ")
            },
            cardURL.map { "\nLink: \($0)" },
            stats.isEmpty ? nil : stats.joined(separator: " · ")
        ]
            .compactMap { $0 }.joined(separator: "\n"),
        sourceURL: url,
        canonicalURL: URL(string: "https://x.com/\(status.actor)/status/\(status.id)"),
        faviconURL: URL(string: "https://x.com/favicon.ico")
    )
}

func renderXArticle(_ article: [String: Any]) -> String {
    var lines = [String]()
    func collect(_ value: Any) {
        if let object = value as? [String: Any] {
            if let text = cleanInputText(object["text"] as? String), !lines.contains(text) {
                lines.append(text)
            }
            for key in ["content", "blocks", "children", "entities"] {
                if let nested = object[key] { collect(nested) }
            }
        } else if let array = value as? [Any] {
            array.forEach(collect)
        }
    }
    collect(article)
    return lines.joined(separator: "\n\n")
}
