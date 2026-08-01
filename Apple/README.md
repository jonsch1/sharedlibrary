# Briefly for Apple platforms

Native SwiftUI clients for macOS and iOS. These are the primary Briefly apps;
`Web/` provides public sharing and the hosted backend.

## Current capabilities

- Native library, channel, and voice-brief navigation with a collapsible macOS
  sidebar and full-height titlebar layout.
- SQLite-canonical local library with typed document, topic, channel,
  voice-brief, and attachment records; FTS5 search; revision-checked writes;
  and attachments stored in SQLite.
- RSS/Atom, podcasts, Reddit, Hacker News, arXiv, ordinary pages, and
  authenticated X capture. Visible and hidden `WKWebView` instances share one
  persistent cookie store. External Safari/default-browser links are for
  viewing only; authenticated extraction stays in-app so the session remains
  available to Briefly.
- Briefly account sessions, managed AI, personal context, editable processing
  and voice-brief prompts, custom macOS AI/agent commands, and share links.
- Native audio generation and playback with resume position, seeking, speed,
  and volume.
- Local-first CKSyncEngine synchronization of logical records and attachments;
  the SQLite database file is never synchronized.
- Configurable system-wide macOS clipboard capture, native File-menu actions,
  drag-and-drop capture, light/dark/system appearance, and app-local SQLite
  persistence.

## Open and run

Open `Briefly.xcodeproj`, select the `Briefly` scheme, and choose My Mac or an
iPhone simulator.

To connect the private CloudKit library:

1. Select the `Briefly` target, then **Signing & Capabilities**.
2. Select the development team.
3. Add **iCloud**, enable **CloudKit**, and select the container used by the web
   app's `CLOUDKIT_CONTAINER_ID`.
4. Confirm `BRIEFLY_CLOUDKIT_CONTAINER_IDENTIFIER` is `iCloud.fyi.readbriefly`.
5. Run while signed into an iCloud account that has a Briefly library.

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

xcodebuild -project Briefly.xcodeproj -scheme Briefly \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build

xcodebuild -project Briefly.xcodeproj -scheme Briefly \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

The iOS check requires the iOS Simulator platform installed in Xcode.

## Platform-specific limits

- Local command-line processing and custom terminal agents are macOS-only; iOS
  uses Briefly AI.
- Scheduled briefs run at launch, while active, and while the app remains
  running. Reliable background iOS execution still needs an App Refresh task.
- The native clients retain generated voice-brief audio. Permanent download of
  manually captured YouTube audio is not available on iOS.
