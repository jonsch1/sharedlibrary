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

Briefly uses one server-side OpenRouter account for optional paid narration. Users
never connect or see that credential. Readers choose Low (Kokoro), Medium (Orpheus),
or High (Grok Voice) quality. Supported browsers begin playback as MP3 bytes arrive;
the complete result is cached in the browser and copied to Google Drive.

AI voice credit is prepaid in €5, €10, or €20 increments through Stripe. The server
reserves the exact character-based retail charge before requesting speech, releases
it on provider failure, and records successful usage in D1. Purchased credit is
non-refundable except where required by law and has no short product expiry.
The first successfully paid Briefly Plus Checkout also grants that account a
one-time AI voice credit equal to the total EUR amount paid; renewals and later
subscriptions do not grant it again.

## Development

```bash
npm install
npm test
npm run db:generate
```

Database definitions live in `db/schema.ts`; generated migrations live in
`drizzle/`. The worker also creates missing active tables defensively.

### Local Stripe sandbox

Use one isolated Stripe sandbox for local development:

1. Copy `.env.example` to `.env`. Fill it with the sandbox's `sk_test_` or
   restricted `rk_test_` key, Product, Price, and portal configuration IDs.
   Never mix live and sandbox IDs.
2. Add `http://localhost:8787/api/google/connect/callback` to the Google OAuth
   client's authorized redirect URIs, then start the production-like local app:

   ```bash
   npm run dev:full
   ```

3. In another terminal, run the Stripe CLI against the same sandbox:

   ```bash
   stripe listen \
     --events checkout.session.completed,checkout.session.expired,checkout.session.async_payment_succeeded,checkout.session.async_payment_failed,customer.subscription.created,customer.subscription.updated,customer.subscription.deleted,invoice.paid,invoice.payment_failed \
     --forward-to http://localhost:8787/api/billing/webhook
   ```

   Put the printed `whsec_...` signing secret in `.env` as
   `STRIPE_WEBHOOK_SECRET`, then restart `npm run dev:full`.

For an end-to-end pass, sign in with Google, buy Plus with Stripe's successful
test card `4242 4242 4242 4242` (any future expiry and any CVC), verify the
account and desktop app unlock, open the customer portal, cancel at period end,
and confirm access remains until the period ends. Also test checkout cancellation,
the declined card `4000 0000 0000 0002`, the 3D Secure card
`4000 0025 0000 3155`, an AI voice top-up, duplicate webhook delivery, and a
renewal/payment failure with a Stripe Billing simulation. Local Wrangler uses
its own D1 and R2 data, not production data.

The deployment needs:

- a D1 binding named `DB`;
- an `OPENROUTER_CREDENTIAL_KEY` secret containing 32 random bytes encoded as
  64 hexadecimal characters;
- an `OPENROUTER_API_KEY` secret for Briefly's managed OpenRouter account;
- `GOOGLE_DRIVE_WEB_CLIENT_ID` and a `GOOGLE_DRIVE_WEB_CLIENT_SECRET` secret;
- `STRIPE_SECRET_KEY`, `STRIPE_WEBHOOK_SECRET`, `STRIPE_PRODUCT_PLUS`,
  `STRIPE_PRODUCT_TTS`, `STRIPE_PORTAL_CONFIGURATION_ID`, and the four Stripe
  Price IDs described below;
- public access to the Google sign-in and capability-link routes. Provider
  credentials and library operations remain account-scoped by the app's secure,
  HTTP-only Google session cookie.

## Briefly Plus and Stripe

Briefly requires an account and active membership for app access and downloads.
The subscription includes cross-device Google Drive synchronization and deliberate
public share links. Launch pricing
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

Configure Stripe for paid access:

1. Create a single `Briefly Plus` Product and four flat-rate recurring monthly
   Prices. Add their Product and Price IDs plus a least-privilege
   `STRIPE_SECRET_KEY` as deployment secrets. Briefly validates each selected
   Price against its expected Product, EUR amount, and monthly recurrence before
   opening Checkout.
2. Create a dedicated Stripe customer portal configuration in both sandbox and
   live mode. Allow customers to update billing information and payment methods,
   view invoices, and cancel at period end. Disable plan switching, quantity
   changes, and promotion codes, then save its ID as
   `STRIPE_PORTAL_CONFIGURATION_ID`.
3. Add a Stripe webhook endpoint at
   `https://www.readbriefly.fyi/api/billing/webhook`.
4. Pin the event destination to Stripe API version `2026-06-24.dahlia`.
   Subscribe it to `checkout.session.completed`, `checkout.session.expired`,
   `customer.subscription.created`, `customer.subscription.updated`,
   `customer.subscription.deleted`, `invoice.paid`, and
   `invoice.payment_failed`, then save its signing secret as
   `STRIPE_WEBHOOK_SECRET`. Briefly currently restricts Checkout to card-based
   payment methods; also subscribe to Checkout's async payment success/failure
   events before enabling asynchronous methods.
5. Complete Stripe Tax registration and set the Briefly Plus product's tax code
   to the appropriate software-as-a-service code. Checkout collects and validates
   billing location and tax IDs.
6. Create a separate one-time Product named **Briefly AI voice credit**, set its
   appropriate digital-service tax code, and save its ID as `STRIPE_PRODUCT_TTS`.
   Top-up Prices are created inline by Checkout so no separate Price IDs are
   needed. Keep the existing webhook subscribed to Checkout completion and async
   payment events; the same idempotent handler credits both subscriptions and
   narration top-ups.

Paid access and managed narration activate automatically when their required
deployment secrets and Stripe IDs are present. Missing or invalid Stripe
configuration fails closed instead of granting free Plus access.
The owner account `schauljonathan@gmail.com` has complimentary Plus entitlement;
it does not receive unlimited metered AI voice credit.
`STRIPE_PAST_DUE_GRACE_DAYS` controls the finite past-due entitlement window and
defaults to seven days. A daily Worker cron reconciles D1 subscription state with
Stripe.

## Cloudflare deployment

`wrangler.jsonc` is the source of truth for the Worker, static assets, D1
database, R2 bucket, and custom domains. Production deployments are automated:
push completed Web changes to `main` and
`.github/workflows/deploy-web.yml` runs the checks, worker tests, production
build, outstanding D1 migrations, and Cloudflare deployment.

Do not run `npm run deploy` from a local checkout. Configure production secrets
and variables in the GitHub `production` environment and Cloudflare before
merging changes that depend on them.
