# Capture Capabilities Audit

## Native ownership note

The previous JavaScript command-line implementation is retired. As of 5 August
2026, Swift is the sole item and channel capture implementation. The focused
native boundary suite in `Apple/Tests/BrieflyCoreTests/NativeInputTests.swift`
is the executable parity check; live-source cases remain opt-in because public
sites and credentials change.

| Source family | Native Swift disposition |
|---|---|
| arXiv | `ingestArxiv` converts public paper URLs through Markxiv; arXiv query channels use the export API. |
| Bluesky | `ingestBluesky` resolves handles and reads public post threads through XRPC. |
| Feed | `FeedParser`, `PageChannel`, and `FeedChannel` cover RSS, Atom, discovered feeds, and page fallback. |
| Firecrawl | `ItemInputContext.firecrawl` is a native fallback hook; verification and error shells are rejected. |
| Generic HTML | `WebPageItem` and `Metadata` provide readable text, structured metadata, binary guards, and rendered-page fallback. |
| HTTP | `InputHTTPClient` owns HTTP(S) validation, redirects, status handling, byte limits, headers, and credential rejection. |
| PDF | `PDFItem` handles local and remote text-layer PDFs; remote failures can use the native Firecrawl hook. |
| Podcast | `PodcastItem` and `PodcastSupport` discover feeds, select episodes, parse published transcripts, and request transcription when needed. |
| Reddit | `RedditItem` reads JSON listings, linked content, RSS/embed fallbacks, comments, and oEmbed metadata. |
| Routing | `NativeItemInputRouter` dispatches URL, file, and text capture; `NativeChannelInputRouter` dispatches channel enumeration and page/feed fallback. |
| Threads | `ThreadsItem` reads public metadata and falls back through the native page path. |
| TikTok | `TikTokItem` reads oEmbed metadata and falls back through the native page path. |
| Transcription | The Swift backend hook supplies authenticated media transcription and direct-media retry behavior for YouTube and podcasts. |
| X | `XItem` reads posts and long-form articles; `XChannel` uses public HTML or the signed-in browser session. |
| YouTube | `YouTubeItem` reads player/page metadata, refreshes caption tracks, selects manual captions, and falls back to native transcription. |
| Channel watch routing | The native channel path covers feed, YouTube, podcast, Reddit, X, arXiv, Hacker News, ordinary pages, and content-hash page changes. |

Workspace input packages, an extension subprocess, and a Node runtime are not
part of the native ownership boundary. They were execution mechanisms of the
retired implementation, not source behavior to recreate in Swift.

Direct audio, image, video, archive, EPUB, and other unsupported binary URLs
remain intentional boundaries unless a dedicated native adapter is added.
