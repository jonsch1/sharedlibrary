# Briefly App Store launch checklist

This directory is deliberately separate from the application source. It contains
publishing copy, compliance drafts, and asset handoff material only.

## Fastest release path

Ship the iOS/iPadOS app first, in English (U.S.), as a free download with the
existing monthly subscription. Submit the first subscription, its subscription
group, and app version in the same review submission. Use automatic release after
approval unless a coordinated launch date matters more than speed. Add the macOS
version in a separate submission after iOS is through review.

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
- [x] Create and localize the monthly subscription and subscription group, make
  them available in all 175 storefronts, set the U.S. price to `$8.49`, and
  leave Family Sharing off.
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
  `1.0` and build `1`.
- [x] Add in-app account deletion, including Sign in with Apple
  token revocation and deletion of server-side account data not legally retained.
- [x] Embed a valid `PrivacyInfo.xcprivacy` covering the app's required-reason
  API use in the app and share extension resource bundles.
- [x] Set `ITSAppUsesNonExemptEncryption` to `NO`; the source audit found Apple
  transport/storage services and SHA-256 hashing, with no proprietary or
  non-standard encryption.
- [x] Deploy the tested account-deletion Worker and its one-table database
  migration to production.
- [ ] Archive the finished iOS build with Xcode 26, validate it, and upload it.
- [ ] Capture and upload at least one iPhone 6.9-inch screenshot and one iPad
  13-inch screenshot; the five-screen plan below is preferred.
- [ ] Upload the subscription review screenshot from Settings > Account.
- [ ] Attach the processed build to version 1.0 and submit the app, subscription,
  and subscription group together.

## App-team blockers (do not submit before these are fixed)

1. **Distribution signing:** the sandboxed audit did not find a valid local code
   signing identity. Re-check from Xcode's Accounts settings before archiving and
   let automatic signing create or download the Apple Distribution certificate
   and App Store provisioning profiles if needed.

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
- The subscription review screenshot is separate and should show the localized
  product, price, period, Subscribe action, Restore Purchases, Privacy Policy,
  and Terms of Use in context.

## Owner input required before external submission

- Export-compliance attestation that the app uses only exempt standard encryption
  supplied by Apple (for example HTTPS) and no proprietary/non-standard crypto.
- Bank account details and the answers required by Apple's U.S. tax questionnaire.

## Defaults prepared for speed

- Platforms: iOS/iPadOS first; macOS second.
- Primary language: English (U.S.).
- Primary category: Productivity.
- Secondary category: News.
- Price: Free app with one monthly auto-renewable subscription.
- Release: Automatic after approval.
- Age rating: answer **Yes** to unrestricted web access, which produces 16+ on
  Apple OS 26-era storefronts (17+ on older OS versions). All other content and
  capability answers are `None`/`No` unless the final app adds them.
- Tracking: No.
- Advertising: No.
