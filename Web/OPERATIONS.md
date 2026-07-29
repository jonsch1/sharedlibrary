# Briefly production operations

## Launch configuration

- Apply every D1 migration before deploying the Worker.
- Keep `OPENROUTER_CREDENTIAL_KEY` stable; changing it makes saved provider
  credentials unreadable. Generate it with `openssl rand -hex 32` for a new
  deployment.
- Keep `PAID_PROCESSING_ENABLED=true` for normal operation. Set it to `false`
  to stop new transcription, voice, and Firecrawl jobs immediately.
- Configure PostHog, if used, with the EU ingestion host, a maximum 12-month
  event retention, no session replay, and no autocapture. Briefly starts it only
  after explicit consent.
- Configure a Modal workspace hard budget and alert. Start with the maximum
  amount Briefly can safely lose in one month; review it only after observing
  real usage.
- Keep Whisper at three containers and Kokoro at one until queue telemetry
  demonstrates a user-visible need.
- Alert when Firecrawl reaches 80% of the purchased monthly credit pool.

## Alerts and daily checks

- Cloudflare Worker: elevated 5xx rate, p95 latency, D1 errors, and R2 failures.
- Stripe: failed webhook delivery, payment failures, and subscription state
  that differs from the daily reconciliation result.
- Modal: budget thresholds, GPU container count, job failures, and queue time.
- Firecrawl: remaining credits and upstream error rate.
- Synthetic checks: landing page, authentication status, one public share,
  billing status, and a signed-in library request.

Every production error response has an `X-Request-ID`; the Worker logs that ID,
method, path, and sanitized error message as one JSON object.

## Backups and recovery

- Confirm D1 Time Travel is enabled for the production database.
- Record the database and R2 bucket identifiers in the private operator
  inventory.
- Quarterly, restore D1 to a temporary database and verify account, billing,
  and share-link rows.
- Public R2 objects are rebuildable only while their source library content
  remains available. A D1 restore must therefore be paired with an R2 inventory
  check.
- Never use a restored billing row to grant access without reconciling its
  current Stripe subscription first.

## Account-erasure runbook

Until self-service erasure exists, requests go to `hello@readbriefly.fyi`.

1. Verify control of the account email using the active session or a reply from
   the same sign-in address. Record the request and statutory response deadline.
2. Ask whether the user also wants the Stripe subscription cancelled. Account
   erasure must not silently leave a renewing subscription.
3. Delete its `share_texts` and `share_links` rows. If legacy
   `share_audio_segments` remain, queue their `r2_key` values in
   `share_media_deletions`, delete the rows, and run the media-deletion cleanup.
4. Revoke the Google refresh token with Google when possible, then delete
   `google_drive_connections`, OAuth states, `sync_preferences`,
   `app_sessions`, `auth_identities`, feedback rows/upvotes, and legacy
   OpenRouter credential rows for the email.
5. Resolve the internal `billing_customers.account_id`, then delete its
   `service_leases`, `service_usage`, `managed_ai_usage`, and legacy TTS usage
   and credit rows that are not legally required.
6. Retain or pseudonymize billing, invoice, webhook, fraud, and tax records only
   to the extent required by German law. Confirm the exact retention treatment
   with the operator's tax/legal adviser before the first request.
7. Explain that local files, Google Drive files, and private CloudKit records
   are controlled by the user and are not deleted merely by erasing Briefly's
   server account.
8. Confirm completion to the requester and keep only the minimal compliance
   record needed to prove the request was handled.

## Release acceptance

Desktop release automation creates a draft release. Publish it only after:

- Apple and Google sign-in succeed.
- Stripe checkout, portal, cancellation, failed payment, and webhook replay
  have been checked in the matching environment.
- Two devices synchronize a creation, edit, deletion, and concurrent-edit
  conflict using both iCloud and Google Drive.
- A normal web page, YouTube video, podcast without a transcript, and PDF are
  captured.
- Live Whisper and Kokoro jobs succeed, quota errors are understandable, and
  `PAID_PROCESSING_ENABLED=false` stops new jobs.
- A share exposes summaries and its source link, never captured source text or
  narration, and disappears after revoke.
- macOS, Windows, Microsoft Store, and Linux artifacts install; signed update
  feeds work from the draft release.
- The account-erasure runbook has been rehearsed against a disposable account.
