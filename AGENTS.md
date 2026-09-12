# Briefly Agent Instructions
- Do not preserve backwards compatibility.

## Project status

- `packages/apple/` owns the active Mac and iPhone/iPad apps, shared Swift code,
  migration tool, Xcode project, and build/release scripts. Keep shared UI in
  `App/Shared/`, platform code in `App/macOS/` and `App/iOS/`, and domain code in
  `Sources/BrieflyCore/`. `packages/mcp/` owns the MCP executable and plugin.
- `packages/web/` provides public share links plus supporting marketing, legal,
  administration, and native-backend surfaces. Do not add a customer account
  manager, checkout, or private web library reader.

- After Apple feature work is complete, run
  `swift test --package-path packages/apple` once from the repository root, then
  use the repo script to rebuild, reinstall where needed, and reopen the affected
  app from the repo-local derived-data path. For macOS, from the repository root run:

  ```bash
  ./packages/apple/scripts/rebuild-and-reopen.sh macos
  ```

  For iOS changes, with a simulator booted, use:

  ```bash
  ./packages/apple/scripts/rebuild-and-reopen.sh ios
  ```

  For shared Apple changes, run `./packages/apple/scripts/rebuild-and-reopen.sh all`. The iOS
  build requires the matching Xcode platform component and a booted simulator.
  The script deliberately keeps development signing enabled and checks the
  macOS Sign in with Apple entitlement. Do not add `CODE_SIGNING_ALLOWED=NO` to
  launched builds; it strips capabilities such as Sign in with Apple.

## Test strategy

- Keep the suite intentionally small. Prefer a few end-to-end or request-boundary
  journeys that exercise production entry points over unit tests for helpers,
  branches, parsers, presentation details, or configuration values.
- Extend `packages/apple/Tests/BrieflyCoreTests/NativeInputTests.swift` for native item or
  channel capture boundaries. Extend `packages/web/worker/index.test.mjs` for Worker
  boundaries. Add a new test file only for a genuinely new executable boundary.
- Add a regression check only when failure would risk data loss, security,
  payments, or a core user journey.
- Assert observable output or persisted state. Do not test source text, exact CSS
  geometry, internal call counts, removed features, or duplicate the same
  behavior across platforms.
- Do not rebuild broad unit matrices or handwritten service/database emulators.
  Use the real CLI, Worker entry point, and the smallest binding stub needed to
  reach the boundary.
- Install JavaScript dependencies with `npm ci` at the repository root; keep one
  root lockfile. Run `npm run test:web` for reader tests and all Web checks.
  Run `npm run test:sdk` for the real MCP/SDK capture journey.
- Keep shared web reader primitives in `packages/web/src/lib/reader/`. MCP depends
  on the BrieflyCore product from `packages/apple/` through SwiftPM.

## Web UI

- Keep `packages/web/src/routes/+page.svelte` limited to the public share reader. Other
  public and legal routes remain platform-owned.
- Reuse the rendering primitives in `packages/web/src/lib/reader/`.
- After changing web UI, run `npm run test:web`, including the reader tests.
