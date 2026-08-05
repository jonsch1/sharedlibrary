import Foundation

@MainActor
func enumerateXChannel(
    source: String,
    maximumItems: Int,
    context: ChannelInputContext
) async throws -> ChannelInputBatch {
    guard let url = httpInputURL(source) else { throw NativeInputError.unsupportedInput }
    if let response = try? await context.http.get(url, maximumBytes: 12_000_000) {
        let actor = url.path.split(separator: "/").first.map(String.init) ?? "x"
        let items = inputRegexCaptures(
            response.text,
            #"(?is)(<article\b[^>]*\bdata-tweet-id=["'][^"']+["'][^>]*>.*?</article>)"#
        ).prefix(maximumItems).compactMap { article -> ChannelItemReference? in
            guard
                let id = inputRegexCapture(article, #"\bdata-tweet-id=["'](\d+)["']"#),
                let itemURL = URL(string: "https://x.com/\(actor)/status/\(id)"),
                let content = cleanInputText(inputStripHTML(article))
            else { return nil }
            let publishedAt = inputRegexCaptures(article, #"(?is)<meta\b[^>]*>"#)
                .first { inputHTMLAttribute("itemprop", in: $0).lowercased() == "datepublished" }
                .flatMap { cleanInputText(inputHTMLAttribute("content", in: $0)) }
            return .init(
                id: id,
                title: nativeFirstUsefulLine(content),
                url: itemURL,
                publishedAt: publishedAt,
                hints: .init(preferredInput: .x, title: nativeFirstUsefulLine(content), content: content)
            )
        }
        if !items.isEmpty {
            let metadata = inputHTMLMetadata(response.text, baseURL: response.finalURL)
            return .init(
                inputID: .x,
                title: metadata.title ?? "@\(actor) on X",
                kind: .page,
                items: Array(items)
            )
        }
    }
    guard let render = context.render else { throw NativeInputError.missingBrowserSession }
    return inputLimitedBatch(try await render(url, maximumItems), maximumItems: maximumItems)
}
