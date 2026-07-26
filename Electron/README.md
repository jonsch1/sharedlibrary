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
- Google sign-in configures one personal Drive location per account. Folder-structured
  Markdown and content-addressed audio are mirrored locally on every client.
- Clipboard URLs use the bundled extractor, then the local Codex CLI creates four
  summaries and assigns a topic in the background. The app shows persistent ingest
  status and mirrors active work on the dock/taskbar progress indicator; macOS also
  shows the number of active ingests as a dock badge.
- A bearer-authenticated agent API on `127.0.0.1` supports explicit topic creation,
  approved batch URL ingestion, job polling, and summary retrieval. Its bundled
  deep-research and input-extension skills are installed into the selected workspace
  automatically.
- Versioned workspace input packages in `.briefly/inputs/` can override extraction
  for narrowly matched sites. They are hot-discovered and execute in restricted,
  secret-free child processes with optional built-in fallback.
- Managed Briefly AI voice offers Low (Kokoro), Medium (Orpheus), and High
  (Grok Voice) quality using prepaid account credit. The first MP3 segment plays as
  provider bytes arrive while later segments are generated, cached locally, and
  backed up to Drive.
- Share links publish all text levels and already-generated narration through the
  same D1/R2 sharing service as the web reader.

Google and managed narration credentials remain in the hosted account service; the
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

Build an unpacked application for the current platform:

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
