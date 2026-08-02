import Foundation
import XCTest
@testable import BrieflyCore

private let realItemTestURLs: [(ItemInputID, URL)] = [
    (.text, URL(string: "https://www.rfc-editor.org/rfc/rfc9110.txt")!),
    (.pdf, URL(string: "https://www.rfc-editor.org/rfc/rfc9110.pdf")!),
    (.arxiv, URL(string: "https://arxiv.org/abs/1706.03762")!),
    (.youtube, URL(string: "https://www.youtube.com/watch?v=jNQXAC9IVRw")!),
    (.podcast, URL(string: "https://inandaroundpodcasting.com/episode/behind-the-scenes")!),
    (.reddit, URL(string: "https://www.reddit.com/r/IAmA/comments/z1c9z/i_am_barack_obama_president_of_the_united_states/")!),
    (.x, URL(string: "https://x.com/jack/status/20")!),
    (.bluesky, URL(string: "https://bsky.app/profile/bsky.app/post/3lsyqmukj3c2b")!),
    (.threads, URL(string: "https://www.threads.com/@zuck/post/C-srcchPpp7")!),
    (.tiktok, URL(string: "https://www.tiktok.com/@scout2015/video/6718335390845095173")!),
    (.webPage, URL(string: "https://example.com/")!)
]

private let realChannelTestURLs: [(ChannelInputID, URL)] = [
    (.feed, URL(string: "https://hnrss.org/frontpage")!),
    (.youtube, URL(string: "https://www.youtube.com/channel/UC_x5XG1OV2P6uZZ5FSM9Ttw")!),
    (.podcast, URL(string: "https://feeds.truefans.fm/rss/6750170d97d4af53ccbaec06/")!),
    (.reddit, URL(string: "https://www.reddit.com/r/swift/")!),
    (.x, URL(string: "https://x.com/openai")!),
    (.arxiv, URL(string: "https://arxiv.org/list/cs.AI/recent")!),
    (.hackerNews, URL(string: "https://news.ycombinator.com/")!),
    (.page, URL(string: "https://example.com/")!)
]

@MainActor
final class NativeItemInputTests: XCTestCase {
    private let router = NativeItemInputRouter()

    func testEveryItemInputHasARealTestURL() {
        assertRealTestURLs(
            realItemTestURLs.map { ($0.0.rawValue, $0.1) },
            expectedIDs: ItemInputID.allCases.map(\.rawValue)
        )
    }

    func testTextInput() async throws {
        let url = itemTestURL(.text)
        let value = try await router.ingest(
            .init(source: .url(url)),
            context: .init(http: fixtureHTTP([
                "rfc/rfc9110.txt": .text("HTTP Semantics\nWith detail.", "text/plain")
            ]))
        )
        XCTAssertEqual(value.inputID, .text)
        XCTAssertEqual(value.title, "HTTP Semantics")
        XCTAssertEqual(value.sourceURL, url)
    }

    func testClipboardTextInput() async throws {
        let value = try await router.ingest(.init(source: .text("A useful note\nWith detail.")))
        XCTAssertEqual(value.inputID, .text)
        XCTAssertEqual(value.title, "A useful note")
    }

    func testLocalPDFInput() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "input-\(UUID()).pdf")
        try fixturePDF(text: "Native PDF content", title: "Native report").write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let value = try await router.ingest(.init(source: .file(url)))
        XCTAssertEqual(value.inputID, .pdf)
        XCTAssertEqual(value.title, "Native report")
        XCTAssertTrue(value.content.contains("Native PDF content"))
    }

    func testArxivInput() async throws {
        let value = try await router.ingest(
            .init(source: .url(itemTestURL(.arxiv))),
            context: .init(http: fixtureHTTP([
                "markxiv.org/abs/1706.03762": .text("# Attention Is All You Need\n\nPaper body.", "text/markdown")
            ]))
        )
        XCTAssertEqual(value.inputID, .arxiv)
        XCTAssertEqual(value.title, "Attention Is All You Need")
    }

    func testYouTubeInput() async throws {
        let player: [String: Any] = [
            "videoDetails": ["title": "Native video", "author": "Briefly", "shortDescription": "Demo"],
            "captions": ["playerCaptionsTracklistRenderer": ["captionTracks": [[
                "baseUrl": "https://www.youtube.com/api/timedtext?v=jNQXAC9IVRw&lang=en",
                "languageCode": "en"
            ]]]],
            "streamingData": ["adaptiveFormats": [[
                "mimeType": "audio/mpeg", "url": "https://traffic.libsyn.com/atpfm/atp300.mp3"
            ]]]
        ]
        let captions: [String: Any] = ["events": [
            ["segs": [["utf8": "First line."]]], ["segs": [["utf8": "Second line."]]]
        ]]
        let value = try await router.ingest(
            .init(source: .url(itemTestURL(.youtube)), retainAudio: true),
            context: .init(
                http: fixtureHTTP([
                    "youtubei/v1/player": .json(player),
                    "youtube.com/api/timedtext": .json(captions)
                ]),
                downloadAudio: { _ in (Data("audio".utf8), "audio/mp4") }
            )
        )
        XCTAssertEqual(value.inputID, .youtube)
        XCTAssertTrue(value.transcriptAvailable)
        XCTAssertTrue(value.content.contains("Second line"))
        XCTAssertEqual(value.audioData, Data("audio".utf8))
    }

    func testPodcastInput() async throws {
        let episode = itemTestURL(.podcast)
        let media = URL(string: "https://traffic.libsyn.com/atpfm/atp300.mp3")!
        let value = try await router.ingest(
            .init(
                source: .url(episode),
                hints: .init(
                    preferredInput: .podcast,
                    title: "Behind the Scenes",
                    mediaURL: media
                )
            ),
            context: .init(http: fixtureHTTP([:]), transcribe: { _ in
                InputTranscript(text: "Spoken words.", language: "en")
            })
        )
        XCTAssertEqual(value.inputID, .podcast)
        XCTAssertEqual(value.mediaURL, media)
        XCTAssertTrue(value.content.contains("Spoken words"))
    }

    func testRedditInput() async throws {
        let payload: [Any] = [
            ["data": ["children": [["kind": "t3", "data": [
                "title": "Native Reddit post", "author": "reader", "subreddit_name_prefixed": "r/native",
                "selftext": "Post body",
                "permalink": "/r/IAmA/comments/z1c9z/i_am_barack_obama_president_of_the_united_states/"
            ]]]]],
            ["data": ["children": [["kind": "t1", "data": [
                "author": "commenter", "body": "Useful reply"
            ]]]]]
        ]
        let value = try await router.ingest(
            .init(source: .url(itemTestURL(.reddit))),
            context: .init(http: fixtureHTTP(["comments/z1c9z.json": .json(payload)]))
        )
        XCTAssertEqual(value.inputID, .reddit)
        XCTAssertTrue(value.content.contains("Useful reply"))
    }

    func testXInput() async throws {
        let value = try await router.ingest(
            .init(source: .url(itemTestURL(.x))),
            context: .init(http: fixtureHTTP(["api.fxtwitter.com/jack/status/20": .json([
                "tweet": [
                    "raw_text": "Native X post", "created_at": "today", "likes": 4,
                    "author": ["name": "Briefly", "screen_name": "briefly"]
                ]
            ])]))
        )
        XCTAssertEqual(value.inputID, .x)
        XCTAssertTrue(value.content.contains("Native X post"))
    }

    func testBlueskyInput() async throws {
        let value = try await router.ingest(
            .init(source: .url(itemTestURL(.bluesky))),
            context: .init(http: fixtureHTTP([
                "resolveHandle": .json(["did": "did:plc:native"]),
                "getPostThread": .json(["thread": ["post": [
                    "record": ["text": "Native Bluesky post", "createdAt": "today"],
                    "author": ["handle": "test.bsky.social", "displayName": "Tester"],
                    "likeCount": 2
                ]]])
            ]))
        )
        XCTAssertEqual(value.inputID, .bluesky)
        XCTAssertTrue(value.content.contains("Native Bluesky post"))
    }

    func testThreadsInput() async throws {
        let html = """
        <html><head><meta property="og:title" content="Native thread">
        <meta property="og:description" content="A native Threads post"></head></html>
        """
        let value = try await router.ingest(
            .init(source: .url(itemTestURL(.threads))),
            context: .init(http: fixtureHTTP(["threads.com/@zuck/post/C-srcchPpp7": .text(html)]))
        )
        XCTAssertEqual(value.inputID, .threads)
        XCTAssertTrue(value.content.contains("native Threads"))
    }

    func testTikTokInput() async throws {
        let value = try await router.ingest(
            .init(source: .url(itemTestURL(.tiktok))),
            context: .init(http: fixtureHTTP(["tiktok.com/oembed": .json([
                "title": "Native TikTok caption", "author_name": "Briefly"
            ])]))
        )
        XCTAssertEqual(value.inputID, .tiktok)
        XCTAssertTrue(value.content.contains("Native TikTok caption"))
    }

    func testGeneralPageInput() async throws {
        let html = """
        <html><head><title>Example Domain</title><link rel="canonical" href="https://example.com/"></head>
        <body><article><h1>Native web page</h1><p>This is the readable article body.</p></article></body></html>
        """
        let value = try await router.ingest(
            .init(source: .url(itemTestURL(.webPage))),
            context: .init(http: fixtureHTTP(["example.com": .text(html)]))
        )
        XCTAssertEqual(value.inputID, .webPage)
        XCTAssertTrue(value.content.contains("readable article body"))
        XCTAssertEqual(value.canonicalKey, "https://example.com/")
    }

    func testURLCredentialsAreRejected() async {
        do {
            _ = try await router.ingest(
                .init(source: .url(URL(string: "https://user:secret@example.com/")!)),
                context: .init(http: fixtureHTTP([:]))
            )
            XCTFail("Expected credentials to be rejected")
        } catch {}
    }

    func testPDFInput() async throws {
        let url = itemTestURL(.pdf)
        let value = try await router.ingest(
            .init(source: .url(url)),
            context: .init(http: fixtureHTTP([
                "rfc/rfc9110.pdf": .init(
                    data: fixturePDF(text: "Remote PDF", title: "Remote report"),
                    contentType: "application/pdf"
                )
            ]))
        )
        XCTAssertEqual(value.inputID, .pdf)
        XCTAssertEqual(value.sourceURL, url)
        XCTAssertTrue(value.content.contains("Remote PDF"))
    }

    func testSpecializedFailureUsesFirecrawlFallback() async throws {
        let url = itemTestURL(.x)
        let value = try await router.ingest(
            .init(source: .url(url)),
            context: .init(
                http: fixtureHTTP([:]),
                firecrawl: { url in
                    ItemDraft(
                        inputID: .webPage,
                        title: "Fallback capture",
                        content: "Fallback content",
                        sourceURL: url,
                        canonicalURL: url
                    )
                }
            )
        )
        XCTAssertEqual(value.inputID, .webPage)
        XCTAssertEqual(value.content, "Fallback content")
    }
}

@MainActor
final class NativeChannelInputTests: XCTestCase {
    private let router = NativeChannelInputRouter()

    func testEveryChannelInputHasARealTestURL() {
        assertRealTestURLs(
            realChannelTestURLs.map { ($0.0.rawValue, $0.1) },
            expectedIDs: ChannelInputID.allCases.map(\.rawValue)
        )
    }

    func testFeedChannelInput() async throws {
        let batch = try await enumerate(
            channelTestURL(.feed).absoluteString,
            fixtures: ["hnrss.org/frontpage": .text(feedXML(), "application/rss+xml")]
        )
        XCTAssertEqual(batch.inputID, .feed)
        XCTAssertEqual(batch.items.first?.title, "Native story")
    }

    func testYouTubeChannelInput() async throws {
        let atom = """
        <feed><title>Google for Developers</title><entry><id>yt:video:jNQXAC9IVRw</id><title>Me at the zoo</title>
        <link href="https://www.youtube.com/watch?v=jNQXAC9IVRw"/><published>2005-04-24T03:31:52Z</published></entry></feed>
        """
        let batch = try await enumerate(
            channelTestURL(.youtube).absoluteString,
            fixtures: ["feeds/videos.xml": .text(atom, "application/atom+xml")]
        )
        XCTAssertEqual(batch.inputID, .youtube)
        XCTAssertEqual(batch.items.first?.hints.preferredInput, .youtube)
    }

    func testPodcastChannelInput() async throws {
        let podcast = """
        <rss><channel><title>In &amp; Around Podcasting</title><item><guid>behind-the-scenes</guid><title>Behind the Scenes</title>
        <link>\(itemTestURL(.podcast).absoluteString)</link><description>Why we created the show.</description>
        <enclosure url="https://traffic.libsyn.com/atpfm/atp300.mp3" type="audio/mpeg"/>
        </item></channel></rss>
        """
        let batch = try await enumerate(
            channelTestURL(.podcast).absoluteString,
            fixtures: [
                "feeds.truefans.fm/rss/6750170d97d4af53ccbaec06": .text(podcast, "application/rss+xml")
            ]
        )
        XCTAssertEqual(batch.inputID, .podcast)
        XCTAssertEqual(batch.items.first?.url, itemTestURL(.podcast))
        XCTAssertEqual(batch.items.first?.hints.mediaURL?.absoluteString, "https://traffic.libsyn.com/atpfm/atp300.mp3")
    }

    func testRedditCommunityChannelInput() async throws {
        let batch = try await enumerate(
            channelTestURL(.reddit).absoluteString,
            fixtures: ["/r/swift/.rss": .text(
                feedXML(itemURL: itemTestURL(.reddit).absoluteString),
                "application/atom+xml"
            )]
        )
        XCTAssertEqual(batch.inputID, .reddit)
        XCTAssertEqual(batch.items.first?.hints.preferredInput, .reddit)
    }

    func testXProfileChannelInput() async throws {
        let context = ChannelInputContext(http: fixtureHTTP([:]), render: { url, _ in
            .init(inputID: .x, title: "Briefly on X", kind: .page, items: [
                .init(
                    id: "123456",
                    title: "Native X post",
                    url: itemTestURL(.x),
                    hints: .init(preferredInput: .x, title: "Native X post", content: "Post body")
                )
            ])
        })
        let batch = try await router.enumerate(
            source: channelTestURL(.x).absoluteString,
            context: context
        )
        XCTAssertEqual(batch.inputID, .x)
        XCTAssertEqual(batch.items.first?.id, "123456")
    }

    func testArxivChannelInput() async throws {
        let atom = """
        <feed><title>cs.AI</title><entry><id>https://arxiv.org/abs/1706.03762</id><title>Attention Is All You Need</title>
        <link href="https://arxiv.org/abs/1706.03762"/><updated>2023-08-02T00:00:00Z</updated></entry></feed>
        """
        let batch = try await enumerate(
            channelTestURL(.arxiv).absoluteString,
            fixtures: ["export.arxiv.org/api/query": .text(atom, "application/atom+xml")]
        )
        XCTAssertEqual(batch.inputID, .arxiv)
        XCTAssertEqual(batch.items.first?.hints.preferredInput, .arxiv)
    }

    func testHackerNewsChannelInput() async throws {
        let html = """
        <html><table><tr class="athing" id="8863"><td><span class="titleline">
        <a href="https://news.ycombinator.com/item?id=8863">My YC app: Dropbox</a></span></td></tr></table></html>
        """
        let batch = try await enumerate(
            channelTestURL(.hackerNews).absoluteString,
            fixtures: ["news.ycombinator.com": .text(html)]
        )
        XCTAssertEqual(batch.inputID, .hackerNews)
        XCTAssertEqual(batch.items.first?.id, "8863")
    }

    func testPageWatcherChannelInputUsesContentHash() async throws {
        let first = try await enumerate(
            channelTestURL(.page).absoluteString,
            fixtures: ["example.com": .text("<title>Example Domain</title><main>First native version</main>")]
        )
        let second = try await enumerate(
            channelTestURL(.page).absoluteString,
            fixtures: ["example.com": .text("<title>Example Domain</title><main>Second native version</main>")]
        )
        XCTAssertEqual(first.inputID, .page)
        XCTAssertNotEqual(first.items.first?.id, second.items.first?.id)
        XCTAssertEqual(first.items.first?.url, channelTestURL(.page))
    }

    private func enumerate(
        _ source: String,
        fixtures: [String: Fixture]
    ) async throws -> ChannelInputBatch {
        try await router.enumerate(
            source: source,
            context: .init(http: fixtureHTTP(fixtures))
        )
    }
}

@MainActor
final class LiveInputURLTests: XCTestCase {
    func testTextItemIngestsLiveContent() async throws {
        let draft = try await assertLiveItem(.text, contains: ["HTTP Semantics", "IANA Considerations"])
        XCTAssertTrue(draft.title.contains("Internet Engineering Task Force"))
        XCTAssertFalse(draft.title.contains("\u{FEFF}"))
        XCTAssertGreaterThan(draft.content.count, 400_000)
    }

    func testPDFItemIngestsLiveContent() async throws {
        let draft = try await assertLiveItem(.pdf, contains: ["HTTP Semantics", "IANA Considerations"])
        XCTAssertGreaterThan(draft.content.count, 400_000)
    }

    func testArxivItemIngestsLiveContent() async throws {
        let draft = try await assertLiveItem(
            .arxiv,
            contains: ["Attention Is All You Need", "English Constituency Parsing"]
        )
        XCTAssertGreaterThan(draft.content.count, 40_000)
    }

    func testYouTubeItemIngestsLiveContent() async throws {
        let draft = try await assertLiveItem(
            .youtube,
            contains: ["in front of the\nelephants", "pretty much all there is to\nsay"]
        )
        XCTAssertTrue(draft.transcriptAvailable)
        XCTAssertGreaterThan(draft.content.count, 200)
    }

    func testPodcastItemIngestsLiveContent() async throws {
        let draft = try await assertLiveItem(
            .podcast,
            hints: .init(preferredInput: .podcast),
            contains: ["Hello and welcome to this bonus episode", "their chance to shine"]
        )
        XCTAssertTrue(draft.transcriptAvailable)
        XCTAssertGreaterThan(draft.content.count, 30_000)
    }

    func testRedditItemIngestsLiveContent() async throws {
        let draft = try await assertLiveItem(
            .reddit,
            contains: [
                "Ask me anything", "NOT BAD!", "## Top comments",
                "He said he would do an AMA for 30 min"
            ]
        )
        XCTAssertGreaterThan(draft.content.count, 5_000)
    }

    func testXItemIngestsLiveContent() async throws {
        try await assertLiveItem(.x, contains: ["just setting up my twttr"])
    }

    func testBlueskyItemIngestsLiveContent() async throws {
        let draft = try await assertLiveItem(.bluesky, contains: ["Verification update"])
        XCTAssertGreaterThan(draft.content.count, 400)
    }

    func testThreadsItemIngestsLiveContent() async throws {
        try await assertLiveItem(.threads, contains: ["post insights", "multiple drafts"])
    }

    func testTikTokItemIngestsLiveContent() async throws {
        try await assertLiveItem(.tiktok, contains: ["Scramble up ur name"])
    }

    func testWebPageItemIngestsLiveContent() async throws {
        try await assertLiveItem(.webPage, contains: ["Example Domain", "documentation examples"])
    }

    func testFeedChannelDiscoversAndIngestsLiveItem() async throws {
        try await assertLiveChannel(.feed, contains: ["Hacker News"])
    }

    func testYouTubeChannelDiscoversAndIngestsLiveItem() async throws {
        let draft = try await assertLiveChannel(.youtube, contains: ["Google"])
        XCTAssertEqual(draft.inputID, .youtube)
        XCTAssertTrue(draft.transcriptAvailable)
    }

    func testPodcastChannelDiscoversAndIngestsLiveItem() async throws {
        let draft = try await assertLiveChannel(.podcast, contains: ["Podcasting 2.0 in Practice"])
        XCTAssertEqual(draft.inputID, .podcast)
        XCTAssertTrue(draft.transcriptAvailable)
        XCTAssertGreaterThan(draft.content.count, 5_000)
    }

    func testRedditChannelDiscoversAndIngestsLiveItem() async throws {
        try await assertLiveChannel(.reddit, contains: ["Swift"])
    }

    func testXChannelDiscoversAndIngestsLiveItem() async throws {
        try await assertLiveChannel(.x, contains: ["OpenAI"])
    }

    func testArxivChannelDiscoversAndIngestsLiveItem() async throws {
        let draft = try await assertLiveChannel(.arxiv, contains: ["cs.AI"])
        XCTAssertEqual(draft.inputID, .arxiv)
        XCTAssertGreaterThan(draft.content.count, 10_000)
    }

    func testHackerNewsChannelDiscoversAndIngestsLiveItem() async throws {
        try await assertLiveChannel(.hackerNews, contains: ["Hacker News"])
    }

    func testPageChannelDiscoversAndIngestsLiveItem() async throws {
        try await assertLiveChannel(.page, contains: ["Example Domain"])
    }

    @discardableResult
    private func assertLiveItem(
        _ id: ItemInputID,
        hints: ItemInputHints = .init(),
        contains expected: [String]
    ) async throws -> ItemDraft {
        let draft = try await NativeItemInputRouter().ingest(
            .init(source: .url(itemTestURL(id)), hints: hints)
        )
        XCTAssertEqual(draft.inputID, id)
        let output = "\(draft.title)\n\(draft.content)"
        XCTAssertGreaterThan(draft.content.trimmingCharacters(in: .whitespacesAndNewlines).count, 20)
        for value in expected {
            XCTAssertTrue(
                output.localizedCaseInsensitiveContains(value),
                "\(id.rawValue) did not ingest expected live content ‘\(value)’\n\(output.prefix(1_000))"
            )
        }
        return draft
    }

    @discardableResult
    private func assertLiveChannel(
        _ id: ChannelInputID,
        contains expected: [String]
    ) async throws -> ItemDraft {
        let batch = try await NativeChannelInputRouter().enumerate(
            source: channelTestURL(id).absoluteString,
            maximumItems: 3
        )
        XCTAssertEqual(batch.inputID, id)
        let item = try XCTUnwrap(batch.items.first)
        let discovery = ([batch.title] + batch.items.map(\.title)).joined(separator: "\n")
        for value in expected {
            XCTAssertTrue(
                discovery.localizedCaseInsensitiveContains(value),
                "\(id.rawValue) did not discover expected live content ‘\(value)’\n\(discovery)"
            )
        }
        let draft = try await NativeItemInputRouter().ingest(
            .init(source: .url(item.url), hints: item.hints)
        )
        XCTAssertFalse(draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        XCTAssertGreaterThan(
            draft.content.trimmingCharacters(in: .whitespacesAndNewlines).count,
            20,
            "\(id.rawValue) discovered \(item.url), but item ingestion returned no real content"
        )
        return draft
    }

}

private func itemTestURL(_ id: ItemInputID) -> URL {
    realItemTestURLs.first { $0.0 == id }!.1
}

private func channelTestURL(_ id: ChannelInputID) -> URL {
    realChannelTestURLs.first { $0.0 == id }!.1
}

private func assertRealTestURLs(
    _ registrations: [(String, URL)],
    expectedIDs: [String],
    file: StaticString = #filePath,
    line: UInt = #line
) {
    XCTAssertEqual(
        registrations.map(\.0).sorted(),
        expectedIDs.sorted(),
        "Every input must have exactly one test URL",
        file: file,
        line: line
    )
    XCTAssertEqual(
        Set(registrations.map { $0.1.absoluteString }).count,
        registrations.count,
        "Test URLs must be unique within each input family",
        file: file,
        line: line
    )
    for (_, url) in registrations {
        let host = url.host?.lowercased() ?? ""
        XCTAssertEqual(url.scheme, "https", "Test URLs must use HTTPS: \(url)", file: file, line: line)
        XCTAssertNil(url.user, "Test URLs cannot contain credentials: \(url)", file: file, line: line)
        XCTAssertNil(url.password, "Test URLs cannot contain credentials: \(url)", file: file, line: line)
        XCTAssertTrue(host.contains("."), "Test URLs need a public host: \(url)", file: file, line: line)
        XCTAssertFalse(
            host == "localhost" || host.hasSuffix(".test") || host.hasSuffix(".invalid"),
            "Placeholder test URL is forbidden: \(url)",
            file: file,
            line: line
        )
    }
}

private struct Fixture: Sendable {
    let data: Data
    let contentType: String

    static func text(_ value: String, _ contentType: String = "text/html") -> Self {
        .init(data: Data(value.utf8), contentType: contentType)
    }

    static func json(_ value: Any) -> Self {
        .init(
            data: try! JSONSerialization.data(withJSONObject: value),
            contentType: "application/json"
        )
    }
}

private enum FixtureError: Error { case missing(String) }

private func fixtureHTTP(_ fixtures: [String: Fixture]) -> InputHTTPClient {
    InputHTTPClient { request, maximumBytes in
        let value = request.url!.absoluteString
        guard let fixture = fixtures.sorted(by: { $0.key.count > $1.key.count })
            .first(where: { value.contains($0.key) })?.value else {
            throw FixtureError.missing(value)
        }
        guard fixture.data.count <= maximumBytes else { throw NativeInputError.responseTooLarge }
        return InputHTTPResponse(
            data: fixture.data,
            finalURL: request.url!,
            contentType: fixture.contentType
        )
    }
}

private func feedXML(itemURL: String = "https://example.com/") -> String {
    """
    <rss><channel><title>Native feed</title><item><guid>native-1</guid><title>Native story</title>
    <link>\(itemURL)</link><description>Native summary</description>
    <pubDate>Mon, 01 Jun 2026 10:00:00 +0000</pubDate></item></channel></rss>
    """
}

private func fixturePDF(text: String, title: String) -> Data {
    let stream = "BT /F1 18 Tf 72 720 Td (\(text)) Tj ET"
    let objects = [
        "<< /Type /Catalog /Pages 2 0 R >>",
        "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>",
        "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
        "<< /Length \(stream.utf8.count) >>\nstream\n\(stream)\nendstream",
        "<< /Title (\(title)) >>"
    ]
    var pdf = "%PDF-1.4\n"
    var offsets = [0]
    for (index, object) in objects.enumerated() {
        offsets.append(pdf.utf8.count)
        pdf += "\(index + 1) 0 obj\n\(object)\nendobj\n"
    }
    let xref = pdf.utf8.count
    pdf += "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
    pdf += offsets.dropFirst().map { String(format: "%010d 00000 n \n", $0) }.joined()
    pdf += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R /Info 6 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
    return Data(pdf.utf8)
}
