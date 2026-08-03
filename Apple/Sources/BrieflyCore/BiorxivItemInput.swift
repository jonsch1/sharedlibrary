import Foundation

func ingestBiorxiv(
    _ request: ItemInputRequest,
    http: InputHTTPClient
) async throws -> ItemDraft {
    let url = try requestURL(request)
    guard let articlePath = biorxivArticlePath(url),
          var articleComponents = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
        throw NativeInputError.unsupportedInput
    }
    articleComponents.scheme = "https"
    articleComponents.host = "www.biorxiv.org"
    articleComponents.path = articlePath
    articleComponents.query = nil
    articleComponents.fragment = nil
    guard let articleURL = articleComponents.url else { throw NativeInputError.unsupportedInput }

    var pdfComponents = articleComponents
    pdfComponents.path = articlePath + ".full.pdf"
    guard let pdfURL = pdfComponents.url else { throw NativeInputError.unsupportedInput }

    async let pageResponse: InputHTTPResponse? = try? await http.get(
        articleURL,
        maximumBytes: 5_000_000
    )
    let pdfResponse = try await fetchBiorxivPDF(pdfURL, http: http)
    guard pdfResponse.contentType.contains("application/pdf") ||
            pdfResponse.data.starts(with: Data("%PDF-".utf8)) else {
        throw NativeInputError.unreadableContent
    }

    let temporary = FileManager.default.temporaryDirectory
        .appending(path: "\(UUID().uuidString).pdf")
    defer { try? FileManager.default.removeItem(at: temporary) }
    try pdfResponse.data.write(to: temporary, options: .atomic)
    var draft = try ingestPDF(.init(source: .file(temporary)))
    let metadata = await pageResponse.map {
        inputHTMLMetadata($0.text, baseURL: $0.finalURL)
    }
    draft.inputID = .biorxiv
    draft.title = request.hints.title?.nativeNilIfEmpty ??
        metadata?.title?.nativeNilIfEmpty ?? draft.title.nativeNilIfEmpty ?? "bioRxiv paper"
    draft.sourceURL = url
    draft.canonicalURL = metadata?.canonicalURL ?? articleURL
    draft.faviconURL = metadata?.faviconURL ?? URL(string: "https://www.biorxiv.org/favicon.ico")
    return draft
}

private func fetchBiorxivPDF(
    _ url: URL,
    http: InputHTTPClient
) async throws -> InputHTTPResponse {
    var retry = 0
    while true {
        do {
            return try await http.get(
                url,
                headers: ["Accept": "application/pdf"],
                maximumBytes: 50_000_000
            )
        } catch {
            guard case NativeInputError.requestFailed(let status) = error,
                  (500..<600).contains(status), retry < 2 else {
                throw error
            }
            retry += 1
            try await Task.sleep(for: retry == 1 ? .milliseconds(400) : .milliseconds(1_200))
        }
    }
}
