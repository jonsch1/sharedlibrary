# iOS App Architecture and Reuse Plan

Reviewed against the repository on 2026-07-30.

## Recommendation in brief

Build the first iOS app in **SwiftUI** under `apps/ios/`, with reader-first scope:
account sign-in, entitlement, provider connection, offline library sync, search,
summary-depth selection, Markdown reading, audio playback, source links, and share
links.

Expo has substantially better TypeScript reuse, but this repository's largest
mobile-specific constraint is iCloud. The current iCloud implementation talks
directly to a user's private CloudKit database from CloudKit JS
(`Web/src/lib/icloud.ts`), while Electron hosts that same code in a hidden browser
window (`Electron/src/main/backend.ts`). Expo would still need a custom Swift
CloudKit module or a privacy-significant backend redesign. It also cannot reuse the
current Svelte components or CSS.

Do not start by moving `Web/` and `Electron/` or by creating all seven proposed
packages. First extract the small boundaries that mobile actually needs, add a
mobile authentication flow, and prove one end-to-end library sync.

Choose Expo instead if an Android app is a committed near-term requirement. In that
case, put it under `apps/mobile/` and accept that iCloud remains an iOS native module.

## Assumed first-release scope

The practical first release is a native replacement for the existing mobile web
reader, not a phone-sized copy of every desktop feature.

Include:

- Apple and Google account sign-in and membership status.
- iCloud and Google Drive connection/status.
- Complete offline library mirror.
- Library and podcast-episode browsing, search, topic filtering, and all summary
  depths.
- Markdown and transcript reading.
- Audio playback with position and speed.
- Source links and deliberate share-link creation/revocation.
- Explicit analytics consent.

Defer:

- Local Codex/CLI processing (`Electron/src/main/processing.ts`).
- The loopback agent API (`Electron/src/main/agent-api.ts`).
- Global clipboard shortcuts and desktop window/menu behavior
  (`Electron/src/main/index.ts`).
- Workspace input extensions and the Node extractor (`Tools/extractor/` and
  `Electron/src/main/extraction.ts`).
- Scheduled channel scraping and signed-in browser automation
  (`Electron/src/main/channel-workflows.ts`).
- Editing and bidirectional conflict handling until the read-only mirror is proven.

Those capabilities depend on Electron, Node, child processes, an unrestricted local
workspace, or desktop interaction patterns. Treating them as iOS v1 requirements
would dominate the project while adding little validation of the core reader.

## Current architecture

### Repository and build shape

The repository is not currently a workspace monorepo:

- `Web/package.json`, `Electron/package.json`, and `Shared/package.json` each own an
  npm install and lockfile.
- Web and Electron install `Shared/` through `postinstall` scripts and import it by
  relative filesystem paths.
- `Web/vite.config.ts` explicitly allows Vite to read `../Shared`.
- Electron packaging reaches into `../Shared` and `../Tools/extractor` from
  `Electron/package.json`.
- GitHub workflows use `Web/`, `Electron/`, and `Shared/` in path filters, working
  directories, and npm cache paths
  (`.github/workflows/deploy-web.yml`, `.github/workflows/electron.yml`, and
  `.github/workflows/desktop-release-assets.yml`).

Moving the directories is possible but touches build, packaging, CI, deployment,
documentation, and many relative imports. It provides no mobile capability by
itself.

### Shared code

`Shared/library.ts` is the strongest existing cross-platform boundary. Its 349 lines
contain:

- the versioned library projection types;
- handwritten runtime validation and schema migration;
- selection, filtering, variant, content-comparison, and transcript helpers.

It is used by both apps and their tests. This is genuine platform-neutral TypeScript
and is the best initial package candidate.

The rest of `Shared/` is mostly web-platform code:

- `Shared/AudioPlayer.svelte` uses `HTMLAudioElement`, Media Session, Svelte state,
  and `localStorage`;
- `Shared/MarkdownView.svelte` uses Svelte, `marked`, DOMPurify, and HTML rendering;
- `Shared/DepthControl.svelte` is a Svelte/CSS control;
- `Shared/themes.ts` mixes reusable theme data with DOM, CSS-variable,
  `matchMedia`, and `localStorage` behavior;
- `Shared/tweakcn-themes.json` is reusable data, but some presets contain CSS units,
  HSL/OKLCH strings, font stacks, and web shadow values that native renderers cannot
  consume unchanged.

### Web

`Web/` combines two deployable concerns:

- a static SvelteKit reader and account UI in `Web/src/`;
- a Cloudflare Worker API in the 6,000-plus-line `Web/worker/index.js`, backed by D1,
  R2, Stripe, Google APIs, and Cloudflare assets as configured in
  `Web/wrangler.jsonc`.

The reader:

- keeps a complete path-preserving library mirror in IndexedDB
  (`Web/src/lib/library.ts`);
- accesses Google Drive through Worker endpoints
  (`Web/src/lib/google-drive.ts`);
- accesses the user's private iCloud database directly through CloudKit JS
  (`Web/src/lib/icloud.ts`);
- owns browser-specific fetch helpers for billing and sharing
  (`Web/src/lib/billing.ts`, `Web/src/lib/share-links.ts`);
- keeps most screen and workflow state directly in the 1,300-line
  `Web/src/routes/+page.svelte`;
- initializes opt-in `posthog-js` analytics in `Web/src/hooks.client.ts`, with event
  calls scattered through route components;
- is already an installable, offline-capable responsive PWA
  (`Web/static/manifest.webmanifest`, `Web/src/service-worker.ts`).

### Electron

Electron has a conventional three-part security boundary:

- Node/Electron services in `Electron/src/main/`;
- a narrow IPC bridge in `Electron/src/preload/index.ts`;
- a sandboxed Svelte renderer in `Electron/src/renderer/`.

`Electron/src/main/library.ts` makes the local Markdown workspace the source of
truth. `Electron/src/main/sync.ts` synchronizes it bidirectionally and preserves
conflict copies. `Electron/src/main/backend.ts` calls the hosted Worker for account,
Google Drive, billing, managed AI, library, media, and sharing operations.

The Electron renderer's types in `Electron/src/shared/contracts.ts` describe both
portable data and desktop-only IPC operations. Much of the UI and state lives in
`Electron/src/renderer/App.svelte` and `Electron/src/renderer/styles.css`; these
cannot be imported by either SwiftUI or React Native.

### Authentication and private sync

The current hosted session is browser-oriented:

- the Worker stores only a SHA-256 hash of a 90-day opaque session token in D1;
- it returns the raw token only as a secure, HTTP-only
  `shared_library_session` cookie;
- `authenticatedEmail()` in `Web/worker/index.js` reads only that cookie;
- mutation handlers call `requireSameOrigin()`, which requires a web `Origin`
  exactly matching the request URL;
- Apple and Google callbacks redirect to a path on the hosted web origin.

Electron works because its `session.defaultSession` shares the authentication
window's cookie jar and manually supplies the hosted origin. Swift `URLSession` and
React Native fetch do not inherit that Electron/browser session model.

Private storage is deliberately separate from Briefly account identity:

- Google Drive refresh credentials are encrypted and kept by the Worker.
- iCloud content never passes through the Worker. CloudKit JS accesses the private
  database directly, using the custom `Briefly` zone and
  `BrieflyLibraryIndex`, `BrieflyLibraryFile`, and `BrieflyLibraryMedia` records in
  `Web/src/lib/icloud.ts`.

That privacy boundary should remain intact.

## Proposed target structure

The eventual top-level layout is sound, but the package list is too granular for
the code that exists today.

```text
apps/
  web/                 # current Web/
  desktop/             # current Electron/
  ios/                 # SwiftUI recommendation
  # mobile/            # use this instead of ios/ if Expo is chosen

packages/
  library-contract/    # current Shared/library.ts: types, validation, pure helpers
  svelte-ui/           # current shared Svelte components and DOM theme adapter
  design-tokens/       # platform-neutral semantic color/type/spacing data
  api-client/          # useful for web/desktop and especially Expo

tools/
  extractor/           # current Tools/extractor/
```

Keep the Cloudflare Worker with `apps/web/worker/` because its deployment, static
assets, migrations, and Worker configuration are already one release unit.

Mapping from the proposed direction:

| Proposed package | Recommendation |
| --- | --- |
| `domain/` | Start as `library-contract/`; the current domain is too small to justify a separate package. |
| `schemas/` | Keep beside the domain types and validators initially. Split only if generated/native contracts later need an independent lifecycle. |
| `api-client/` | Create after mobile auth exists. It should accept a base URL and auth strategy instead of reading `window` or assuming relative URLs. |
| `auth/` | Do not create a universal client package. Browser cookies, Electron sessions, Swift Keychain, and Expo SecureStore need platform adapters. Share server protocol types only. |
| `analytics/` | Do not create an SDK wrapper yet. First centralize a small typed event-name catalog and consent rules; each platform initializes its own SDK. |
| `design-tokens/` | Worth creating, but normalize only semantic tokens needed by the product. Keep DOM application code in `svelte-ui/`. |
| state management | Keep app-owned. There is no existing shared store, and navigation/selection/background state differs substantially by platform. |

If Expo is selected, root npm workspaces are justified because Expo officially
supports workspace monorepos and automatic monorepo detection. If SwiftUI is
selected, an npm workspace migration is not a prerequisite for the iOS app. Expo's
official guide also notes the extra dependency-resolution complexity of monorepos:
[Expo monorepo guide](https://docs.expo.dev/guides/monorepos/).

### Migration order

1. Create `packages/library-contract/` and update existing imports without moving
   either app.
2. Create `packages/design-tokens/` only when the iOS token importer exists.
3. Create `packages/api-client/` only after the mobile auth/session contract is
   settled.
4. Move `Web/` and `Electron/` into `apps/` in a separate, mechanical change after
   all three clients build in CI.

This keeps path churn out of the critical mobile work.

## Native SwiftUI reuse assessment

Percentages below estimate **client implementation reused**, not backend uptime or
product behavior retained. Swift cannot compile the TypeScript source, so many areas
have high protocol/behavior reuse but zero direct source reuse.

| Area | Direct source/data reuse | Realistic retained behavior | Assessment |
| --- | ---: | ---: | --- |
| API | 0% client source | 80–90% of endpoints | Reimplement with `URLSession` and `Codable`; existing Worker endpoints remain, after mobile bearer auth is added. |
| Domain logic | 0% source | 75–90% of rules | Port the small helpers and enum ordering from `Shared/library.ts`; keep shared JSON fixtures to prevent drift. |
| Schemas | 0% compiled source | 85–95% of wire shapes | Recreate `LibraryProjection` and endpoint responses as `Codable`; the existing version and field semantics stay authoritative. |
| Authentication | 0% client source | 60–75% server identity/session code | Reuse D1 identities and opaque sessions, but add native login callback/exchange and bearer validation. Store tokens in Keychain. |
| Analytics | 0% SDK code | 60–80% event vocabulary | Reimplement consent and SDK setup; retain deliberate event names such as `library_synced` and `share_link_created`. |
| Design tokens | 40–60% raw data | 60–75% visual semantics | Reuse normalized colors, spacing, and radii. CSS units, color functions, font packages, and web shadows need native values. |
| State management | 0% | 15–25% selection rules | Use one app-owned observable model/actor. Do not port Svelte `$state` or introduce a state library. |
| UI | 0% | 30–50% UX and assets | Rebuild in SwiftUI. Reuse `Brand/briefly-icon.png`, layout intent, copy, accessibility labels, and reading-depth behavior. |
| Offline storage | 0% | 60–75% mirror algorithm | Reimplement the index-plus-content-hash mirror with `FileManager`; add SwiftData only if querying/performance later requires it. |
| iCloud | 0% source | 80–90% record contract | Reimplement `Web/src/lib/icloud.ts` with native CloudKit against the existing container, zone, record names, assets, and hashes. |
| Google Drive | 0% client source | 90% service behavior | Continue using the Worker as the account-scoped Drive gateway; the app does not need Google Drive credentials. |

### What is reusable directly

- Brand PNG assets in `Brand/`.
- A normalized subset of `Shared/tweakcn-themes.json` as bundled JSON.
- API URLs, payload semantics, library projection JSON, CloudKit record names, and
  existing server behavior.
- Test fixtures derived from `Shared/library.test.ts` and Worker tests.

### What needs refactoring first

- Mobile authentication and bearer-token support in `Web/worker/index.js`.
- Central endpoint response/request shapes currently duplicated between
  `Web/src/routes/+page.svelte`, `Web/src/routes/account/+page.svelte`,
  `Web/src/lib/*.ts`, `Electron/src/main/backend.ts`, and
  `Electron/src/shared/contracts.ts`.
- A platform-neutral semantic token file extracted from
  `Shared/tweakcn-themes.json`.
- Explicit documentation/tests for the CloudKit record contract, including the
  media record that `Web/README.md` currently omits from its table.

### What must be reimplemented

- SwiftUI screens, navigation, reader controls, settings, and account UI.
- `URLSession` API transport, `Codable` models, Keychain session storage, and deep
  links/universal links.
- Local file cache and sync orchestration.
- CloudKit access.
- Markdown rendering and sanitization policy.
- `AVPlayer`-based playback, position persistence, remote controls, and audio
  session behavior.
- Native analytics initialization and consent.

SwiftUI fits the platform constraint well: Apple's native CloudKit API can address
the same private container and records directly, and Authentication Services
provides native Sign in with Apple. See Apple's
[CloudKit private database documentation](https://developer.apple.com/documentation/cloudkit/ckdatabase)
and
[Authentication Services documentation](https://developer.apple.com/documentation/authenticationservices/asauthorizationappleidprovider).

## Expo/React Native reuse assessment

Expo can import platform-neutral TypeScript, but React Native cannot render Svelte
components, browser DOM, HTML audio, IndexedDB, or the current CSS.

| Area | Direct reuse now | Realistic reuse after refactor | Assessment |
| --- | ---: | ---: | --- |
| API | 25–40% | 75–85% | Fetch/error/payload code in `Web/src/lib/*.ts` can move to a base-URL/auth-aware client. Window navigation and cookie assumptions remain platform-specific. |
| Domain logic | 85–95% | 90–100% | `Shared/library.ts` can be imported almost unchanged after packaging. |
| Schemas | 55–70% | 85–95% | Library validation already exists. Consolidate other response interfaces and add runtime validation at the network boundary. |
| Authentication | 0–10% | 40–60% | Mobile redirect handling and SecureStore are new. The server identity/session extension is shared with the Swift option. |
| Analytics | 0% SDK code | 60–80% event vocabulary | `posthog-js` is browser-only; React Native initialization and consent are new. |
| Design tokens | 35–55% | 65–80% | JSON values can be shared after CSS values are normalized; React Native styles still need a platform adapter. |
| State management | 0% | 20–30% pure rules | Current state is embedded in Svelte pages. Use React hooks/context for v1; add a store only when actual cross-screen complexity requires it. |
| UI | 0% | 0% component code | All Svelte, DOM, and CSS UI must be rebuilt in React Native. Brand assets and UX intent remain useful. |
| Offline storage | 10–20% algorithm | 55–70% | Reuse the mirror flow, but replace IndexedDB with Expo FileSystem plus a JSON manifest. Use SQLite only when measurements justify it. |
| iCloud | 0% | 10–25% TypeScript orchestration | CloudKit JS is not a React Native API. Keep privacy semantics by writing a local Swift Expo module, or redesign sync through a backend. |
| Google Drive | 60–75% | 85–95% | The existing Worker-backed helper is close to portable once base URL and bearer auth are injected. |

Expo officially provides monorepo support, browser-based AuthSession, encrypted
SecureStore, FileSystem, and SQLite. Those cover most mobile plumbing, but not the
current CloudKit JS access model. See:

- [Expo authentication guide](https://docs.expo.dev/guides/authentication/)
- [Expo storage guide](https://docs.expo.dev/develop/user-interface/store-data/)
- [Expo FileSystem](https://docs.expo.dev/versions/latest/sdk/filesystem/)

### What is reusable directly

- Almost all of `Shared/library.ts`.
- Brand image assets.
- A normalized subset of the theme JSON.
- Pure request/response code extracted from `Web/src/lib/google-drive.ts`,
  `Web/src/lib/share-links.ts`, and `Web/src/lib/billing.ts`.
- Endpoint types and event names after consolidation.

### What needs refactoring first

- Turn relative fetches into an API client configured with `baseURL`, credentials,
  and an authorization-header provider.
- Separate browser redirect operations from request functions.
- Separate IndexedDB persistence from the mirror algorithm in
  `Web/src/lib/library.ts`.
- Separate raw theme values from DOM application in `Shared/themes.ts`.
- Move endpoint types out of Svelte route files and Electron-only contracts.
- Add the same mobile auth exchange required by Swift.

### What must be reimplemented

- Every screen and reusable UI component in React Native.
- Offline persistence and file downloads.
- Mobile auth/deep-link integration and SecureStore.
- Markdown presentation and audio playback.
- Analytics SDK setup and consent.
- CloudKit access through a custom native Swift module if iCloud remains a direct,
  private client connection.

The CloudKit module is the decisive cost. If it is built, the app is no longer a
pure managed-Expo project and the most difficult iOS-specific subsystem is still
Swift. If the product is iOS-only, that weakens Expo's main strategic advantage.

## Required cross-option refactors

### 1. Add a mobile session protocol

Keep cookie behavior unchanged for Web and Electron. Add a separate mobile flow:

1. The app opens a provider authorization URL with an app redirect and PKCE
   challenge.
2. The existing Worker completes Google or Apple identity linking.
3. The Worker redirects to the app with a short-lived, single-use authorization
   code, never a long-lived session token in the URL.
4. The app exchanges the code plus verifier for an opaque access token.
5. The app stores that token in Keychain or Expo SecureStore and sends
   `Authorization: Bearer …`.
6. `authenticatedEmail()` accepts either the existing secure cookie or a valid
   bearer session.
7. Mutation handlers accept either the current same-origin cookie request or a
   valid bearer request. They must not simply disable the origin check globally.
8. Add token revocation/logout and expiration behavior.

Expo's auth guidance likewise separates web cookies from securely stored native
tokens: [Expo authentication overview](https://docs.expo.dev/develop/authentication/).

### 2. Consolidate the wire contract

Move these into `packages/library-contract/`:

- `LibraryProjection` and its runtime parser from `Shared/library.ts`;
- account and provider status currently repeated in two Svelte pages and
  `Electron/src/main/backend.ts`;
- billing types from `Web/src/lib/billing.ts`;
- share types duplicated in `Web/src/lib/share-links.ts`,
  `Electron/src/main/backend.ts`, and `Electron/src/shared/contracts.ts`;
- mobile-auth request/response types.

Keep runtime validation at external trust boundaries. Do not introduce code
generation initially. For Swift, check the same committed JSON success/failure
fixtures with `Codable` tests.

### 3. Extract transport from browser behavior

Create a small fetch client only after the endpoints and auth are stable:

- configured backend origin;
- cookie or bearer auth supplied by the caller;
- JSON/error handling;
- account, billing, library, file/media, and sharing methods.

Leave browser navigation, Electron `BrowserWindow`, Swift authentication sessions,
and Expo AuthSession in their apps.

### 4. Make offline mirroring storage-agnostic

The portable algorithm is:

- validate the projection;
- compare content hashes;
- download missing files with bounded concurrency;
- activate the new projection only after required files are present;
- remove stale files after success.

`Web/src/lib/library.ts` currently combines that algorithm with IndexedDB. Extract
the pure comparison/planning step for Expo reuse. Swift can port the small algorithm
from fixtures without requiring a cross-language framework.

### 5. Freeze and test the iCloud wire format

Document and test:

- container ID and environment;
- `Briefly` custom zone;
- index, file, and media record types;
- deterministic record names;
- field names and types;
- asset filenames;
- SHA-256 and byte-count validation;
- change-tag conflict behavior.

The Swift app should use those existing records through `CKDatabase`, not introduce
a second CloudKit schema. Apple's documentation notes that low-level `CKDatabase`
access leaves conflict and change tracking to the app, which matches the current
manual index/asset protocol:
[CloudKit architecture options](https://developer.apple.com/documentation/cloudkit/deciding-whether-cloudkit-is-right-for-your-app).

### 6. Normalize only the design tokens mobile uses

Start with one semantic light/dark theme:

- background, foreground, surface, primary, secondary, muted, accent, destructive,
  and border colors;
- small/medium/large radii;
- spacing scale;
- body, heading, code, and reader typography roles.

Keep the many TweakCN presets and font packages on Web/Electron until native theme
switching is a real requirement. Convert unsupported CSS color functions and units
at build time or store normalized platform-neutral values.

### 7. Centralize analytics vocabulary, not SDKs

Define event names and allowed property shapes once. Keep consent persistence,
device identity, SDK lifecycle, and exception capture platform-specific. Electron
currently has no corresponding PostHog integration, so a universal analytics
package would be speculative.

## Phased implementation plan

### Phase 0 — Product boundary and contract fixtures

- Confirm reader-first scope and the minimum supported iOS version.
- Commit representative library projections for schema versions 2 and 3, invalid
  projections, account status, billing status, and share-link responses.
- Add a written CloudKit record contract based on `Web/src/lib/icloud.ts`.
- Define acceptance behavior for offline launch, interrupted sync, account changes,
  and provider disconnection.

Exit: a mobile client can be tested against stable payload fixtures without running
the UI.

### Phase 1 — Extract the minimum shared boundaries

- Move `Shared/library.ts` and its test to `packages/library-contract/`.
- Add the duplicated account, billing, connection, and sharing protocol types.
- Update Web and Electron imports in place.
- Split raw design tokens from `Shared/themes.ts`, but export only the initial
  semantic light/dark set for mobile.
- Do not move `Web/` or `Electron/`.

Exit: existing Web and Electron checks/builds pass with no behavior change.

### Phase 2 — Mobile authentication and API hardening

- Add mobile authorization start/exchange/revoke endpoints with PKCE and one-time
  codes.
- Extend Worker authentication to validate bearer sessions alongside cookies.
- Preserve same-origin checks for cookie mutations and authorize bearer mutations
  separately.
- Add tests for exchange replay, expiry, provider errors, logout, bearer access,
  cookie compatibility, and invalid origins.
- Add an absolute-URL API client boundary.

Exit: a command-line or minimal app harness can sign in and call
`/api/auth/status`, `/api/billing/status`, and a protected library endpoint with a
securely stored bearer token.

### Phase 3 — One-provider vertical slice

Implement the app shell, account status, library list, document reader, search,
summary-depth control, and offline cache against **Google Drive first**. It already
uses the Worker as a gateway and therefore tests the API/session architecture
without CloudKit work.

For SwiftUI:

- `Codable` contract models and `URLSession` actor/client;
- Keychain token storage;
- a single observable app model;
- `FileManager` cache keyed by content hash;
- native Markdown presentation and `AVPlayer`.

For Expo:

- import `library-contract`;
- AuthSession plus SecureStore;
- React hooks/context;
- Expo FileSystem plus a JSON manifest;
- React Native Markdown/audio components.

Exit: airplane-mode relaunch opens the last complete mirror, and a later sync swaps
to a fully downloaded new projection without exposing a partial library.

### Phase 4 — iCloud parity

SwiftUI:

- add the existing iCloud container entitlement;
- implement account-status checks and the existing custom zone/record contract with
  native CloudKit;
- validate hashes and byte counts before activating downloads;
- test on a real device against production CloudKit after development schema tests.

Expo:

- implement a local Expo module in Swift that exposes the same operations as
  `window.brieflyICloud`;
- use a development build, not Expo Go, for the native entitlement/module;
- keep record and hash validation in the shared TypeScript orchestration where
  practical.

Exit: an existing Web/Electron iCloud library opens in iOS and vice versa without
schema migration or sending private content through the Worker.

### Phase 5 — Account, sharing, audio, and analytics

- Provider selection/disconnection and membership states.
- Share create/status/copy/revoke flow.
- Background-safe audio, lock-screen controls, speed, and saved position.
- Explicit analytics opt-in before SDK initialization.
- Accessibility, Dynamic Type/font scaling, reduced motion, VoiceOver, and error
  recovery.

Exit: iOS covers the useful private-reader and sharing behavior of the mobile web
app.

### Phase 6 — Distribution and operational hardening

- Add iOS unit tests for fixtures, auth storage, sync planning, and CloudKit mapping.
- Add one UI smoke path: signed-out launch, fixture-backed library, document open.
- Add a dedicated iOS CI/TestFlight workflow without changing the Web deployment
  workflow.
- Add privacy manifest, entitlements, associated domains/URL scheme, App Store
  metadata, crash reporting policy, and release runbook.
- Test expired sessions, revoked Apple credentials, no iCloud account, low storage,
  interrupted downloads, and CloudKit/Drive conflicts.

Exit: an internal TestFlight build can be upgraded without losing its offline mirror
or auth state.

### Phase 7 — Optional repository move

Only after mobile is building reliably:

- move `Web/` to `apps/web/` and `Electron/` to `apps/desktop/`;
- update relative imports, Vite filesystem allowlists, npm scripts, packaging
  resources, workflow path filters, working directories, cache paths, and docs;
- perform no feature changes in the same commit.

For Expo, add a root workspace before or during Phase 3 if package imports require
it. For SwiftUI, this move can remain indefinitely deferred.

## Final recommendation

Use **native SwiftUI**.

The repository does contain useful shared TypeScript, but it is concentrated in one
small library contract. The large reusable-looking surfaces are Svelte, CSS,
IndexedDB, DOM audio/Markdown, Electron IPC, Node filesystem/process code, or
CloudKit JS. Expo would reuse the library contract and much of a refactored API
client, but it would still rebuild all UI and mobile state, replace offline storage
and authentication, and write Swift for CloudKit.

SwiftUI gives up direct TypeScript reuse but preserves more important assets:

- the existing Worker and D1/R2 backend;
- the Google Drive gateway;
- the exact library JSON contract;
- the direct-to-private-CloudKit privacy model;
- the existing CloudKit record schema;
- the product's offline and sharing behavior;
- native authentication, audio, background, accessibility, and iCloud integration.

The decision should flip to Expo only when Android is a committed product, not a
possible future one. Until then, the simplest path is a small SwiftUI reader, a
mobile bearer-session extension, shared payload fixtures, and no wholesale
monorepo reorganization.
