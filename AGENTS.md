# Briefly Agent Instructions
- Do not preserve backwards compatibility.

## Project status

- `Apple/` is the active platform under development.
- `Web/` provides public share links plus supporting marketing, legal,
  administration, and native-backend surfaces. Do not add a customer account
  manager, checkout, or private web library reader.

- After Apple feature work is complete, run `swift test` once from `Apple/`, then
  use the repo script to rebuild, reinstall where needed, and reopen the affected
  app from the repo-local derived-data path. For macOS, from `Apple/` run:

  ```bash
  ./scripts/rebuild-and-reopen.sh macos
  ```

  For iOS changes, with a simulator booted, use:

  ```bash
  ./scripts/rebuild-and-reopen.sh ios
  ```

  For shared Apple changes, run `./scripts/rebuild-and-reopen.sh all`. The iOS
  build requires the matching Xcode platform component and a booted simulator.
  The script deliberately keeps development signing enabled and checks the
  macOS Sign in with Apple entitlement. Do not add `CODE_SIGNING_ALLOWED=NO` to
  launched builds; it strips capabilities such as Sign in with Apple.

## Test strategy

- Keep the suite intentionally small. Prefer a few end-to-end or request-boundary
  journeys that exercise production entry points over unit tests for helpers,
  branches, parsers, presentation details, or configuration values.
- Extend `Apple/Tests/BrieflyCoreTests/NativeInputTests.swift` for native item or
  channel capture boundaries. Extend `Web/worker/index.test.mjs` for Worker
  boundaries. Add a new test file only for a genuinely new executable boundary.
- Add a regression check only when failure would risk data loss, security,
  payments, or a core user journey.
- Assert observable output or persisted state. Do not test source text, exact CSS
  geometry, internal call counts, removed features, or duplicate the same
  behavior across platforms.
- Do not rebuild broad unit matrices or handwritten service/database emulators.
  Use the real CLI, Worker entry point, and the smallest binding stub needed to
  reach the boundary.
- Run `npm test` in `Shared/`. In `Web/`, run `npm run check`,
  `npm run test:worker`, and `npm run build` (or `npm test`, which runs all
  three with the required public environment values).

## Web UI

- Keep `Web/src/routes/+page.svelte` limited to the public share reader. Other
  public and legal routes remain platform-owned.
- Reuse the rendering primitives in `Shared/`; do not copy them into `Web/`.
- After changing web UI, run the Shared tests and Web checks.
