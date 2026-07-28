# Briefly link inputs

The extractor is an owned, ordered input pipeline. `inputs/registry.mjs` routes
each HTTP(S) URL to the first matching specialized module and uses
`generic-html.mjs` for ordinary web pages.

Before built-in routing, `extension-contract.mjs` discovers versioned workspace
packages from `<workspace>/.briefly/inputs/`. Declarative manifests perform URL
matching without executing extension code. The selected module runs through
`extension-runner.mjs` in a restricted subprocess, and can fall back to built-ins.

Supported specialized inputs:

- PDF responses are parsed by content type or PDF signature, including download
  URLs without a `.pdf` suffix. Image-only scans report that OCR is unavailable.
- Podcast RSS feeds and episode pages with RSS autodiscovery use published
  Podcasting 2.0 transcripts in WebVTT, HTML, JSON, SRT, or plain text, then
  fall back to the authenticated Whisper service when configured.
- `youtube.mjs` reads video metadata and published caption tracks, then falls
  back to the authenticated Whisper service when configured. Without that
  service, metadata and a transcript-unavailable notice are still returned.
- `x.mjs` reads X posts and Articles through the public FXTwitter response.
- `bluesky.mjs` reads public Bluesky posts through the AT Protocol API.
- `threads.mjs` reads public Threads post preview metadata.

The generic HTML input fetches text documents directly, extracts metadata and
JSON-LD, and uses Mozilla Readability with a sanitized DOM-text fallback.
Unsupported binary formats and media are intentionally rejected.

When `FIRECRAWL_API_KEY` is configured, failed built-in extraction and obvious
verification/login shells fall back to Firecrawl's v2 single-page Markdown
scraper. Built-in and workspace inputs remain first so ordinary captures do not
consume Firecrawl credits.

## Adding an input

An input module exports an object with this shape:

```js
{
  id: "source-name",
  sourceType: "web-page",
  fallbackToGeneric: false,
  matches(url) {},
  extract(url, context) {}
}
```

Register specialized modules before the generic HTML input. Every successful
extractor returns at least `url`, `title`, and non-empty `content`; the registry
adds the extractor ID, source type, word count, and character count.

Public workspace extensions use the separately versioned v1 manifest and result
contract documented by the bundled `briefly-input-extension` skill. Built-in
handler objects remain private implementation details.
