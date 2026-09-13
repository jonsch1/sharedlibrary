#if os(macOS)
import Foundation

func ingestBiorxiv(
    _ request: ItemInputRequest,
    context: ItemInputContext
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

    let pdfResponse: InputHTTPResponse
    do {
        pdfResponse = try await fetchBiorxivPDF(pdfURL, http: context.http)
    } catch {
        if let rendered = await renderedBiorxivFullText(
            articleComponents: articleComponents,
            sourceURL: url,
            titleHint: request.hints.title,
            render: context.render
        ) {
            return rendered
        }
        throw error
    }
    guard pdfResponse.contentType.contains("application/pdf") ||
            pdfResponse.data.starts(with: Data("%PDF-".utf8)) else {
        if let rendered = await renderedBiorxivFullText(
            articleComponents: articleComponents,
            sourceURL: url,
            titleHint: request.hints.title,
            render: context.render
        ) {
            return rendered
        }
        throw NativeInputError.unreadableContent
    }
    let pageResponse = try? await context.http.get(
        articleURL,
        maximumBytes: 5_000_000
    )

    let temporary = FileManager.default.temporaryDirectory
        .appending(path: "\(UUID().uuidString).pdf")
    defer { try? FileManager.default.removeItem(at: temporary) }
    try pdfResponse.data.write(to: temporary, options: .atomic)
    var draft = try ingestPDFFile(at: temporary, maximumBytes: 50_000_000)
    let metadata = pageResponse.map {
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

@MainActor
private func renderedBiorxivFullText(
    articleComponents: URLComponents,
    sourceURL: URL,
    titleHint: String?,
    render: (@MainActor @Sendable (URL) async throws -> RenderedInputPage)?
) async -> ItemDraft? {
    guard let render else { return nil }
    var fullComponents = articleComponents
    fullComponents.path += ".full"
    guard let fullURL = fullComponents.url,
          let page = try? await render(fullURL),
          let content = page.content.nativeNilIfEmpty,
          content.count >= 1_000,
          isNativeHTTPURL(page.sourceURL),
          page.sourceURL.user == nil,
          page.sourceURL.password == nil else {
        return nil
    }
    return ItemDraft(
        inputID: .biorxiv,
        title: titleHint?.nativeNilIfEmpty ?? page.title.nativeNilIfEmpty ?? "bioRxiv paper",
        content: content,
        sourceURL: sourceURL,
        canonicalURL: sourceURL,
        faviconData: page.faviconData,
        faviconFileExtension: page.faviconFileExtension
    )
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

#endif
