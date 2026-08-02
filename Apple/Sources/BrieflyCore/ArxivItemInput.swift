import Foundation

func ingestArxiv(
    _ request: ItemInputRequest,
    http: InputHTTPClient
) async throws -> ItemDraft {
    let url = try requestURL(request)
    guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
        throw NativeInputError.unsupportedInput
    }
    components.host = "markxiv.org"
    guard let markxivURL = components.url else { throw NativeInputError.unsupportedInput }
    let response = try await http.get(markxivURL)
    let content = response.text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !content.isEmpty else { throw NativeInputError.unreadableContent }
    return ItemDraft(
        inputID: .arxiv,
        title: inputRegexCapture(content, #"(?m)^#\s+(.+)$"#)?.nativeNilIfEmpty ?? "arXiv paper",
        content: content,
        sourceURL: url,
        canonicalURL: url,
        faviconURL: URL(string: "https://arxiv.org/favicon.ico")
    )
}
