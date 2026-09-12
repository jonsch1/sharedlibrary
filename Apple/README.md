# Briefly for Apple platforms

Native SwiftUI clients for macOS and iOS. These are the primary Briefly apps;
`Web/` provides public sharing and the hosted backend.

## Current capabilities

- Native library and channel navigation with a collapsible macOS sidebar and
  full-height titlebar layout.
- SQLite-canonical local library with typed document, topic, channel, and
  attachment records; FTS5 search; revision-checked writes; and attachments
  stored in SQLite.
- Native item inputs for text, PDF, web pages, arXiv, bioRxiv, YouTube, podcasts,
  Reddit, X, Bluesky, Threads, and TikTok; channel inputs for RSS/Atom,
  YouTube, podcasts, Reddit, X, arXiv, Hacker News, and watched pages. Visible
  and hidden `WKWebView` instances share one
  persistent cookie store. External Safari/default-browser links are for
  viewing only; authenticated extraction stays in-app so the session remains
  available to Briefly.
- Native Sign in with Apple, personal context, an editable processing prompt,
  macOS provider commands, optional user-supplied OpenRouter processing, and
  share links.
- Startup-warmed on-device audio generation with paragraph-level progressive
  playback, local caching, resume position, seeking, speed, and volume.
- Local-first CKSyncEngine synchronization of logical records and attachments;
  the SQLite database file is never synchronized.
- Durable channel review queues keep up to 50 user-configured candidates per
  channel group. Discovery is cheap; only accepted candidates enter the library
  and start summary processing.
- Configurable system-wide macOS clipboard capture, native File-menu actions,
  drag-and-drop capture, light/dark/system appearance, and app-local SQLite
  persistence.

## Open and run

Open `Briefly.xcodeproj`, select the `Briefly` scheme, and choose My Mac or an
iPhone simulator.

To connect the private CloudKit library:

1. Select the `Briefly` target, then **Signing & Capabilities**.
2. Select the development team.
3. Add **iCloud**, enable **CloudKit**, and select the Briefly container.
4. Confirm `BRIEFLY_CLOUDKIT_CONTAINER_IDENTIFIER` is `iCloud.fyi.readbriefly`.
5. Run while signed into an iCloud account that has a Briefly library.

Also add **Sign in with Apple** if account-backed features are being tested. The
TestFlight beta is free and does not use app-funded hosted AI.
macOS users can enter their own OpenRouter API key or configure a local provider
CLI; iOS captures and stores items without summaries.

The app uses the private `BrieflyDocuments` zone. Each local transaction adds
or coalesces a logical-record outbox entry for CKSyncEngine.

For the one-time legacy Markdown import:

```bash
swift run briefly-migrate '/path/to/Shared Library'
```

The importer leaves the Markdown library untouched and creates
`.briefly/library.sqlite3` inside the supplied legacy root. The native apps
use their app-local SQLite database directly.

## Checks

```bash
swift test

BRIEFLY_RUN_LIVE_TESTS=1 swift test --filter LiveInputURLTests

xcodebuild -project Briefly.xcodeproj -scheme Briefly \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build

xcodebuild -project Briefly.xcodeproj -scheme Briefly \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

To rebuild and immediately reopen a development-signed app, use:

```bash
./scripts/rebuild-and-reopen.sh macos
./scripts/rebuild-and-reopen.sh ios
# Or rebuild and reopen both:
./scripts/rebuild-and-reopen.sh all
```

To build, install Briefly directly into `/Applications`, and launch it:

```bash
./scripts/install-to-applications.sh
```

Launched builds keep development signing enabled so capabilities such as Sign
in with Apple remain available. The iOS command requires a booted simulator.

The live input tests run as part of `swift test`. They ingest the registered
public URL for every item input, then enumerate every channel and ingest one
of its discovered items. The filtered command runs only those live journeys.
The iOS check requires the iOS Simulator platform installed in Xcode.

## Platform-specific limits

- macOS summaries use either a user-supplied OpenRouter API key or a local
  command-line provider such as Codex, Claude, or Gemini. iOS captures and
  stores items without summaries in this beta.
- Scheduled channel checks run at launch while the app remains active. Reliable
  background iOS execution still needs an App Refresh task.
- The native clients can generate local speech for ordinary library documents.
