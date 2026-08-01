# Briefly Web

The SvelteKit site renders public share links and the supporting marketing,
feedback, administration, and legal pages. It does not contain a private library,
account manager, or checkout. The Cloudflare Worker supports the native macOS and
iOS apps with Apple authentication, App Store entitlement verification, managed
processing, and public-share publishing.

## Development

```bash
npm install
npm test
```

Database definitions live in `db/schema.ts`; the unlaunched Apple-only baseline
is `drizzle/0000_*.sql`. Production applies it before deploying the Worker.

## Apple authentication

The native apps use AuthenticationServices and send a nonce-bound Apple identity
token to `/api/auth/apple/native`. Configure `APPLE_APP_BUNDLE_ID` with the native
bundle identifier and enable Sign in with Apple for both app entitlements.

The feedback and administration support pages may use Apple's web authorization
flow. Configure `APPLE_CLIENT_ID`, `APPLE_TEAM_ID`, `APPLE_KEY_ID`, and
`APPLE_PRIVATE_KEY`, then register
`https://www.readbriefly.fyi/api/auth/apple/callback` as the Services ID return URL.

## App Store subscriptions

Create one monthly auto-renewable subscription whose product identifier matches
`APP_STORE_PRODUCT_ID` (`fyi.readbriefly.plus.monthly` by default). The app attaches
its Briefly account UUID as StoreKit's `appAccountToken`; the Worker verifies each
transaction with the App Store Server API before granting hosted access.

Create an App Store Connect In-App Purchase key and configure
`APP_STORE_ISSUER_ID`, `APP_STORE_KEY_ID`, and `APP_STORE_PRIVATE_KEY`. Set the
App Store Server Notifications V2 production and sandbox URL to:

```
https://www.readbriefly.fyi/api/billing/apple/notifications
```

Pricing and cancellation are presented and managed by the App Store. The website
does not display a checkout or manage the customer's Apple account.

## Other deployment configuration

- `FIRECRAWL_API_KEY` enables authenticated extraction fallback.
- `OPENROUTER_API_KEY` enables hosted Briefly AI processing.
- `PAID_PROCESSING_ENABLED=false` stops new hosted processing during an incident.
- `PUBLIC_POSTHOG_PROJECT_TOKEN` optionally enables consent-only analytics.
- D1 must be bound as `DB`; static assets must be bound as `ASSETS`.

`wrangler.jsonc` is the source of truth for production bindings, domains, secrets,
and variables. Deployment is handled by `.github/workflows/deploy-web.yml`.
