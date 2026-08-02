import Foundation

func ingestReddit(
    _ request: ItemInputRequest,
    http: InputHTTPClient
) async throws -> ItemDraft {
    let url = try requestURL(request)
    guard let postID = redditPostID(url) else { throw NativeInputError.unsupportedInput }
    let jsonURL = URL(string:
        "https://www.reddit.com/comments/\(postID).json?raw_json=1&limit=20&depth=2&sort=top"
    )!
    do {
        let response = try await http.get(jsonURL, headers: [
            "Accept": "application/json", "User-Agent": "Briefly/1.0"
        ])
        guard
            let listings = try JSONSerialization.jsonObject(with: response.data) as? [[String: Any]],
            let post = redditListingChildren(listings.first).first(where: { $0.kind == "t3" })?.data,
            let title = cleanInputText(post["title"] as? String)
        else { throw NativeInputError.unreadableContent }
        let author = cleanInputText(post["author"] as? String)
        let subreddit = cleanInputText(post["subreddit_name_prefixed"] as? String)
        let body = cleanInputText(post["selftext"] as? String)
        let linked = httpInputURL(post["url_overridden_by_dest"] as? String)
        let comments = redditComments(listings.dropFirst().first).prefix(20)
        let content = [
            [author.map { "Posted by u/\($0)" }, subreddit.map { "in \($0)" }]
                .compactMap { $0 }.joined(separator: " ").nativeNilIfEmpty,
            body ?? linked.map { "[Open linked content](\($0.absoluteString))" },
            comments.isEmpty ? nil : "## Top comments\n\n" + comments.map {
                "**u/\($0.author)**\n\n\($0.body)"
            }.joined(separator: "\n\n")
        ].compactMap { $0 }.joined(separator: "\n\n")
        let permalink = httpInputURL(post["permalink"] as? String, relativeTo: URL(string: "https://www.reddit.com")!)
        return ItemDraft(
            inputID: .reddit,
            title: title,
            content: content,
            sourceURL: url,
            canonicalURL: permalink ?? URL(string: "https://www.reddit.com/comments/\(postID)")!,
            faviconURL: URL(string: "https://www.reddit.com/favicon.ico")
        )
    } catch {
        if let feed = try? await ingestRedditCommentsFeed(url, http: http) {
            return feed
        }
        if let embedded = try? await ingestRedditEmbed(url, postID: postID, http: http) {
            return embedded
        }
        let endpoint = URL(string: "https://www.reddit.com/oembed?url=\(url.absoluteString.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")")!
        let response = try await http.get(endpoint, headers: ["Accept": "application/json"])
        guard
            let object = try JSONSerialization.jsonObject(with: response.data) as? [String: Any],
            let title = cleanInputText(object["title"] as? String)
        else { throw error }
        let author = cleanInputText(object["author_name"] as? String)
        return ItemDraft(
            inputID: .reddit,
            title: title,
            content: [author.map { "Posted by u/\($0)" }, title].compactMap { $0 }
                .joined(separator: "\n\n"),
            sourceURL: url,
            canonicalURL: URL(string: "https://www.reddit.com/comments/\(postID)")!,
            faviconURL: URL(string: "https://www.reddit.com/favicon.ico")
        )
    }
}

private func ingestRedditCommentsFeed(
    _ url: URL,
    http: InputHTTPClient
) async throws -> ItemDraft {
    guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
        throw NativeInputError.unsupportedInput
    }
    components.scheme = "https"
    components.host = "old.reddit.com"
    components.path = components.path.trimmingCharacters(
        in: CharacterSet(charactersIn: "/")
    )
    components.path = "/\(components.path)/.rss"
    components.queryItems = [
        URLQueryItem(name: "limit", value: "20"),
        URLQueryItem(name: "depth", value: "2"),
        URLQueryItem(name: "sort", value: "top")
    ]
    guard let feedURL = components.url else { throw NativeInputError.unsupportedInput }
    let response = try await http.get(feedURL, headers: [
        "Accept": "application/atom+xml", "User-Agent": "Briefly/1.0"
    ])
    let feed = try parseFeed(response.data, fallbackTitle: "Reddit", baseURL: response.finalURL)
    guard let post = feed.items.first, let body = post.content?.nativeNilIfEmpty else {
        throw NativeInputError.unreadableContent
    }
    let comments = feed.items.dropFirst().prefix(20).compactMap { item -> RedditComment? in
        guard let body = item.content?.nativeNilIfEmpty else { return nil }
        let author = inputRegexCapture(item.title, #"^/u/([^ ]+)\s+on\s+"#) ?? "reddit user"
        return RedditComment(author: author, body: body)
    }
    guard !comments.isEmpty else { throw NativeInputError.unreadableContent }
    let postAuthor = inputRegexCapture(
        response.text,
        #"(?is)<entry\b[^>]*>.*?<author\b[^>]*>.*?<name\b[^>]*>/u/([^<]+)</name>"#
    )
    let content = [
        postAuthor.map { "Posted by u/\($0)" },
        body,
        "## Top comments\n\n" + comments.map {
            "**u/\($0.author)**\n\n\($0.body)"
        }.joined(separator: "\n\n")
    ].compactMap { $0 }.joined(separator: "\n\n")
    return ItemDraft(
        inputID: .reddit,
        title: post.title,
        content: content,
        sourceURL: url,
        canonicalURL: url,
        faviconURL: URL(string: "https://www.reddit.com/favicon.ico")
    )
}

private func ingestRedditEmbed(
    _ url: URL,
    postID: String,
    http: InputHTTPClient
) async throws -> ItemDraft {
    guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
        throw NativeInputError.unsupportedInput
    }
    components.scheme = "https"
    components.host = "www.redditmedia.com"
    components.queryItems = [
        URLQueryItem(name: "ref_source", value: "embed"),
        URLQueryItem(name: "ref", value: "share"),
        URLQueryItem(name: "embed", value: "true")
    ]
    guard let embedURL = components.url else { throw NativeInputError.unsupportedInput }
    let response = try await http.get(embedURL, headers: [
        "Accept": "text/html", "User-Agent": "Mozilla/5.0"
    ])
    let title = inputRegexCapture(response.text, #"(?is)<h1\b[^>]*>([\s\S]*?)</h1>"#)
        .map(inputStripHTML).flatMap(cleanInputText)
    let body = inputRegexCapture(
        response.text,
        #"(?is)\bid=[\"']t3_"# + NSRegularExpression.escapedPattern(for: postID) +
            #"-post-rtjson-content[\"'][^>]*>([\s\S]*?)</div>"#
    ).flatMap { inputReadableHTML("<article>\($0)</article>") }
    guard let title, let body, !body.isEmpty else { throw NativeInputError.unreadableContent }
    let author = inputRegexCapture(response.text, #"(?is)href=[\"'][^\"']*/user/([^/\"'?]+)"#)
        .flatMap(cleanInputText)
    let subreddit = inputRegexCapture(response.text, #"(?is)href=[\"'][^\"']*/r/([^/\"'?]+)"#)
        .flatMap(cleanInputText)
    let attribution = [author.map { "Posted by u/\($0)" }, subreddit.map { "in r/\($0)" }]
        .compactMap { $0 }.joined(separator: " ")
    return ItemDraft(
        inputID: .reddit,
        title: title,
        content: [attribution.nativeNilIfEmpty, body].compactMap { $0 }.joined(separator: "\n\n"),
        sourceURL: url,
        canonicalURL: url,
        faviconURL: URL(string: "https://www.reddit.com/favicon.ico")
    )
}

struct RedditComment {
    let author: String
    let body: String
}


func redditListingChildren(_ listing: [String: Any]?) -> [(kind: String, data: [String: Any])] {
    guard let data = listing?["data"] as? [String: Any],
          let children = data["children"] as? [[String: Any]] else { return [] }
    return children.compactMap {
        guard let kind = $0["kind"] as? String, let data = $0["data"] as? [String: Any] else {
            return nil
        }
        return (kind, data)
    }
}

func redditComments(_ listing: [String: Any]?) -> [RedditComment] {
    var result = [RedditComment]()
    func append(_ children: [[String: Any]]) {
        for child in children where result.count < 20 {
            guard child["kind"] as? String == "t1", let data = child["data"] as? [String: Any] else {
                continue
            }
            if let author = cleanInputText(data["author"] as? String),
               let body = cleanInputText(data["body"] as? String), !["[deleted]", "[removed]"].contains(body) {
                result.append(.init(author: author, body: body))
            }
            if let replies = data["replies"] as? [String: Any],
               let replyData = replies["data"] as? [String: Any],
               let children = replyData["children"] as? [[String: Any]] { append(children) }
        }
    }
    guard let data = listing?["data"] as? [String: Any],
          let children = data["children"] as? [[String: Any]] else { return [] }
    append(children)
    return result
}
