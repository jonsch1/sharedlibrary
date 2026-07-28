# Briefly Web

The mobile Briefly client is a private SvelteKit reader hosted on Cloudflare
Workers. Users sign in with Apple or Google, then independently choose iCloud or
Google Drive for their private library. IndexedDB keeps a complete path-preserving Markdown mirror
available offline. The previous complete mirror opens immediately while synchronization continues in
the background.

## Accounts

Google account sign-in requests only `openid email`. Sign in with Apple uses a
Services ID and a short-lived ES256 client-secret JWT. Configure
`APPLE_CLIENT_ID`, `APPLE_TEAM_ID`, `APPLE_KEY_ID`, and the multiline
`APPLE_PRIVATE_KEY`, then register
`https://www.readbriefly.fyi/api/auth/apple/callback` as the Services ID return URL.
The `/account` page owns sync connection, provider selection, and disconnection;
the reader only links there and reports the current status.

## Google Drive

Enable the Google Drive API and create one Web application OAuth client. Configure
its Client ID and Client Secret once for the deployment, then register
`https://www.readbriefly.fyi/api/google/connect/callback` as an authorized
redirect URI. Drive authorization is a separate flow after account sign-in. The web
and Electron clients reuse the saved personal library location.

The backend encrypts account tokens and requests only `drive.file`. It can therefore
access only files Briefly creates or that the user explicitly opens with it,
not the rest of the user's Drive. The app mirrors `library/`, `podcasts/`, and `topics.md`, and stores a
rebuildable metadata-only index under `.shared-library/`. It reuses existing
`Shared Library` and `Shared Library Media` folders during migration.

## iCloud

Create a CloudKit container and a CloudKit JS web-services token restricted to
`https://www.readbriefly.fyi`. Configure `CLOUDKIT_CONTAINER_ID`,
`CLOUDKIT_API_TOKEN`, and `CLOUDKIT_ENVIRONMENT` (`development` or `production`).
Briefly stores data in the user's private database and a custom `Briefly` zone:

| Record type | Fields |
| --- | --- |
| `BrieflyLibraryIndex` | `schemaVersion` Int64, `generatedAt` Int64, `payload` Asset |
| `BrieflyLibraryFile` | `path` String, `contentHash` String, `byteCount` Int64, `content` Asset |

Create and test the record types in development, then promote the schema in
CloudKit Console before setting `CLOUDKIT_ENVIRONMENT=production`. The browser
authenticates directly with CloudKit; Briefly's Worker receives the selected-provider
preference but not private iCloud file content. Each browser or Electron installation
must authorize iCloud from `/account` because CloudKit authentication is local to
that web session.

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

For an end-to-end pass, sign in with Apple and Google separately, choose each sync
provider, then buy Plus with Stripe's successful
test card `4242 4242 4242 4242` (any future expiry and any CVC), verify the
account and desktop app unlock, open the customer portal, cancel at period end,
and confirm access remains until the period ends. Also test checkout cancellation,
the declined card `4000 0000 0000 0002`, the 3D Secure card
`4000 0025 0000 3155`, duplicate webhook delivery, and a
renewal/payment failure with a Stripe Billing simulation. Local Wrangler uses
its own D1 and R2 data, not production data.

The deployment needs:

- a D1 binding named `DB`;
- `GOOGLE_DRIVE_WEB_CLIENT_ID` and a `GOOGLE_DRIVE_WEB_CLIENT_SECRET` secret;
- the four Sign in with Apple values and three CloudKit values described above
  when those providers should be offered;
- a `FIRECRAWL_API_KEY` Worker secret for authenticated extraction fallback;
- `STRIPE_SECRET_KEY`, `STRIPE_WEBHOOK_SECRET`, `STRIPE_PRODUCT_PLUS`,
  `STRIPE_PORTAL_CONFIGURATION_ID`, and the four Stripe
  Price IDs described below;
- public access to the account callback and capability-link routes. Provider
  credentials and library operations remain account-scoped by the app's secure,
  HTTP-only session cookie.

## Briefly Plus and Stripe

Briefly requires an account and active membership for app access and downloads.
The subscription includes cross-device iCloud or Google Drive synchronization and deliberate
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
Paid access activates automatically when the required deployment secrets and
Stripe IDs are present. Missing or invalid Stripe
configuration fails closed instead of granting free Plus access.
The owner account `schauljonathan@gmail.com` has complimentary Plus entitlement;
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
