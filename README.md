# Briefly

Briefly is a native SwiftUI app for macOS and iOS. It captures articles, videos,
podcasts, PDFs, and notes into a local SQLite library; creates several reading
depths; follows sources; and produces scheduled text and voice briefs.

The Apple apps are the product. The website provides public capability-link
readers plus supporting marketing, legal, and Cloudflare Worker surfaces. It
does not expose a private library, account manager, or checkout.

## Packages

| Package | Responsibility |
| --- | --- |
| [`apple`](packages/apple/README.md) | Mac and iPhone/iPad apps, shared Swift library, migration CLI, Xcode project, and release tooling |
| [`mcp`](packages/mcp/README.md) | Swift MCP executable and distributable agent plugin |
| [`web`](packages/web/README.md) | Public website, Cloudflare Worker, and shared reader components |
| [`sdk`](packages/sdk/README.md) | Public `@readbriefly/sdk` TypeScript capture SDK |

Architecture and product documents live in [`docs/`](docs/); brand originals live
in [`assets/brand/`](assets/brand/). The hosted speech scripts live in
[`tools/kokoro/`](tools/kokoro/) and [`tools/whisper/`](tools/whisper/).

The JavaScript packages use npm workspaces and one root lockfile. Swift uses
local package dependencies: MCP depends on the `BrieflyCore` library exported by
`apple`, while the core has no dependency on MCP. Inside `apple`, `App/Shared/`
owns shared SwiftUI code and resources, `App/macOS/` and `App/iOS/` own platform
code, and `Sources/BrieflyCore/` owns the shared domain and storage layer. The
Xcode project assembles those folders into both apps. The web app and Worker
reuse reader components and contracts from `web/src/lib/reader/`.

## Development

Use Node.js 24 or newer and Xcode with Swift 6.2 or newer. Install JavaScript
dependencies once at the repository root:

```bash
npm ci
cp packages/web/.env.example packages/web/.env
npm run dev
```

Run checks from the repository root:

```bash
npm run test:web     # Reader tests, Svelte checks, Worker journeys, web build
npm run test:sdk     # Build real MCP helper, check SDK, run capture journeys
npm run test:apple   # Shared native boundary tests
npm test            # All of the above; requires macOS and Xcode
npm run build       # Web and distributable SDK
npm run build:migrate
```

Package-specific npm commands use `npm run <command> --workspace @readbriefly/<name>`.
Do not create nested lockfiles or run separate dependency installations.

Rebuild and reopen the signed native apps using repo-local derived data:

```bash
npm run app:mac
npm run app:iphone  # Requires an installed iOS platform and a booted simulator
npm run app:all
```

Open `packages/apple/Briefly.xcodeproj` for Xcode development. Native item capture
and channel enumeration are owned by `packages/apple/Sources/BrieflyCore/Inputs/`.
Browser rendering, Firecrawl fallback, and media transcription are injected Swift
services. See [`packages/apple/README.md`](packages/apple/README.md) for native details.

## Storage and synchronization

The native apps keep the canonical library in an app-local SQLite database.
Logical records and attachments synchronize through the user's private CloudKit
database; the SQLite file itself is never synchronized.

The one-time migration CLI can import a former Markdown workspace without
changing it:

```bash
swift run --package-path packages/apple briefly-migrate '/path/to/Shared Library'
```

## Public sharing and hosted services

Publishing a document uploads only the selected summaries and metadata to the
sharing service. The stable 192-bit capability link is intentionally forwardable
and impractical to guess. Recipients do not need an account. The reader includes
the available summary depths and source link, and never publishes the captured
original text or its narration. Revoking a link deletes its active share records.

`packages/web/worker/index.js` provides native Apple authentication, managed
processing, share publishing, and content reports. D1 stores account,
service-access, usage, and text-share state. See [`packages/web/README.md`](packages/web/README.md)
for local development and deployment configuration.
