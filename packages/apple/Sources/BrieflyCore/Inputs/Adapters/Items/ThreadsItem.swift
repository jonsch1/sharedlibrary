#if os(macOS)
import Foundation

func ingestThreads(
    _ request: ItemInputRequest,
    http: InputHTTPClient
) async throws -> ItemDraft {
    let url = try requestURL(request)
    guard let actor = threadsPost(url)?.actor else { throw NativeInputError.unsupportedInput }
    let response = try await http.get(url, headers: [
        "User-Agent": "Mozilla/5.0 (compatible; Googlebot/2.1; +http://www.google.com/bot.html)"
    ])
    let metadata = inputHTMLMetadata(response.text, baseURL: response.finalURL)
    guard let content = metadata.description?.nativeNilIfEmpty else {
        throw NativeInputError.unreadableContent
    }
    return ItemDraft(
        inputID: .threads,
        title: metadata.title ?? "Threads post by @\(actor)",
        content: content,
        sourceURL: url,
        canonicalURL: metadata.canonicalURL ?? url,
        faviconURL: metadata.faviconURL ?? URL(string: "https://www.threads.net/favicon.ico")
    )
}

#endif
