import Foundation

func ingestWebPage(
    _ request: ItemInputRequest,
    context: ItemInputContext
) async throws -> ItemDraft {
    let url = try requestURL(request)
    do {
        let response = try await context.http.get(url)
        if response.contentType.contains("text/plain") {
            var draft = try ingestText(.init(source: .text(response.text)))
            draft.sourceURL = url
            draft.canonicalURL = response.finalURL
            return draft
        }
        if response.contentType.contains("application/pdf") || response.data.starts(with: Data("%PDF-".utf8)) {
            let temporary = FileManager.default.temporaryDirectory
                .appending(path: "\(UUID().uuidString).pdf")
            defer { try? FileManager.default.removeItem(at: temporary) }
            try response.data.write(to: temporary, options: .atomic)
            var draft = try ingestPDF(ItemInputRequest(source: .file(temporary)))
            draft.sourceURL = url
            draft.canonicalURL = response.finalURL
            return draft
        }
        if let feed = parseNativePodcastFeed(response.data, baseURL: response.finalURL),
           let episode = feed.episodes.first {
            return try await ingestPodcast(ItemInputRequest(
                source: .url(episode.link ?? url),
                hints: episode.hints
            ), context: context)
        }
        if looksLikeNativePodcastPage(response.text, url: response.finalURL) {
            return try await ingestPodcast(request, context: context)
        }
        let metadata = inputHTMLMetadata(response.text, baseURL: response.finalURL)
        let content = inputReadableHTML(response.text)
        let titleOnly = content.map {
            $0.split(whereSeparator: \.isWhitespace).count < 10 &&
                cleanInputText($0)?.lowercased() == cleanInputText(metadata.title)?.lowercased()
        } ?? false
        if let content, !titleOnly,
           !looksLikeInputInterstitial("\(metadata.title ?? "")\n\(content)") {
            return ItemDraft(
                inputID: .webPage,
                title: metadata.title ?? response.finalURL.host ?? "Web page",
                content: content,
                sourceURL: url,
                canonicalURL: metadata.canonicalURL ?? response.finalURL,
                faviconURL: metadata.faviconURL
            )
        }
        throw NativeInputError.unreadableContent
    } catch {
        if let render = context.render, let rendered = try? await render(url),
           !rendered.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return ItemDraft(
                inputID: .webPage,
                title: rendered.title,
                content: rendered.content,
                sourceURL: url,
                canonicalURL: rendered.sourceURL,
                faviconData: rendered.faviconData,
                faviconFileExtension: rendered.faviconFileExtension
            )
        }
        if let firecrawl = context.firecrawl, let draft = try? await firecrawl(url) { return draft }
        if let hint = request.hints.content?.nativeNilIfEmpty {
            return ItemDraft(
                inputID: .webPage,
                title: request.hints.title?.nativeNilIfEmpty ?? url.host ?? "Web page",
                content: hint,
                sourceURL: url,
                canonicalURL: url
            )
        }
        throw error
    }
}
