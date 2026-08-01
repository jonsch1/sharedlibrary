# Briefly Agent Instructions

## Project status

- `Apple/` is the active platform under development.
- `Web/` provides public share links plus supporting marketing, account, legal,
  and backend surfaces. Do not restore a private web library reader.

- After changing `Apple/`, run `swift test` there and build the `Briefly` scheme
  for macOS and the generic iOS Simulator destination. The iOS build requires
  the matching Xcode platform component to be installed.

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
  public, account, and legal routes remain platform-owned.
- Reuse the rendering primitives in `Shared/`; do not copy them into `Web/`.
- After changing web UI, run the Shared tests and Web checks.
