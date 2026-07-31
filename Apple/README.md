# Briefly for Apple platforms

Native SwiftUI clients for macOS and iOS. `Electron/`, `Web/`, and `Shared/`
remain intact as the compatibility and product reference during the port.

## Current capabilities

- Native library, channel, and voice-brief navigation with a collapsible macOS
  sidebar and full-height titlebar layout.
- Existing Markdown workspace format: capture text, authenticated web pages,
  PDFs, edit every text depth, regenerate summaries, recoverable trash, topics,
  channels, voice-brief definitions, generated scripts, audio, and favicons.
- RSS/Atom, podcasts, Reddit, Hacker News, arXiv, ordinary pages, and
  authenticated X capture. Visible and hidden `WKWebView` instances share one
  persistent cookie store. External Safari/default-browser links are for
  viewing only; authenticated extraction stays in-app so the session remains
  available to Briefly.
- Briefly account sessions, managed AI, personal context, editable processing
  and voice-brief prompts, custom macOS AI/agent commands, and share links.
- Native audio generation and playback with resume position, seeking, speed,
  and volume.
- Safe three-way CloudKit synchronization of Markdown plus audio/favicon media,
  with conflict copies and recoverable sync trash.
- Configurable system-wide macOS clipboard capture, native File-menu actions,
  drag-and-drop capture, light/dark/system appearance, and security-scoped
  workspace persistence.

## Open and run

Open `Briefly.xcodeproj`, select the `Briefly` scheme, and choose My Mac or an
iPhone simulator.

To connect the private CloudKit library:

1. Select the `Briefly` target, then **Signing & Capabilities**.
2. Select the development team.
3. Add **iCloud**, enable **CloudKit**, and select the container used by the web
   app's `CLOUDKIT_CONTAINER_ID`.
4. Set `BRIEFLY_CLOUDKIT_CONTAINER_IDENTIFIER` to that container identifier.
5. Run while signed into an iCloud account that has a Briefly library.

The app uses the private `Briefly` zone, `library-index` record, and the same
content-addressed file/media records as the existing clients. Without an
explicit container, local/sample use remains available and Sync reports the
configuration error.

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
- The native clients retain generated voice-brief audio. Electron's optional
  permanent download of manually captured YouTube audio still depends on its
  bundled extractor and is not available on iOS.
