# Briefly Electron

This directory contains the cross-platform Briefly desktop application.

## Current baseline

- Normal resizable application window on macOS, Windows, and Linux.
- Reads the existing `library/`, summary folders, and `topics.md` directly.
- Search, horizontally scrolling topic badges, all conciseness levels, Markdown
  reading, editing, folder reveal, coordinated Trash, and clipboard capture.
- Secure Electron boundary: sandboxed renderer, context isolation, no renderer
  Node.js access, and a narrow preload API keyed by library entry IDs.
- Configurable system-wide clipboard capture shortcut (default:
  `CommandOrControl-G`).
- Apple or Google signs in to the Briefly account; iCloud or Google Drive is chosen
  separately on the hosted account page for folder-structured Markdown and
  voice-brief-definition sync.
- Clipboard URLs use the bundled extractor, then the local Codex CLI creates four
  summaries and assigns a topic in the background. The app shows persistent ingest
  status and mirrors active work on the dock/taskbar progress indicator; macOS also
  shows the number of active ingests as a dock badge.
- A bearer-authenticated agent API on `127.0.0.1` supports research ingestion and
  agent-created voice briefs. Its bundled skills are installed into the selected
  workspace automatically.
- Versioned workspace input packages in `.briefly/inputs/` can override extraction
  for narrowly matched sites. They are hot-discovered and execute in restricted,
  secret-free child processes with optional built-in fallback.
- Voice briefs are plain Markdown files in `voice-briefs/`. Briefly can watch public feeds
  itself, while the bundled voice-brief skill lets Codex discover signed-in
  Reddit/X updates, avoid used sources, submit a linked script, and leave TTS and
  playback to Briefly.
- Share links publish summaries and source metadata, never captured source text
  or narration, through the same D1 sharing service as the web reader.

Google credentials remain in the hosted account service; CloudKit access stays
in an authenticated Apple web context. Account and sync settings open in an
Electron-hosted `/account` window so its per-device CloudKit authorization is
available to desktop sync. The
sandboxed renderer and local workspace never receive OAuth refresh tokens or API
keys.

## Development

```bash
npm install
npm test
npm run typecheck
npm run dev
```

Run the cross-platform Electron smoke test. This builds the production bundles,
launches Electron against an isolated temporary library, and verifies rendering
and preload/IPC reads and writes:

```bash
npm run test:e2e
```

Build an unpacked, unsigned application for local testing:

```bash
npm run package
```

GitHub Actions runs the unit and smoke tests on native macOS, Windows, and Linux
runners. Linux runs Electron under Xvfb. Pushes to `main`, version tags, and
manual workflow runs also verify that an unpacked app can be packaged on each
platform.

## Desktop releases

Update `version` in `package.json` and `package-lock.json`, then push the matching
`v*` tag. The desktop release workflow signs each native build and publishes the
installers, blockmaps, and update metadata to `jonsch1/briefly-downloads`.

The workflow requires `BRIEFLY_DOWNLOADS_TOKEN`, `MAC_CSC_LINK`,
`MAC_CSC_KEY_PASSWORD`, `APPLE_ID`, `APPLE_APP_SPECIFIC_PASSWORD`,
`APPLE_TEAM_ID`, `WIN_CSC_LINK`, and `WIN_CSC_KEY_PASSWORD` repository secrets.
The downloads token needs release write access only to `briefly-downloads`.
It also uploads an unsigned `store-windows` AppX artifact for Partner Center;
Microsoft signs that package after Store certification.
