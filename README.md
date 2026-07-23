# Shared Library

Shared Library is a native macOS menu bar app for capturing, processing, browsing, editing, and synchronizing a local source library.

The repository also contains a native iPhone and iPad companion that browses a private iCloud projection of My Library and plays its summaries as spoken audio.

The default private workspace is `~/Documents/Shared Library`. Its workspace root is a Git repository. Sharing uses a second, separately configured repository that defaults to `~/Documents/Shared Library Shared`.

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

Once repository setup is complete, synchronization runs entirely in the background. Each serialized synchronization:

1. Stage and commit workspace changes locally.
2. Fetch `origin`.
3. Compare the local and remote branch histories.
4. Rebase only when the remote branch is ahead, then push only when the local branch is ahead.
5. Refresh the library when remote changes were applied.

Background synchronization is debounced and requested after meaningful operations, including completing capture processing, editing or deleting a capture, reorganizing content, and saving workspace agent instructions. It also runs after launch, wake, restored connectivity, and periodically while the app remains open. Each check fetches the current branch, compares the local and remote histories, rebases only when remote commits exist, and pushes only when local commits exist. The passive status reports the active phase and finishes with the actual result, including when everything is already up to date. Transient fetch and push failures retry with increasing delays. Rebase conflicts and authentication failures are surfaced in the passive status and must be resolved before synchronization can continue.

## Sharing

The Sharing tab configures the separate shared folder and its GitHub repository. It provides the same prerequisite checks, repository initialization, remote connection or creation, and passive background-sync status as the private workspace.

Use the people button in a capture's footer, or its context menu, to share it and optionally tag organization members. Sharing copies the original source and every existing companion summary to the matching paths in the shared repository. The canonical content is stored only once. Lightweight JSON references under each person's `shared/` and `shared_with/` folders record who shared the capture and who it was tagged for. Editing tags reconciles those references, and Unshare removes the mirrored content and all related references. The private library remains authoritative: edits and processing refresh an existing shared copy, and deleting a private capture also removes its shared copy.

Unsharing removes the files from the shared repository's current tree. Copies already pushed to Git remain available in repository history unless that history is explicitly rewritten.

## People

The People mode browses sharing activity by GitHub organization member. A person's `shared/` section contains captures they shared; `shared_with/` contains captures tagged for them. These tags organize content but do not create folder-level access control: every repository collaborator can still read the whole shared repository.

Settings → People provides the only GitHub roster refresh action. **Sync People from GitHub** reads the configured organization through the existing authenticated GitHub CLI session, creates `people/<login>/`, and triggers normal shared-repository synchronization afterward. The roster is never fetched automatically. Each `profile.json` stores only `githubID` and `displayName`; the login is represented by the directory name. Login changes are detected through the stable ID so the directory and its sharing history move together. Avatars and email addresses are not imported.

## iCloud mobile library

Git remains the source of truth. The macOS app builds a text-only projection containing the personal library plus captures tagged `shared_with` the current stable GitHub ID, then publishes it to the private CloudKit container `iCloud.com.sharedlibrary.app`. Sources and summary variants use CloudKit assets so long documents do not need to fit inside individual record fields. Stable capture and sharing IDs produce deterministic CloudKit record names; removed and unshared records are deleted during the next publication.

Settings → Mobile controls publication and reports iCloud status. Publication is debounced after meaningful library changes and completed Git synchronization, and can also be requested with **Publish Now**. No audio is uploaded: the mobile app downloads text, keeps an offline JSON cache, and uses on-device speech synthesis.

The mobile project is `Mobile/SharedLibraryMobile.xcodeproj`. It provides unified browsing and search, personal/shared provenance, all four summary lengths plus the original, a reorderable listening queue, background spoken-audio playback, and Lock Screen playback controls.

Build the simulator app with:

```bash
xcodebuild \
  -project Mobile/SharedLibraryMobile.xcodeproj \
  -scheme SharedLibraryMobile \
  -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/sharedlibrary-mobile-derived \
  CODE_SIGNING_ALLOWED=NO \
  build
```

Both the macOS bundle ID (`com.sharedlibrary.app`) and mobile bundle ID (`com.sharedlibrary.mobile`) must be assigned to the same Apple developer team and granted access to `iCloud.com.sharedlibrary.app`. Before distribution, deploy the development CloudKit schema to production in CloudKit Console.

`Desktop/SharedLibraryDesktop.xcodeproj` is the provisioning wrapper used by the normal install script. Its assembly phase embeds the SwiftPM-built executable and extractor resources into an Xcode-signed app so Apple can authorize the CloudKit entitlement. If automatic provisioning is unavailable, the script falls back to the previous certificate-signed bundle without iCloud access and reports that limitation.

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
| Capture extraction/library | `Sources/SharedLibrary/` |
| Git/GitHub sync | `Sources/SharedLibrary/Sync/` |
| Sharing mirror | `Sources/SharedLibrary/Sharing/` |
| GitHub people | `Sources/SharedLibrary/People/` |
| CloudKit projection | `Sources/SharedLibrary/Cloud/` |
| iPhone/iPad companion | `Mobile/SharedLibraryMobile.xcodeproj`, `Mobile/SharedLibraryMobile/` |
| Settings/support | `Sources/SharedLibrary/Settings/`, `Sources/SharedLibrary/Support/` |
| Tests | `Tests/SharedLibraryTests/` |
