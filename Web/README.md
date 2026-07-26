# Briefly Web

The mobile Briefly client is a private SvelteKit reader hosted on Cloudflare
Workers. Google Drive supplies a lightweight file index, mirrored Markdown documents,
and generated audio. IndexedDB keeps a complete path-preserving Markdown mirror
available offline, and existing narration is mirrored into the local audio cache.
The previous complete mirror opens immediately while synchronization continues in
the background.

## Google Drive

Enable the Google Drive API and create one Web application OAuth client. Configure
its Client ID and Client Secret once for the deployment, then register
`https://www.readbriefly.fyi/api/google/connect/callback` as an authorized
redirect URI. Google sign-in creates an app session and configures one personal
library folder for the account. The web and Electron clients reuse that saved
location.

The backend encrypts account tokens and requests only `drive.file`. It can therefore
access only files Briefly creates or that the user explicitly opens with it,
not the rest of the user's Drive. The app mirrors `library/` and `topics.md`, stores a
rebuildable metadata-only index under `.shared-library/`, and keeps content-addressed
audio under `audio/` in a visible `Briefly` folder. It reuses existing
`Shared Library` and `Shared Library Media` folders during migration.

## OpenRouter

OpenRouter OAuth is optional and account-scoped. Its key is encrypted in D1 and used
only by the server-side speech route. Audio playback begins from a complete MP3
response, then the result is cached in the browser and copied to Google Drive.

## Development

```bash
npm install
npm run check
npm run test:worker
npm run db:generate
npm run build
```

Database definitions live in `db/schema.ts`; generated migrations live in
`drizzle/`. The worker also creates missing active tables defensively.

The deployment needs:

- a D1 binding named `DB`;
- an `OPENROUTER_CREDENTIAL_KEY` secret containing 32 random bytes encoded as
  64 hexadecimal characters;
- `GOOGLE_DRIVE_WEB_CLIENT_ID` and a `GOOGLE_DRIVE_WEB_CLIENT_SECRET` secret;
- `STRIPE_SECRET_KEY`, `STRIPE_WEBHOOK_SECRET`, and the four Stripe Price IDs
  described below;
- public access to the Google sign-in and capability-link routes. Provider
  credentials and library operations remain account-scoped by the app's secure,
  HTTP-only Google session cookie.

## Briefly Plus and Stripe

Briefly keeps the local desktop experience free. Plus pays for cross-device
Google Drive synchronization and deliberate public share links. Launch pricing
is a grandfathered monthly ladder:

| Subscribers | Price | Stripe environment variable |
| --- | ---: | --- |
| First 50 | €3.99/month | `STRIPE_PRICE_FOUNDING` |
| Next 100 | €5.99/month | `STRIPE_PRICE_EARLY` |
| Next 250 | €7.99/month | `STRIPE_PRICE_GROWING` |
| Thereafter | €9.99/month | `STRIPE_PRICE_STANDARD` |

Create one recurring Stripe Product named **Briefly Plus** and four EUR monthly
Prices matching that table. Existing subscribers remain on their Price while
their subscription stays active. A customer who cancels and later returns joins
at the price then available.

Configure Stripe before enabling paid access:

1. Add the four Price IDs and `STRIPE_SECRET_KEY` as deployment secrets.
2. Enable and configure the Stripe customer portal in both sandbox and live
   mode so customers can update payment methods and cancel.
3. Add a Stripe webhook endpoint at
   `https://www.readbriefly.fyi/api/billing/webhook`.
4. Subscribe it to `checkout.session.completed`, `checkout.session.expired`,
   `customer.subscription.created`, `customer.subscription.updated`, and
   `customer.subscription.deleted`, then save its signing secret as
   `STRIPE_WEBHOOK_SECRET`.
5. Complete Stripe Tax registration and set the Briefly Plus product's tax code
   to the appropriate software-as-a-service code. Checkout collects and validates
   billing location and tax IDs.

Paid-route enforcement activates only when all Stripe values are present and
valid. Until then the current library and sharing behavior remains available,
while the pricing UI clearly reports that checkout setup is pending.

## Cloudflare deployment

`wrangler.jsonc` is the source of truth for the Worker, static assets, D1
database, R2 bucket, and custom domains. Configure deployment secrets with
`wrangler secret put`, then deploy the current build and outstanding D1
migrations with:

```bash
npm run deploy
```
