# Briefly Sharing

## Principle

Private synchronization and deliberate sharing are separate systems.

- iCloud contains each user's complete private library and generated audio.
- The sharing service contains only documents the owner explicitly publishes.
- A share is a hard-to-guess capability URL. Anyone who receives or forwards the
  URL can open it; possession of the URL is the authorization boundary.
- No group Drive folder, people directory, recipient tags, or shared Inbox is
  required.

## Storage model

D1 stores one current record for each published capture:

- owner account and private capture ID;
- a random 192-bit URL token;
- revision, publication status, and timestamps;
- title, excerpt, topics, tags, and source metadata;
- every available summary variant: brief, concise, detailed, and comprehensive.

Captured original text and narration remain in the user's private library. Public
shares include the source URL when one is available, but do not copy either form
to Briefly's sharing storage.

The public response exposes neither the owner's email nor private provider record
IDs. Authentication credentials and provider tokens never enter D1, R2, or the
public document payload.

## Lifecycle

1. The owner selects **Share** in the Mac or iOS app.
2. The native app sends only the selected summary variants and creates or reuses
   the capture's stable capability URL.
4. **Update link** creates a new atomic generation while keeping the URL stable.
5. **Stop sharing** deletes the D1 record and text variants, making the link unavailable.

The link UI is optimistic: it returns immediately with a preparing state and updates
as the background publication completes.

## Recipient experience

The public reader works without an account, provides the summary conciseness
selector, and links back to the original source.

## Security properties

Tokens use 24 cryptographically random bytes encoded as 32 URL-safe characters.
They are designed to be unguessable, not private after forwarding. Public share
responses disable shared caching, and mutations require an authenticated account
plus same-origin requests.

Anyone with a link can read and forward the published document until the owner
revokes it. Content requiring recipient identity checks would need a different,
access-controlled sharing mode.
