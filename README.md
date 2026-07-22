# Shared Library

Shared Library is a native macOS menu bar app for capturing, processing, browsing, editing, and synchronizing a local source library. It keeps GatherCapture's library workflow while removing its Notes feature.

The default workspace is `~/Documents/Shared Library`. The workspace itself is the Git repository; there is no nested or separate shared folder.

- `gather/` stores text capture records, image capture records, image assets, and companion summaries.
- `topics.md` stores the text-capture taxonomy.
- `output/` stores syntheses and other derived work.
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

Use `Command-G` to capture the clipboard as a URL, text, or image. New text captures are extracted and processed in the background: Codex generates brief, concise, detailed, and comprehensive summaries and assigns one existing topic or creates a new topic.

Clipboard images are stored separately. Codex assigns one informative name; images do not receive summaries or topics. The **Recent / Topics / Images** selector switches among the text library's newest-first and topic views and the image library's masonry gallery.

Text captures open at the shortest summary by default. The footer slider moves through all four editable summary variants and the original source. **Reorganize** regenerates every variant and re-evaluates the topic using the current processing prompt. **Output** exposes derived files without showing internal storage. The Agent button launches the configured workspace command; by default it opens the workspace in ChatGPT.

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

Automatic synchronization is debounced and requested only after meaningful operations, including completing capture processing, editing a document, creating or deleting an item, and saving workspace agent instructions. It is not triggered for every low-level filesystem write. Rebase conflicts and authentication failures are surfaced in the sync status and must be resolved before retrying.

## Hotkeys

| Hotkey | Action |
| --- | --- |
| `Option-Shift-Space` | Toggle Shared Library |
| `Command-G` | Capture clipboard URL, text, or image into `gather/` |

## Architecture

| Slice | Files |
| --- | --- |
| App shell | `Sources/SharedLibrary/App/` |
| Capture extraction/library | `Sources/SharedLibrary/Gather/` |
| Images | `Sources/SharedLibrary/Images/` |
| Git/GitHub sync | `Sources/SharedLibrary/Sync/` |
| Settings/support | `Sources/SharedLibrary/Settings/`, `Sources/SharedLibrary/Support/` |
| Tests | `Tests/SharedLibraryTests/` |
