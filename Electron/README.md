# Shared Library Electron

This directory contains the cross-platform Shared Library desktop application.

## Current baseline

- Normal resizable application window on macOS, Windows, and Linux.
- Reads the existing `library/`, summary folders, and `topics.md` directly.
- Search, horizontally scrolling topic badges, all conciseness levels, Markdown
  reading, editing, folder reveal, coordinated Trash, and clipboard capture.
- Secure Electron boundary: sandboxed renderer, context isolation, no renderer
  Node.js access, and a narrow preload API keyed by library entry IDs.
- `CommandOrControl-G` capture shortcut.
- Google sign-in configures one personal Drive location per account. Folder-structured
  Markdown and content-addressed audio are mirrored locally on every client.
- Clipboard URLs use the bundled extractor, then the local Codex CLI creates four
  summaries and assigns a topic in the background.
- A bearer-authenticated agent API on `127.0.0.1` supports explicit topic creation,
  approved batch URL ingestion, job polling, and summary retrieval. Its bundled
  deep-research skill is installed into the selected workspace automatically.
- OpenRouter OAuth narration uses incremental MP3 segments: the first segment plays
  while later segments are generated, cached locally, and backed up to Drive.
- Share links publish all text levels and already-generated narration through the
  same D1/R2 sharing service as the web reader.

Google and OpenRouter credentials remain in the hosted account service; the
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
