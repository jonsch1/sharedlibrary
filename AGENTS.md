# Briefly Agent Instructions
- Do not preserve backwards compatibility.

## Project status

- `Apple/` is the active platform under development.
- `Web/` provides public share links plus supporting marketing, legal,
  administration, and native-backend surfaces. Do not add a customer account
  manager, checkout, or private web library reader.

- After Apple feature work is complete, run `swift test` once from `Apple/`, then
  rebuild and reopen the affected app from the repo-local derived-data path
  using the platform-specific flow:
  For macOS, from `Apple/` run:

  ```bash
  xcodebuild -project Briefly.xcodeproj -scheme Briefly \
    -destination 'platform=macOS' \
    -derivedDataPath .build/xcode/macos \
    CODE_SIGNING_ALLOWED=NO build
  osascript -e 'tell application "Briefly" to quit' 2>/dev/null || true
  open .build/xcode/macos/Build/Products/Debug/Briefly.app
  ```

  For iOS changes, with a simulator booted, use:

  ```bash
  xcodebuild -project Briefly.xcodeproj -scheme Briefly \
    -destination 'generic/platform=iOS Simulator' \
    -derivedDataPath .build/xcode/ios-simulator \
    CODE_SIGNING_ALLOWED=NO build
  xcrun simctl terminate booted fyi.readbriefly.BrieflyNative 2>/dev/null || true
  xcrun simctl install booted \
    .build/xcode/ios-simulator/Build/Products/Debug-iphonesimulator/Briefly.app
  xcrun simctl launch booted fyi.readbriefly.BrieflyNative
  ```

  For shared Apple changes, do both. The iOS build requires the matching Xcode
  platform component to be installed.

## Test strategy

- Keep the suite intentionally small. Prefer a few end-to-end or request-boundary
  journeys that exercise production entry points over unit tests for helpers,
  branches, parsers, presentation details, or configuration values.
- Extend one of the existing test files before creating another:
  `Tools/extractor/e2e.test.mjs` or `Web/worker/index.test.mjs`. Add a new file
  only for a genuinely new executable boundary.
- Add a regression check only when failure would risk data loss, security,
  payments, or a core user journey.
- Assert observable output or persisted state. Do not test source text, exact CSS
  geometry, internal call counts, removed features, or duplicate the same
  behavior across platforms.
- Do not rebuild broad unit matrices or handwritten service/database emulators.
  Use the real CLI, Worker entry point, and the smallest binding stub needed to
  reach the boundary.
- Run `npm test` in `Shared/` and `Tools/extractor/`, and
  `npm run test:worker` in `Web/`.

## Web UI

- Keep `Web/src/routes/+page.svelte` limited to the public share reader. Other
  public and legal routes remain platform-owned.
- Reuse the rendering primitives in `Shared/`; do not copy them into `Web/`.
- After changing web UI, run the Shared tests and Web checks.
