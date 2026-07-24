# Shared Library

Shared Library is a native macOS menu bar app for capturing, processing, browsing,
editing, and listening to a local text library. A private Svelte web reader provides
mobile access, narration, offline caching, and deliberate public share links.
Google Drive is the private-library synchronization service; the sharing service
stores only documents the user explicitly publishes.

`Electron/` contains the cross-platform desktop rewrite for macOS, Windows, and
Linux. It opens the same workspace directly and now includes capture extraction,
Codex processing, Google Drive synchronization, OpenRouter narration, share links,
editing, and coordinated Trash while the native app remains available during the
migration.

The default workspace is `~/Documents/Shared Library`.

- `library/` stores sources and their brief, concise, detailed, and comprehensive
  summaries.
- `topics.md` stores the capture taxonomy.
- `AGENTS.md` contains workspace instructions for agents.
- `.shared-library/index.json` is a lightweight, rebuildable catalog of the mirrored
  Drive files. It contains metadata and hashes, not document bodies.

There is no `output/` folder and source images are not ingested or stored.

## Build, test, and install

```bash
swift test
./Scripts/install.sh release
```

For development:

```bash
swift run SharedLibrary
```

Build the web reader:

```bash
cd Web
npm install
npm run check
npm run test:worker
npm run build:sites
```

Run the cross-platform desktop client:

```bash
cd Electron
npm install
npm test
npm run typecheck
npm run dev
```

## Capture library

Use `Command-G` to capture a clipboard URL or text. New captures are extracted and
processed in the background. The footer slider moves through every editable summary
and the original source. **Reorganize** regenerates summaries and re-evaluates the
topic. Moving a content item to Trash moves the source and every companion summary
together.

## Share links

The Share button opens the web reader for the selected capture. Publishing creates
a stable, 192-bit capability link that is intentionally forwardable and impractical
to guess. The public reader includes every available conciseness level. If complete
narration segments already exist for a version, those segments are published too;
sharing never generates audio by itself.

Share metadata and Markdown live in D1, and published narration segments live in
R2. Updating a link replaces its current revision. Stopping sharing deletes its
records and media. A recipient can read without an account or sign in and choose
**Add to my library**, which creates an independent capture in their personal
Google Drive and copies published narration into their private audio mirror.

## Google Drive synchronization

Every desktop client is an editing source. After meaningful changes—captures, edits,
processing, deletions, launch, wake, or restored connectivity—it mirrors `library/`
and `topics.md` to the same folder structure in Drive. Files are compared by SHA-256
hash, so unchanged files are not uploaded. Deletions are moved to Drive Trash, and
the lightweight index is updated last.

The web reader checks Drive when it opens, every few minutes while running, when it
regains focus, and when it returns online. It downloads every changed Markdown file
before activating the new index, keeps the folder paths and content hashes in
IndexedDB, and removes stale local copies after a successful sync. The previous
complete mirror opens immediately while the next sync runs in the background.

Generated narration is content-addressed by its model, voice, and text hash. It is
cached locally on every connected client and stored under `audio/` in the visible
`Shared Library` folder in the user's own Google Drive. Existing
`Shared Library Media` folders are reused so earlier audio is not orphaned. Existing
audio is mirrored in the background and remains playable offline.

Google is the account boundary for the web and Electron clients. The first sign-in
creates or reuses one visible `Shared Library` folder and saves that folder ID for
the account; later clients discover the same location after Google sign-in. The
integration requests `openid`, `email`, and the narrow `drive.file` scope, so it can
identify the account and access only files created by Shared Library or explicitly
selected by the user—not the rest of the user's Drive.

For the macOS app, create a Google OAuth **Desktop app** client and set
`SHARED_LIBRARY_GOOGLE_DESKTOP_CLIENT_ID` when building. Authorization uses PKCE with
a temporary loopback callback; the user's refresh token is stored in Keychain.

For the web reader, create a Google OAuth **Web application** client. Set
`GOOGLE_DRIVE_WEB_CLIENT_ID` and the `GOOGLE_DRIVE_WEB_CLIENT_SECRET` deployment
secret, then add `/api/google/connect/callback` on the production origin to the
client's authorized redirect URIs. Account tokens are encrypted per signed-in user.

## OpenRouter narration

OpenRouter OAuth is optional. Its account-controlled API key is encrypted in the web
backend and is never placed in Google Drive or the library projection. Text is sent
to OpenRouter and xAI only when the user requests narration. Generated MP3 segments
are cached locally and, when Drive is connected, uploaded automatically.

## Hotkeys

| Hotkey | Action |
| --- | --- |
| `Option-Shift-Space` | Toggle Shared Library |
| `Command-G` | Capture clipboard URL or text into `library/` |

## Architecture

| Slice | Files |
| --- | --- |
| App shell | `Sources/SharedLibrary/App/` |
| Provisioned macOS bundle | `Desktop/SharedLibraryDesktop.xcodeproj` |
| Cross-platform desktop rewrite | `Electron/` |
| Capture extraction/library | `Sources/SharedLibrary/` |
| Drive mirror and lightweight index | `Sources/SharedLibrary/Cloud/`, `Sources/SharedLibrary/Web/` |
| Google Drive library and audio | `Sources/SharedLibrary/Media/` |
| Svelte web reader and backend | `Web/` |
| Settings/support | `Sources/SharedLibrary/Settings/`, `Sources/SharedLibrary/Support/` |
| Tests | `Tests/SharedLibraryTests/` |
