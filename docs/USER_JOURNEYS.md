# Application journey tests

These tests protect Briefly's user-visible behavior while its architecture changes. They intentionally exercise production entry points and persisted state instead of view layout or implementation details.

## Covered journeys

| Journey | Boundary | Observable contract |
| --- | --- | --- |
| Open a saved item and change reading depth | Native UI + SQLite library | Seeded Home item opens and the detailed variant can be selected |
| Move through Channels, Briefs, and Library | Native UI + projection | Seeded channel story and brief episode appear in their sections; Library remains actionable |
| Open the capture workflow | Native UI | The primary Library action opens the production capture composer |
| Canonical library lifecycle | `BrieflyCore` test suite | Capture, variants, highlights, channels, briefs, trash, and restore persist through the store APIs |

## Deterministic native test mode

The UI target launches the app with `--ui-testing`. In that mode the app:

- uses a scenario-specific SQLite database under Application Support;
- optionally resets it with `--ui-test-reset`;
- seeds fixed Home, Channel, and Brief content through the production database API;
- skips account, CloudKit, speech warm-up, scheduled work, and backend processing.

This mode is dependency-aware rather than a mock UI: navigation, projections, capture, and persistence still use the app's real model and database. Network and account journeys should be tested separately at their request or service boundaries, not made prerequisites for this tour.

## Running the tours

Open `packages/apple/Briefly.xcodeproj` in Xcode and run the `Briefly` scheme tests on macOS or a booted iOS simulator. From the repository root, select an available destination, for example:

```bash
xcodebuild test \
  -project packages/apple/Briefly.xcodeproj \
  -scheme Briefly \
  -destination 'platform=macOS'
```

When adding a user story, extend an existing tour if it shares the same executable boundary. Add a separate test only for a core journey whose failure would risk persisted data, security, payments, or the primary reading workflow.
