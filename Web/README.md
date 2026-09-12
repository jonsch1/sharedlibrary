# Briefly Web

The SvelteKit site renders public share links and the supporting marketing,
feedback, administration, and legal pages. It does not contain a private library,
account manager, or checkout. The Cloudflare Worker supports Apple authentication
and public-share publishing. The beta does not run hosted AI inference; macOS
users can bring an OpenRouter API key or use a local provider CLI.

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

## Hosted processing

Hosted Briefly AI is disabled during the TestFlight beta. Keep
`HOSTED_PROCESSING_ENABLED=false` in the deployed Worker. macOS users process
locally with their own OpenRouter API key or a provider CLI; iOS stores captures
without generating summaries.

## Other deployment configuration

- `FIRECRAWL_API_KEY` enables authenticated extraction fallback.
- `HOSTED_PROCESSING_ENABLED=true` enables hosted Briefly AI processing for
  explicitly approved service accounts; keep it `false` for the beta.
- `APP_REVIEW_CREDENTIAL_HASH` enables the review-only credential boundary.
- `PUBLIC_POSTHOG_PROJECT_TOKEN` optionally enables consent-only analytics.
- D1 must be bound as `DB`; static assets must be bound as `ASSETS`.

`wrangler.jsonc` is the source of truth for production bindings, domains, secrets,
and variables. Deployment is handled by `.github/workflows/deploy-web.yml`.
