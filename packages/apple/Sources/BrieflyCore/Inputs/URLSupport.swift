import Foundation

public func canonicalItemIdentity(_ value: URL?) -> String? {
    guard let value, var components = URLComponents(url: value, resolvingAgainstBaseURL: false),
          let rawHost = components.host else { return nil }
    let host = rawHost.lowercased().replacingOccurrences(
        of: #"^www\."#, with: "", options: .regularExpression
    )
    let parts = components.path.split(separator: "/").map(String.init)
    if host == "x.com" || host.hasSuffix(".x.com") || host == "twitter.com" ||
        host.hasSuffix(".twitter.com"),
       let status = parts.firstIndex(where: { $0.lowercased() == "status" }),
       parts.indices.contains(status + 1), Int(parts[status + 1]) != nil {
        return "x:status:\(parts[status + 1])"
    }
    if host == "redd.it", let id = parts.first?.lowercased(), !id.isEmpty {
        return "reddit:post:\(id)"
    }
    if host == "reddit.com" || host.hasSuffix(".reddit.com"),
       let comments = parts.firstIndex(where: { $0.lowercased() == "comments" }),
       parts.indices.contains(comments + 1) {
        return "reddit:post:\(parts[comments + 1].lowercased())"
    }
    if (host == "bsky.app" || host == "www.bsky.app"),
       parts.count == 4, parts[0] == "profile", parts[2] == "post" {
        return "bluesky:post:\(parts[1]):\(parts[3])"
    }
    if host == "youtu.be", let id = parts.first { return "youtube:video:\(id)" }
    if host == "youtube.com" || host.hasSuffix(".youtube.com") ||
        host == "youtube-nocookie.com" || host.hasSuffix(".youtube-nocookie.com"),
       let id = components.queryItems?.first(where: { $0.name == "v" })?.value ??
        (["shorts", "live", "embed"].contains(parts.first ?? "") ? parts.dropFirst().first : nil) {
        return "youtube:video:\(id)"
    }
    components.host = host
    components.fragment = nil
    if components.path.count > 1 {
        components.path = components.path.replacingOccurrences(
            of: #"/+$"#, with: "", options: .regularExpression
        )
    }
    let queryItems = components.queryItems?.filter {
        !$0.name.lowercased().hasPrefix("utm_") &&
            !["fbclid", "gclid", "mc_cid", "mc_eid"].contains($0.name.lowercased())
    }.sorted { $0.name == $1.name ? ($0.value ?? "") < ($1.value ?? "") : $0.name < $1.name }
    components.queryItems = queryItems?.isEmpty == true ? nil : queryItems
    return components.url?.absoluteString
}

func requestURL(_ request: ItemInputRequest) throws -> URL {
    guard case .url(let url) = request.source,
          isNativeHTTPURL(url) else {
        throw NativeInputError.unsupportedInput
    }
    guard url.user == nil, url.password == nil else { throw NativeInputError.unsupportedInput }
    return url
}

func httpInputURL(_ value: String?, relativeTo base: URL? = nil) -> URL? {
    guard let value = cleanInputText(value), let url = URL(string: value, relativeTo: base)?.absoluteURL,
          ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil,
          url.user == nil, url.password == nil else { return nil }
    return url
}

func isArxivURL(_ url: URL) -> Bool {
    let host = url.host?.lowercased() ?? ""
    return host == "arxiv.org" || host.hasSuffix(".arxiv.org") || host == "markxiv.org"
}

func isBiorxivURL(_ url: URL) -> Bool { biorxivArticlePath(url) != nil }

func biorxivArticlePath(_ url: URL) -> String? {
    let host = url.host?.lowercased() ?? ""
    guard host == "biorxiv.org" || host.hasSuffix(".biorxiv.org") else { return nil }
    var path = url.path
    while path.hasSuffix("/") { path.removeLast() }
    for suffix in [".full.pdf", ".abstract", ".full"] where path.hasSuffix(suffix) {
        path.removeLast(suffix.count)
        break
    }
    let parts = path.split(separator: "/", omittingEmptySubsequences: true)
    guard parts.count == 3, parts[0] == "content", parts[1].hasPrefix("10."), !parts[2].isEmpty else {
        return nil
    }
    return "/" + parts.joined(separator: "/")
}

func youtubeVideoID(_ url: URL) -> String? {
    let host = url.host?.lowercased().replacingOccurrences(of: "www.", with: "") ?? ""
    let parts = url.path.split(separator: "/").map(String.init)
    let value: String?
    if host == "youtu.be" {
        value = parts.first
    } else if host == "youtube.com" || host.hasSuffix(".youtube.com") ||
        host == "youtube-nocookie.com" || host.hasSuffix(".youtube-nocookie.com") {
        value = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .first(where: { $0.name == "v" })?.value ??
            (["shorts", "live", "embed"].contains(parts.first ?? "") ? parts.dropFirst().first : nil)
    } else {
        value = nil
    }
    guard let value, value.range(of: #"^[A-Za-z0-9_-]{6,32}$"#, options: .regularExpression) != nil else {
        return nil
    }
    return value
}

func redditPostID(_ url: URL) -> String? {
    let host = url.host?.lowercased() ?? ""
    let parts = url.path.split(separator: "/").map(String.init)
    if host == "redd.it" { return parts.first?.nativeNilIfEmpty }
    guard host == "reddit.com" || host.hasSuffix(".reddit.com"),
          let index = parts.firstIndex(where: { $0.lowercased() == "comments" }),
          parts.indices.contains(index + 1) else { return nil }
    return parts[index + 1].nativeNilIfEmpty
}

func xStatus(_ url: URL) -> (actor: String, id: String)? {
    let host = url.host?.lowercased() ?? ""
    let parts = url.path.split(separator: "/").map(String.init)
    guard host == "x.com" || host.hasSuffix(".x.com") || host == "twitter.com" ||
        host.hasSuffix(".twitter.com"), let index = parts.firstIndex(where: { $0.lowercased() == "status" }),
        index > 0, parts.indices.contains(index + 1), Int(parts[index + 1]) != nil else { return nil }
    return (parts[index - 1], parts[index + 1])
}

func blueskyPost(_ url: URL) -> (actor: String, rkey: String)? {
    let parts = url.path.split(separator: "/").map(String.init)
    guard ["bsky.app", "www.bsky.app"].contains(url.host?.lowercased() ?? ""), parts.count == 4,
          parts[0] == "profile", parts[2] == "post" else { return nil }
    return (parts[1], parts[3])
}

func threadsPost(_ url: URL) -> (actor: String, id: String)? {
    let host = url.host?.lowercased() ?? ""
    let parts = url.path.split(separator: "/").map(String.init)
    guard host == "threads.net" || host.hasSuffix(".threads.net") || host == "threads.com" ||
        host.hasSuffix(".threads.com"), parts.count >= 3, parts[0].hasPrefix("@"),
        ["post", "t"].contains(parts[1]) else { return nil }
    return (String(parts[0].dropFirst()), parts[2])
}

func isTikTokURL(_ url: URL) -> Bool {
    let host = url.host?.lowercased() ?? ""
    return host == "tiktok.com" || host.hasSuffix(".tiktok.com") || host == "vm.tiktok.com"
}
