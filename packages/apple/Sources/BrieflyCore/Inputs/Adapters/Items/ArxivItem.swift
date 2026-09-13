#if os(macOS)
import Foundation

func ingestArxiv(
    _ request: ItemInputRequest,
    http: InputHTTPClient
) async throws -> ItemDraft {
    let url = try requestURL(request)
    do {
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
    } catch {
        let pdfURL = try arxivPDFURL(for: url)
        let response = try await http.get(pdfURL)
        guard response.contentType.contains("application/pdf") ||
            response.data.starts(with: Data("%PDF-".utf8)) else {
            throw NativeInputError.unreadableContent
        }
        let temporary = FileManager.default.temporaryDirectory
            .appending(path: "(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try response.data.write(to: temporary, options: .atomic)
        var draft = try ingestPDF(.init(source: .file(temporary)))
        draft.inputID = .arxiv
        draft.sourceURL = url
        draft.canonicalURL = response.finalURL
        draft.faviconURL = URL(string: "https://arxiv.org/favicon.ico")
        return draft
    }
}

private func arxivPDFURL(for url: URL) throws -> URL {
    guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
        throw NativeInputError.unsupportedInput
    }
    let path = components.path
    let identifier: String
    if path.hasPrefix("/abs/") {
        identifier = String(path.dropFirst("/abs/".count))
    } else if path.hasPrefix("/pdf/") {
        identifier = String(path.dropFirst("/pdf/".count)).replacingOccurrences(of: ".pdf", with: "")
    } else {
        throw NativeInputError.unsupportedInput
    }
    guard !identifier.isEmpty else { throw NativeInputError.unsupportedInput }
    components.host = "arxiv.org"
    components.path = "/pdf/\(identifier).pdf"
    components.query = nil
    components.fragment = nil
    guard let pdfURL = components.url else { throw NativeInputError.unsupportedInput }
    return pdfURL
}

#endif
