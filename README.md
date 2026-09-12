# Briefly

Briefly is a native SwiftUI app for macOS and iOS. It captures articles, videos,
podcasts, PDFs, and notes into a local SQLite library; creates several reading
depths; follows sources; and produces scheduled text and voice briefs.

The Apple apps are the product. The website provides public capability-link
readers plus supporting marketing, legal, and Cloudflare Worker surfaces. It
does not expose a private library, account manager, or checkout.

## Repository

| Slice | Location |
| --- | --- |
| macOS and iOS apps | `Apple/` |
| Public sharing and hosted backend | `Web/` |
| Shared web rendering primitives | `Shared/` |
| Native capture and channel inputs | `Apple/Sources/BrieflyCore/Inputs/` |
| External TypeScript capture SDK | [`SDK/TypeScript/`](SDK/TypeScript/README.md) |

## Build and test

Apple:

```bash
cd Apple
swift test
xcodebuild -project Briefly.xcodeproj -scheme Briefly \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
xcodebuild -project Briefly.xcodeproj -scheme Briefly \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

Web and shared rendering:

```bash
cd Shared && npm install && npm test
cd ../Web && npm install && npm test
```

Native item capture and channel enumeration are owned by the Swift routers in
`Apple/Sources/BrieflyCore/Inputs/`. Browser rendering, Firecrawl fallback, and
media transcription are injected Swift services; the web application remains
limited to public share, feedback, legal, marketing, administration, and native
backend support.

The iOS build requires the matching Xcode Simulator platform component.

## Storage and synchronization

The native apps keep the canonical library in an app-local SQLite database.
Logical records and attachments synchronize through the user's private CloudKit
database; the SQLite file itself is never synchronized.

The one-time `briefly-migrate` tool can import the former Markdown workspace
without changing it:

```bash
cd Apple
swift run briefly-migrate '/path/to/Shared Library'
```

## Public sharing

Publishing a document uploads only the selected summaries and metadata to the
sharing service. The stable 192-bit capability link is intentionally
forwardable and impractical to guess. Recipients do not need an account.

The public reader includes the available summary depths and original source
link. It never publishes the captured original text or its narration. Revoking
a link deletes its active share records.

## Hosted services

`Web/worker/index.js` provides native Apple authentication, managed processing,
share publishing, and content reports. D1 stores account, service-access, usage,
and text-share state. See `Web/README.md` for local development and deployment
configuration.
