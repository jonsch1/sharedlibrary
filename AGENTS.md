# Briefly Agent Instructions

## Project status

- `Apple/` is the active platform under development.
- `Electron/` will be archived soon and is retained for reference only; do not add new Electron work unless explicitly requested.

- After changing `Apple/`, run `swift test` there and build the `Briefly` scheme
  for macOS and the generic iOS Simulator destination. The iOS build requires
  the matching Xcode platform component to be installed.

## Test strategy

- Keep the suite intentionally small. Prefer a few end-to-end or request-boundary
  journeys that exercise production entry points over unit tests for helpers,
  branches, parsers, presentation details, or configuration values.
- Extend one of the existing test files before creating another:
  `Shared/app.test.ts`, `Tools/extractor/e2e.test.mjs`,
  `Web/worker/index.test.mjs`. Add a new file only for a genuinely new executable
  boundary.
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

## Shared app UI

- `Shared/App.svelte` and `Shared/styles.css` are the source of truth for the
  authenticated web app UI.
- Keep `Web/src/routes/+page.svelte` as a thin platform adapter. Add shared UI
  and behavior in `Shared/`, then expose platform differences through
  `BrieflyAppCapabilities` or the shared API.
- Do not copy shared components or styles into a platform directory. Web-only
  public/account routes remain platform-owned.
- After changing shared app UI, run the Shared tests and Web checks.