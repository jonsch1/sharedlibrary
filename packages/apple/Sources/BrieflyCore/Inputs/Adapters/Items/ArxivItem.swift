#if os(macOS)
import Foundation

func ingestArxiv(
    _ request: ItemInputRequest,
    http: InputHTTPClient
) async throws -> ItemDraft {
    let url = try requestURL(request)
    let identifier = try arxivIdentifier(url)
    let canonicalURL = try arxivURL(host: "arxiv.org", path: "/abs/\(identifier)")
    do {
        let markxivURL = try arxivURL(host: "markxiv.org", path: "/abs/\(identifier)")
        let response = try await http.get(markxivURL)
        let content = response.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { throw NativeInputError.unreadableContent }
        return ItemDraft(
            inputID: .arxiv,
            title: inputRegexCapture(content, #"(?m)^#\s+(.+)$"#)?.nativeNilIfEmpty ?? "arXiv paper",
            content: content,
            sourceURL: url,
            canonicalURL: canonicalURL,
            faviconURL: URL(string: "https://arxiv.org/favicon.ico")
        )
    } catch {
        let pdfURL = try arxivURL(host: "arxiv.org", path: "/pdf/\(identifier).pdf")
        let response = try await http.get(pdfURL)
        guard response.contentType.contains("application/pdf") ||
            response.data.starts(with: Data("%PDF-".utf8)) else {
            throw NativeInputError.unreadableContent
        }
        let temporary = FileManager.default.temporaryDirectory
            .appending(path: "\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try response.data.write(to: temporary, options: .atomic)
        var draft = try ingestPDF(.init(source: .file(temporary)))
        draft.inputID = .arxiv
        draft.sourceURL = url
        draft.canonicalURL = canonicalURL
        draft.faviconURL = URL(string: "https://arxiv.org/favicon.ico")
        return draft
    }
}

/// The paper ID from an arXiv abstract, PDF, or HTML link, such as `2607.12474v2`.
private func arxivIdentifier(_ url: URL) throws -> String {
    var path = url.path
    while path.hasSuffix("/") { path.removeLast() }
    guard let prefix = ["/abs/", "/pdf/", "/html/"].first(where: path.hasPrefix) else {
        throw NativeInputError.unsupportedInput
    }
    var identifier = String(path.dropFirst(prefix.count))
    if identifier.hasSuffix(".pdf") { identifier.removeLast(".pdf".count) }
    guard !identifier.isEmpty else { throw NativeInputError.unsupportedInput }
    return identifier
}

private func arxivURL(host: String, path: String) throws -> URL {
    var components = URLComponents()
    components.scheme = "https"
    components.host = host
    components.path = path
    guard let url = components.url else { throw NativeInputError.unsupportedInput }
    return url
}

#endif
