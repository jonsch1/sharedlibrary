# Briefly link inputs

The extractor is an owned, ordered input pipeline. `inputs/registry.mjs` routes
each HTTP(S) URL to the first matching specialized module and uses
`generic-html.mjs` for ordinary web pages.

Before built-in routing, `extension-contract.mjs` discovers versioned workspace
packages from `<workspace>/.briefly/inputs/`. Declarative manifests perform URL
matching without executing extension code. The selected module runs through
`extension-runner.mjs` in a restricted subprocess, and can fall back to built-ins.

Supported specialized inputs:

- `youtube.mjs` reads video metadata and published caption tracks. It never
  downloads video or audio. Videos without an available transcript still
  produce a result containing the title, channel, description, and a clear
  transcript-unavailable notice.
- `x.mjs` reads X posts and Articles through the public FXTwitter response.
- `bluesky.mjs` reads public Bluesky posts through the AT Protocol API.

The generic HTML input fetches text documents directly, extracts metadata and
JSON-LD, and uses Mozilla Readability with a sanitized DOM-text fallback.
Binary documents and media are intentionally rejected.

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
