# Briefly

Briefly is a cross-platform Electron desktop app for capturing, processing,
browsing, editing, and listening to a local text library. A Svelte web reader
provides mobile access, narration, offline caching, and deliberate public share
links. iCloud or Google Drive stores the private library; the sharing service
stores only documents the user explicitly publishes.

The desktop app supports macOS, Windows, and Linux. It opens the workspace directly
and includes capture extraction, Codex processing, iCloud or Google Drive synchronization,
OpenRouter narration, share links, editing, and coordinated Trash.

The default workspace is `~/Documents/Briefly`.

- `library/` stores sources and their brief, concise, detailed, and comprehensive
  summaries.
- `topics.md` stores the capture taxonomy.
- `AGENTS.md` contains workspace instructions for agents.
- `.briefly/inputs/` contains optional workspace-local link input extensions.
- `.shared-library/index.json` is a lightweight, rebuildable catalog of the mirrored
  Drive files. It contains metadata and hashes, not document bodies.

There is no `output/` folder and source images are not ingested or stored.

## Build and test

Build and package the desktop app:

```bash
cd Electron
npm install
npm test
npm run typecheck
npm run package
```

Build the web reader:

```bash
cd Web
npm install
npm run check
npm run test:worker
npm run build
```

For desktop development, run `npm run dev` from `Electron/`.

## Capture library

Use `Command-G` to capture a clipboard URL or text. New captures are extracted and
processed in the background. The footer slider moves through every editable summary
and the original source. **Reorganize** regenerates summaries and re-evaluates the
topic. Moving a content item to Trash moves the source and every companion summary
together.

## Agent research API

While the desktop app is running it exposes an authenticated, loopback-only API for
deep-research agents. The app installs the `briefly-deep-research` skill into
the selected workspace at `.agents/skills/` and writes the ephemeral connection to
`.shared-library/agent-api.json`. Neither file is included in the Drive mirror.

The skill makes the approval boundary explicit: the agent first proposes an exact URL
list, waits for the user to approve it, then creates or reuses a topic and submits the
approved URLs. The app extracts each page, adds it under that exact topic, creates all
four summary depths in the background, and exposes job status and summary retrieval
to the agent. Failed or replacement sources require a new approval cycle.

The API includes topic listing/creation, approved batch URL ingestion, asynchronous
job polling, and topic-item reads at any summary depth. Requests use a per-launch
bearer token from the connection file and are accepted only on `127.0.0.1`.

## Workspace input extensions

Briefly discovers versioned input packages under `.briefly/inputs/` on every
capture. A package declares its host and path matching in `input.json` and
implements extraction in `input.mjs`. Matching workspace inputs run before
built-ins and can fall back to the built-in pipeline while being developed.

Extension code runs in a separate restricted process with a scrubbed environment,
no filesystem writes, no child processes, and read access limited to its package
and the bundled input runtime. The app installs the `briefly-input-extension`
agent skill into `.agents/skills/`; users can ask an agent to add support for a
site and receive a fixture-tested local input without restarting Briefly.

Workspace inputs are local configuration and are not included in the Google Drive
library mirror.

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

## Cloud synchronization

Every desktop client is an editing source. Account sign-in (Apple or Google) is
separate from library storage (iCloud or Google Drive). After meaningful
changes—captures, edits, processing, deletions, launch, wake, or restored
connectivity—it mirrors `library/` and `topics.md` through the selected provider.
Files are compared by SHA-256 hash, so unchanged files are not uploaded.

The web reader checks the selected provider when it opens, every few minutes while running, when it
regains focus, and when it returns online. It downloads every changed Markdown file
before activating the new index, keeps the folder paths and content hashes in
IndexedDB, and removes stale local copies after a successful sync. The previous
complete mirror opens immediately while the next sync runs in the background.

Generated narration is content-addressed by its model, voice, and text hash. It is
cached locally on every connected client and backed up through the selected sync
provider. Google Drive uses the visible `Briefly/audio/` folder and reuses legacy
folders. iCloud uses asset-backed records in the user's private CloudKit database.

Apple and Google sign-in establish the Briefly account without requesting storage
access. Google sign-in requests `openid email`; connecting Drive later requests only
the narrow `drive.file` scope. Sign in with Apple uses the web Services ID flow.
Provider connection, selection, and removal all live on `/account`; the readers only
show the resulting status.

For the web reader, create a Google OAuth **Web application** client. Set
`GOOGLE_DRIVE_WEB_CLIENT_ID` and the `GOOGLE_DRIVE_WEB_CLIENT_SECRET` deployment
secret, then add
`https://www.readbriefly.fyi/api/google/connect/callback` to the client's
authorized redirect URIs. The Electron app uses the same hosted account
connection, so Drive is configured once per account. Account tokens are
encrypted per signed-in user.

For iCloud, configure a private CloudKit container, a web-services token restricted
to `https://www.readbriefly.fyi`, and the three record types documented in
`Web/README.md`. CloudKit JS talks directly to Apple's private database from the web
reader and an authenticated hidden web context in Electron. CloudKit authorization
is per browser/device, so Electron opens the hosted account page in its own session
when the user manages sync.

## OpenRouter narration

OpenRouter OAuth is optional. Its account-controlled API key is encrypted in the web
backend and is never placed in Google Drive or the library projection. Text is sent
to OpenRouter and xAI only when the user requests narration. Generated MP3 segments
are cached locally and uploaded automatically through the selected sync provider.

## Hotkeys

| Hotkey | Action |
| --- | --- |
| `CommandOrControl-G` | Capture clipboard URL or text into `library/` |

## Architecture

| Slice | Files |
| --- | --- |
| Cross-platform desktop app | `Electron/` |
| Desktop services and local library | `Electron/src/main/` |
| Desktop UI | `Electron/src/renderer/` |
| Capture extraction | `Tools/extractor/` |
| Cloud library and audio sync | `Electron/src/main/sync.ts`, `Web/src/lib/icloud.ts` |
| Svelte web reader and backend | `Web/` |
| Desktop tests | `Electron/src/main/*.test.ts` |
| Web worker tests | `Web/worker/index.test.mjs` |
