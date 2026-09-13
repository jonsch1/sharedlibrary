#if os(macOS)
import Foundation

@MainActor
func enumerateXChannel(
    source: String,
    maximumItems: Int,
    context: ChannelInputContext
) async throws -> ChannelInputBatch {
    guard let url = httpInputURL(source) else { throw NativeInputError.unsupportedInput }
    let actor = url.path.split(separator: "/").first.map(String.init) ?? ""
    guard !actor.isEmpty else { throw NativeInputError.unsupportedInput }
    let encodedActor = actor.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? actor
    var components = URLComponents(
        string: "https://api.fxtwitter.com/2/profile/\(encodedActor)/statuses"
    )!
    components.queryItems = [URLQueryItem(name: "count", value: String(maximumItems))]
    if let endpoint = components.url,
       let response = try? await context.http.get(
           endpoint,
           headers: ["Accept": "application/json", "User-Agent": "Briefly/1.0"],
           maximumBytes: 12_000_000
       ),
       let object = try? JSONSerialization.jsonObject(with: response.data) as? [String: Any],
       let statuses = object["results"] as? [[String: Any]]
    {
        let items = statuses.prefix(maximumItems).compactMap { status -> ChannelItemReference? in
            let rawID = status["id"] as? String ?? (status["id"] as? NSNumber)?.stringValue
            guard let id = rawID, !id.isEmpty,
                  let itemURL = URL(string: "https://x.com/\(actor)/status/\(id)"),
                  let draft = try? xDraft(from: status, sourceURL: itemURL)
            else { return nil }
            return .init(
                id: id,
                title: draft.title,
                url: itemURL,
                publishedAt: cleanInputText(status["created_at"] as? String ?? ""),
                hints: .init(preferredInput: .x, title: draft.title, content: draft.content)
            )
        }
        if !items.isEmpty {
            return .init(
                inputID: .x,
                title: "@\(actor) on X",
                kind: .page,
                items: Array(items)
            )
        }
    }
    guard let render = context.render else { throw NativeInputError.missingBrowserSession }
    return inputLimitedBatch(try await render(url, maximumItems), maximumItems: maximumItems)
}

#endif
