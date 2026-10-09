# Briefly for Apple platforms

Native SwiftUI clients for macOS and iOS. These are the primary Briefly apps;
`packages/web/` provides public sharing and the hosted backend.

## Code organization

The Apple package contains both native apps and their shared code:

- `App/Shared`: shared SwiftUI features, models, app composition, and resources.
- `App/macOS`: desktop navigation, capture, menu bar, shortcuts, and entitlements.
- `App/iOS`: mobile views, native editor, app configuration, and share extension.
- `Sources/BrieflyCore`: reusable Swift domain, SQLite storage, capture, sync,
  processing, and agent IPC.
- `Sources/BrieflyMigrate`: the Markdown-library migration executable.
- `Tests`: Swift library boundary tests; `BrieflyUITests`: app journeys.
- `AppStore` and `scripts`: release materials and development/release commands.

`Briefly.xcodeproj` has one multiplatform app target compiling the shared and
platform UI sources. The macOS app embeds the signed MCP helper from the sibling
`mcp` package; the iPhone app embeds its share extension. The standalone MCP
Swift package depends on this package's `BrieflyCore` library.

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
  macOS OpenRouter browser sign-in or user-supplied API keys, and share links.
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
macOS users can sign in with OpenRouter or enter their own API key; AI usage is
charged to their OpenRouter account. iOS captures and stores items without summaries.

OpenRouter sign-in uses PKCE (S256) in the default browser. A temporary listener
binds only to `127.0.0.1` on a random port, with a random callback path for each
attempt. Briefly exchanges the authorization code directly with OpenRouter and
stores the resulting key in the Mac Keychain. Canceling or completing the attempt
closes the listener. Disconnect removes the local key; users can revoke it in
OpenRouter settings. The Mac's network-server entitlement permits this callback
while keeping App Sandbox enabled.

AI settings link to OpenRouter’s model catalog and accept a `provider/model-id`.
Briefly validates the ID through OpenRouter’s single-model endpoint and fetches
that model’s supported reasoning efforts, defaults, and base token prices. Model
details are cached for six hours and can be refreshed manually. Models must accept
text and support structured outputs. Switching models resets effort to the model
default; choosing an effort saves it immediately. Summary processing and connection
tests both use these choices, with provider routing limited to endpoints that
support the requested parameters.

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

Live input tests are skipped unless `BRIEFLY_RUN_LIVE_TESTS=1` is set. They ingest the registered
public URL for every item input, then enumerate every channel and ingest one
of its discovered items. The filtered command runs only those live journeys.
The iOS check requires the iOS Simulator platform installed in Xcode.

## Platform-specific limits

- macOS summaries use the user's OpenRouter account. iOS reads synced content
  and can queue original items for Mac processing.
- Scheduled channel checks run on the Mac at launch and while the app remains active.
- The native clients can generate local speech for ordinary library documents.

## Capture and processing responsibilities

- iPhone/iPad primarily consume the library prepared on the Mac. Optionally, they
  and the Share Extension save original URLs, text, and PDFs to its queue. They never
  extract pages, enumerate channels, run custom adapters, or generate summaries.
  `SharedCaptureInbox` is the extension-to-app outbox; opening the app transfers its
  contents into SQLite with `queueCapture`, then syncs through iCloud.
- A pending capture is a real document with a stable capture ID and a typed
  `CaptureRequest` in its existing CloudKit payload. Original PDFs are attachments.
  Saving the document, original file, and upload intents is one transaction. An
  interrupted extension import can safely repeat without making another item.
- The Mac owns `LibraryInputService`, a headless page renderer, custom source handlers,
  and `LibraryProcessingModel`. After sync it resumes pending captures, writes the
  extracted source to the same document, and runs the local summary queue. Native
  extraction adapters and AI execution are excluded from iOS compilation.
- Pending UI shows waiting to sync, waiting for Mac, extraction, summarization, or
  a retained failure. Retry preserves the original; removal uses the normal trash.
  Documents arriving before their PDF attachments wait for a subsequent sync.
  Completed documents leave the inbox and appear in the reader.
- Both devices need the same iCloud Apple Account. Briefly account sign-in is
  separate. The Mac must be awake with Briefly running; periodic sync also checks
  for captures while the app stays open. This is eventual processing, not a promise
  of an immediate background handoff from the iOS Share Extension.
- The queue guarantees a stable item identity and resumable stages, not exactly-once
  execution across multiple Macs. Two Macs can repeat extraction or model work before
  observing each other's changes; only one Mac should act as the processing host.

The capture dialog has two inputs on both platforms: Files (PDF, plain text, or
Markdown, via drop or picker) and Text or link (initially the current clipboard).
There is no in-app browser UI. The Mac may render a page in a hidden WebKit view as
part of extraction. Text files are read as UTF-8 or BOM-marked UTF-16 and sent through
the same plain-text capture boundary; reading a file on iOS never invokes an extractor.

## Library export

Library settings offer SQLite and Markdown exports on both platforms. SQLite uses
SQLite's online backup API to create a self-contained snapshot, including WAL writes,
attachments, and all persisted state. Markdown exports source and summary files per
item, original queued input, attachments, and JSON metadata for every library table
(except derived search indexes). Deleted items are under Trash. Stable ID hashes keep
folder names unique and titles cannot create paths outside the export.

Export snapshots include what is stored on the current device. Sync first to receive
changes and attachments from other devices. Exports never replace an existing file;
failed copies are cleaned up before publishing the destination. The Mac asks for a
folder; iOS uses the system document exporter to save either the database or folder.

## Trash and helper packaging

Trash offers permanent deletion per item and Empty Trash, with confirmation on both
platforms. Permanent deletion clears content, attachments, and pending processing jobs.
A content-free document tombstone remains for synchronization so an offline edit cannot
restore a purged item. Attachment removals are sent as CloudKit record deletions.

The MCP executable lives in `Contents/Helpers/BrieflyMCP.app/Contents/MacOS/briefly-mcp`.
Its own app bundle gives the sandbox a distinct identity and container while retaining
the existing app-group entitlement for authenticated IPC. Putting a separately signed,
sandboxed tool directly in the main app's MacOS directory caused macOS to compare the
helper's identity against the main app's private container and show an unnamed consent
prompt. The SDK and plugin select the most recently launched Briefly installation.
