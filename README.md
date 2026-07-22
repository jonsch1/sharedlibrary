# Shared Library

Shared Library is a native macOS menu bar app for capturing, processing, browsing, editing, and synchronizing a local source library.

The default workspace is `~/Documents/Shared Library`. The workspace itself is the Git repository; there is no nested or separate shared folder.

- `library/` stores capture records and companion summaries.
- `topics.md` stores the capture taxonomy.
- `AGENTS.md` contains workspace instructions for agents.

## Build, test, and install

```bash
swift test
./Scripts/make_app.sh release
open "./Shared Library.app"
```

For development:

```bash
swift run SharedLibrary
```

Install or update the app in `/Applications`:

```bash
./Scripts/install.sh release
```

## Capture library

Use `Command-G` to capture a clipboard URL or text. New captures are extracted and processed in the background: Codex generates brief, concise, detailed, and comprehensive summaries and assigns one existing topic or creates a new topic.

Captures open at the shortest summary by default. The footer slider moves through all four editable summary variants and the original source. **Reorganize** regenerates every variant and re-evaluates the topic using the current processing prompt. The Agent button launches the configured workspace command; by default it opens the workspace in ChatGPT.

## GitHub synchronization

The Sync tab in Settings reports:

- whether `git` and GitHub CLI (`gh`) are installed;
- whether GitHub CLI is authenticated;
- whether the workspace is a Git repository;
- the current branch and `origin` remote.

Use **Initialize Repository** to run Git initialization in the normal workspace. If no remote is connected, **Create Repository** can create a private or public GitHub repository, add it as `origin`, and push the current branch. You can instead connect an existing repository by entering `owner/repository`, an HTTPS URL, or an SSH remote. Shared Library uses the existing GitHub CLI login and configures Git's credential helper through `gh auth setup-git`.

**Sync Now** performs one serialized synchronization:

1. Stage and commit workspace changes locally.
2. Fetch `origin`.
3. Rebase the current branch on its remote branch when one exists.
4. Push the current branch and set its upstream.
5. Refresh the library after synchronization.

Automatic synchronization is debounced and requested only after meaningful operations, including completing capture processing, editing or deleting a capture, reorganizing content, and saving workspace agent instructions. It is not triggered for every low-level filesystem write. Rebase conflicts and authentication failures are surfaced in the sync status and must be resolved before retrying.

## Hotkeys

| Hotkey | Action |
| --- | --- |
| `Option-Shift-Space` | Toggle Shared Library |
| `Command-G` | Capture clipboard URL or text into `library/` |

## Architecture

| Slice | Files |
| --- | --- |
| App shell | `Sources/SharedLibrary/App/` |
| Capture extraction/library | `Sources/SharedLibrary/` |
| Git/GitHub sync | `Sources/SharedLibrary/Sync/` |
| Settings/support | `Sources/SharedLibrary/Settings/`, `Sources/SharedLibrary/Support/` |
| Tests | `Tests/SharedLibraryTests/` |
