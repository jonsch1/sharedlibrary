# Briefly App Store launch checklist

This directory is deliberately separate from the application source. It contains
publishing copy, compliance drafts, and asset handoff material only.

## Fastest release path

Ship the iOS/iPadOS app first, in English (U.S.), as a free TestFlight beta with
no subscription or hosted AI. Use automatic release after approval unless a
coordinated launch date matters more than speed. Add the macOS version in a
separate submission after iOS is through review.

## Status

- [x] Confirm current upload toolchain requirement: Xcode 26 or later. The local
  machine has Xcode 26.0.1.
- [x] Confirm bundle ID and product ID used by the app:
  `fyi.readbriefly.BrieflyNative` and `fyi.readbriefly.plus.monthly`.
- [x] Prepare English App Store listing copy and URLs in `metadata/en-US/`.
- [x] Prepare privacy-label, age-rating, export-compliance, review-note, and
  subscription drafts.
- [x] Prepare a 1024 x 1024 opaque App Store icon master in `assets/`.
- [x] Sign in to App Store Connect and confirm the native bundle ID is available.
- [x] Create the `ReadBriefly` iOS/macOS app record in App Store Connect using
  `fyi.readbriefly.BrieflyNative`.
- [x] Save the English (U.S.) iOS and macOS listings as `ReadBriefly`, with the
  subtitle “Stay curious. Build a library.”, Productivity/News categories,
  review notes, support/marketing URLs, and automatic release.
- [x] Complete the age-rating questionnaire and publish the App Privacy label
  for the six collected data types, all linked to the user and none used for
  tracking or advertising.
- [x] Set the app itself to free and available in all 175 App Store countries
  and regions, with public App Store distribution.
- [x] Accept the Paid Apps Agreement. It is pending completion of banking and
  tax information.
- [x] Defer the subscription and hosted AI flow until after the TestFlight beta.
- [ ] Add a bank account and complete the U.S. tax questionnaire.
- [ ] Receive approval for the App Store Small Business Program. Enrollment was
  submitted on August 9, 2026 with no associated developer accounts declared
  and prior-year proceeds confirmed below `$1,000,000`; Apple will email the
  account holder with its decision.
- [x] Complete the Digital Services Act declaration as a trader.
- [x] Attest that the app accesses third-party content and has the necessary
  rights or other legal permission to do so.
- [ ] Confirm owner attestations listed below.
- [x] Embed the supplied icon in an `AppIcon` catalog for iOS, iPadOS, and macOS.
- [x] Align the app, share extension, and UI-test targets with App Store version
  `1.0`; the TestFlight release script applies one explicit build number to the
  app and share extension at archive time.
- [x] Add in-app account deletion, including Sign in with Apple
  token revocation and deletion of server-side account data not legally retained.
- [x] Embed a valid `PrivacyInfo.xcprivacy` covering the app's required-reason
  API use in the app and share extension resource bundles.
- [x] Set `ITSAppUsesNonExemptEncryption` to `NO`; the source audit found Apple
  transport/storage services and SHA-256 hashing, with no proprietary or
  non-standard encryption.
- [x] Add a repeatable iOS archive/upload script and prepare the TestFlight beta
  description, test instructions, group plan, and feedback address.
- [x] Deploy the tested account-deletion Worker and its one-table database
  migration to production.
- [x] Create and verify the finished iOS archive with
  `BUILD_NUMBER=<unique> ./scripts/testflight.sh archive`.
- [x] Re-sign and export the archive locally with
  `BUILD_NUMBER=<same> ./scripts/testflight.sh export`.
- [x] Upload build 5 with `BUILD_NUMBER=5 ./scripts/testflight.sh upload`; App
  Store Connect accepted it and processing is in progress.
- [ ] Add the processed build to an internal TestFlight group and complete an
  internal smoke test before inviting external testers.
- [ ] Capture and upload at least one iPhone 6.9-inch screenshot and one iPad
  13-inch screenshot; the five-screen plan below is preferred.
- [ ] Attach the processed beta build to the TestFlight group and complete the
  native capture/library smoke test.

## Distribution signing

Xcode successfully exported iOS build 4 on August 20, 2026 using the team's
cloud-managed Apple Distribution certificate and App Store provisioning profiles
for the app and share extension. The export verified non-debuggable binaries,
production push notifications, and the production CloudKit environment.

TestFlight beta copy, group defaults, and the release commands are in
[`testflight.md`](testflight.md).

## Screenshot plan

Use real final-build UI, with no debug data, personal email, or third-party
copyrighted article text. Raw screenshots may be uploaded; short captioned frames
can be added later if desired.

1. Home/library — “Save anything. Get the point.”
2. Reader depth controls — “Read at the depth you choose.”
3. Capture flow — “Articles, videos, podcasts, and notes.”
4. Channels/brief — “Keep up without the feed.”
5. Audio player — “Read it or listen.”

Required launch sizes:

- iPhone 6.9-inch portrait: use an accepted 1260 x 2736, 1290 x 2796, or
  1320 x 2868 PNG/JPEG without transparency.
- iPad 13-inch portrait: use 2064 x 2752 or 2048 x 2732 PNG/JPEG without
  transparency.
- Subscription screenshots are intentionally deferred until the paid product is
  reintroduced.

## Owner input required before external submission

- Export-compliance attestation that the app uses only exempt standard encryption
  supplied by Apple (for example HTTPS) and no proprietary/non-standard crypto.
- Bank account details and the answers required by Apple's U.S. tax questionnaire.

## Defaults prepared for speed

- Platforms: iOS/iPadOS first; macOS second.
- Primary language: English (U.S.).
- Primary category: Productivity.
- Secondary category: News.
- Price: Free TestFlight beta; any monthly subscription is deferred.
- Release: Automatic after approval.
- Age rating: answer **Yes** to unrestricted web access, which produces 16+ on
  Apple OS 26-era storefronts (17+ on older OS versions). All other content and
  capability answers are `None`/`No` unless the final app adds them.
- Tracking: No.
- Advertising: No.
