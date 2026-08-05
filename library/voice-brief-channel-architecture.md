# Voice Brief Channel Architecture

## Purpose

An ordinary capture turns one URL, file, or text value into one library item. A
voice-brief channel watches a durable location, discovers new item references,
and sends every unseen item through that same native capture path.

Channels orchestrate captures. They do not introduce a second content pipeline.

## Schematic

```mermaid
flowchart LR
  C["Channel definition<br/>URL or query + schedule"] --> E["Enumerate item references"]
  E --> D["Compare stable IDs<br/>with channel checkpoint"]
  D -->|unseen items| H["Capture each item"]
  H --> N["Native Swift item input router"]
  N --> L["One library entry<br/>per independent item"]
  L --> R["Review gathered items<br/>titles, dates, excerpts"]
  R --> P["Select pending entries for<br/>the voice brief"]
  P --> A["Generate episode"]

  U["Visible browser"] -->|sign in only| S["Shared browser session"]
  S --> E
  S --> H
```

## Native ownership

`Apple/Sources/BrieflyCore/Inputs/` owns item routing, source adapters, HTTP
limits and validation, channel enumeration, and stable source identity. Browser
rendering, Firecrawl fallback, and media transcription are explicit Swift service
hooks supplied by the Apple application.

The shared capture result remains a title, normalized content, source URL, and
optional media. The same native item path handles ordinary pages, papers, feeds,
podcasts, documents, video, and social content.

## Channel responsibilities

- Revisit a profile, feed, listing, search, or podcast.
- Enumerate ordered item references.
- Assign and retain stable item identities.
- Compare the result with previously seen identities.
- Capture only unseen items.
- Preserve partial successes and report channel health.
- Apply a schedule and choose captured entries for an episode.

Enumeration returns references, not combined content. Five independent posts
therefore become five captures and five library files.

## Runtime boundary

The channel workflow exposes two operations:

1. **Enumerate** a channel into item references.
2. **Capture** one item through `NativeItemInputRouter`.

The voice-brief service depends only on those operations. It does not choose
between competing extraction implementations. The visible browser exists only
to establish authentication; background workflows reuse the same native WebKit
session when a rendered page is required.

Gathering and generation are separate user actions. **Check channels** updates
the pending queue and its preview; **Generate voice brief** consumes that
reviewed queue without refreshing it again.

## Current built-in policies

- Podcast page or feed: latest episode.
- YouTube channel: latest video.
- X profile: latest five unique, non-pinned posts when the source exposes them.
- Hacker News front page: top five stories.
- Ordinary feeds: every unseen item returned by the feed.
- Ordinary pages: one content-hash reference when no feed is discoverable.

New source support belongs in the native Swift item or channel adapters. The
shared capture path remains responsible for content validation, retries, media
handling, and library storage.
