# Subscription setup (deferred)

The subscription is not presented in the current TestFlight beta. Keep this
document as future launch configuration only; do not expose the product in the
beta build or use it to gate the native library.

- Subscription group reference name: `ReadBriefly Membership`
- Subscription group display name (en-US): `ReadBriefly Membership`
- Subscription group ID: `22296827`
- Product reference name: `ReadBriefly Plus Monthly`
- Product ID: `fyi.readbriefly.plus.monthly`
- Apple subscription ID: `6799614082`
- Duration: 1 month
- Level: 1 (the only product in the group)
- Display name (en-US): `ReadBriefly Plus`
- Description (en-US): `Hosted processing, voice, transcription, and sharing.`
- Availability: all 175 countries or regions, including future storefronts
- Price: US `$8.49` per month, with App Store Connect's automatically derived
  prices for other storefronts (there is no exact `$8.50` tier)
- Family Sharing: off

Review notes:

> Briefly presents this subscription after onboarding. Sign in with Apple creates
> the Briefly account, after which the localized price and one-month renewal period
> appear before purchase. Restore Purchases, Manage Subscription, Privacy Policy,
> and Terms of Use are available from the membership and Settings screens. The App
> Review credentials supplied with the app version grant complimentary full access
> for feature review without creating a StoreKit transaction. That login opens an
> editable, prepopulated sample library stored separately from iCloud. Membership unlocks
> the native library, hosted AI processing, transcription, voice generation, web
> extraction fallback, private iCloud synchronization, and public share links.

The review screenshot must be captured from the finished build and show the
subscription screen in context. The first subscription and its subscription group
must be added to the same App Review submission as app version 1.0.
