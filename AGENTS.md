# Briefly Agent Instructions

- After changing `Electron/`, run its tests, typecheck, and build. Package and
  restart the Electron app after desktop-facing changes so the user can test it.
- After changing `Web/`, run its checks, worker tests, and production build.
  Do not deploy from a local checkout. Pushing completed changes to `main`
  triggers `.github/workflows/deploy-web.yml`, which applies D1 migrations and
  deploys to Cloudflare.
- After changing `Apple/`, run `swift test` there and build the `Briefly` scheme
  for macOS and the generic iOS Simulator destination. The iOS build requires
  the matching Xcode platform component to be installed.

## Test strategy

- Keep the suite intentionally small. Prefer a few end-to-end or request-boundary
  journeys that exercise production entry points over unit tests for helpers,
  branches, parsers, presentation details, or configuration values.
- Extend one of the existing test files before creating another:
  `Shared/app.test.ts`, `Tools/extractor/e2e.test.mjs`,
  `Electron/src/main/safety.test.ts`, `Electron/e2e/smoke.spec.ts`, or
  `Web/worker/index.test.mjs`. Add a new file only for a genuinely new executable
  boundary.
- Add a regression check only when failure would risk data loss, security,
  payments, or a core user journey. The narrow Electron safety tests are the
  explicit exception to the end-to-end preference.
- Assert observable output or persisted state. Do not test source text, exact CSS
  geometry, internal call counts, removed features, or duplicate the same
  behavior across platforms.
- Do not rebuild broad unit matrices or handwritten service/database emulators.
  Use the real CLI, production Electron build, Worker entry point, and the
  smallest binding stub needed to reach the boundary.
- Run `npm test` in `Shared/` and `Tools/extractor/`, `npm test` plus
  `npm run test:e2e` in `Electron/`, and `npm run test:worker` in `Web/`.

## Shared app UI

- `Shared/App.svelte` and `Shared/styles.css` are the source of truth for the
  authenticated app UI on web and Electron.
- Keep `Web/src/routes/+page.svelte` and `Electron/src/renderer/App.svelte` as
  thin platform adapters. Add shared UI and behavior in `Shared/`, then expose
  platform differences through `BrieflyAppCapabilities` or the shared API.
- Do not copy shared components or styles into a platform directory. Web-only
  public/account routes and Electron-native integrations remain platform-owned.
- After changing shared app UI, run the Shared tests and both platforms' checks.

## Generated Briefly workspace instructions

The `AGENTS.md` populated in a user's Briefly workspace must make the
following document behavior explicit:

- When the user asks to create, write, compile, consolidate, or put material
  into a “document,” default to a Markdown root capture at
  `library/<descriptive-name>.md`.
- Treat “document” as Markdown unless the user explicitly requests another
  format such as DOCX or PDF.
- Do not place the default document at the workspace root or create a separate
  documents directory.
- When another format is explicitly requested, also create and retain the
  Markdown source in `library/` unless the user explicitly opts out.
- Prefer a clear title, useful headings, source links, and readable Markdown
  over document-specific styling.
