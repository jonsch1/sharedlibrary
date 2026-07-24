# Shared Library Electron

This directory contains the cross-platform desktop rewrite. The Swift app remains
available in `Desktop/` until the Electron client reaches feature parity.

## Current baseline

- Normal resizable application window on macOS, Windows, and Linux.
- Reads the existing `library/`, summary folders, and `topics.md` directly.
- Search, horizontally scrolling topic badges, all conciseness levels, Markdown
  reading, editing, folder reveal, coordinated Trash, and clipboard capture.
- Secure Electron boundary: sandboxed renderer, context isolation, no renderer
  Node.js access, and a narrow preload API keyed by library entry IDs.
- `CommandOrControl-G` capture shortcut.

Extraction, Codex processing, Google Drive, narration, share links, and production
signing/updating are the next porting phases.

## Development

```bash
npm install
npm test
npm run typecheck
npm run dev
```

Build an unpacked application for the current platform:

```bash
npm run package
```
