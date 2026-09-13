#if os(macOS)
import BrieflyCore
import CryptoKit
import Foundation

@MainActor
final class LibraryInputService {
    let session: LibrarySession
    let captureCoordinator = BrieflyCaptureCoordinator()

    init(session: LibrarySession) {
        self.session = session
    }

    func itemInputContext() -> ItemInputContext {
        .init(
            render: { url in
                let page = try await MacPageExtractor.shared.extractPage(from: url)
                return RenderedInputPage(
                    title: page.title,
                    content: page.text,
                    sourceURL: url,
                    faviconData: page.faviconData,
                    faviconFileExtension: page.faviconFileExtension
                )
            },
            firecrawl: { try await self.session.backend.firecrawl($0) },
            transcribe: { try await self.session.backend.transcribe($0) },
            downloadAudio: { try await self.session.backend.downloadAudio($0) }
        )
    }

    func channelInputContext() -> ChannelInputContext {
        .init(render: { url, limit in
            let page = try await MacPageExtractor.shared.extractPage(from: url)
            let host = url.host?.lowercased() ?? ""
            let isX = host == "x.com" || host.hasSuffix(".x.com") || host.contains("twitter.com")
            let isBiorxiv = (host == "biorxiv.org" || host.hasSuffix(".biorxiv.org")) &&
                url.path.hasPrefix("/search/")
            let preferredInput: ItemInputID = isX ? .x : isBiorxiv ? .biorxiv : .webPage
            if !page.items.isEmpty {
                return ChannelInputBatch(
                    inputID: isX ? .x : .page,
                    title: page.title,
                    kind: .page,
                    items: page.items.prefix(limit).compactMap { item in
                        guard let itemURL = URL(string: item.url) else { return nil }
                        return ChannelItemReference(
                            id: item.id,
                            title: item.title,
                            url: itemURL,
                            publishedAt: item.publishedAt,
                            hints: .init(
                                preferredInput: preferredInput,
                                title: item.title,
                                content: item.content
                            )
                        )
                    }
                )
            }
            let digest = SHA256.hash(data: Data(page.text.utf8))
                .map { String(format: "%02x", $0) }
                .joined()
            return ChannelInputBatch(
                inputID: isX ? .x : .page,
                title: page.title,
                kind: .page,
                items: [.init(
                    id: digest,
                    title: page.title,
                    url: url,
                    hints: .init(
                        preferredInput: .webPage,
                        title: page.title,
                        content: page.text
                    )
                )]
            )
        })
    }
}

#endif
