# Briefly production operations

## Launch configuration

- Apply the Apple-only D1 baseline to a new database.
- Configure Sign in with Apple, the App Store Server API key, the monthly product,
  and App Store Server Notifications V2 for production and sandbox.
- Keep `PAID_PROCESSING_ENABLED=true` normally; set it to `false` to stop new
  hosted processing during an incident.
- Configure consent-only PostHog analytics with no autocapture, replay, or email
  identification.
- Alert on Cloudflare 5xx/D1 failures, failed App Store notifications, Firecrawl
  exhaustion, and upstream processing failures.

Every production error response includes `X-Request-ID`; the Worker logs that ID,
method, path, and a sanitized error message.

## Account erasure

Until self-service erasure exists, requests go to `hello@readbriefly.fyi`.

1. Verify control of the Sign in with Apple identity.
2. Tell the requester to cancel any renewing subscription in Apple's subscription
   settings; deleting Briefly data does not cancel an App Store subscription.
3. Delete the account's public-share text and links, sessions, identity, feedback,
   usage, leases, limits, managed-AI counters, and entitlement rows.
4. Explain that local files and private CloudKit records remain controlled by the
   user through their devices and Apple account.
5. Retain only records required by law, then confirm completion.

## Release acceptance

- Native Sign in with Apple succeeds on macOS and iOS.
- StoreKit purchase, restore, renewal, cancellation, expiry, and revocation update
  the same Briefly account in sandbox.
- Two Apple devices synchronize representative iCloud changes.
- Hosted extraction and AI processing fail closed without an active entitlement.
- A public share exposes only selected summaries and metadata, then disappears
  after revocation.
- macOS and iOS builds and the web/Worker checks pass.
