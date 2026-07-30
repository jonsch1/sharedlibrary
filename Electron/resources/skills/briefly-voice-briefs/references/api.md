# Briefly voice brief API

The running desktop app writes its authenticated loopback connection to
`.shared-library/agent-api.json`. Never print its bearer token.

## `GET /v1/voice-briefs`

Lists voice-brief definitions, episodes, `usedSourceURLs`, and canonical
`usedItemKeys`. Use the item keys to exclude posts already used by that
voice-brief.

## `POST /v1/extract`

Extracts a known item URL through Briefly without adding it to the library.

```json
{"url": "https://x.com/example/status/123"}
```

The returned `item` contains `itemKey`, `url`, `title`, `content`, and an
optional `mediaURL`.

## `POST /v1/voice-briefs/:voiceBriefID/episodes`

Creates an episode from an agent-written Markdown script and one or more sources.
Each source requires `url`; `title` and `content` are optional. Omit `content`
to let Briefly extract the URL. Supply it only when it came from Briefly's
extract endpoint or a necessary signed-in browser capture.

```json
{
  "script": "# Episode title\n\nSpoken script.",
  "sources": [
    {
      "url": "https://example.com/item",
      "title": "Example item",
      "content": "Extracted source content."
    }
  ]
}
```

Briefly returns `201` for a new episode and `200` when the same canonical source
set already has an episode. `audioPending` means the script is safely stored
and text-to-speech is continuing in the background.

Errors use `{ "error": { "code": "...", "message": "..." } }`. Treat `401` as
a stale connection and restart Briefly. A sandbox may require narrowly scoped
localhost permission for the CLI.
