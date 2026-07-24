# Briefly Sharing

## Principle

Private synchronization and deliberate sharing are separate systems.

- Google Drive contains each user's complete private library and generated audio.
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
- every available Markdown variant: brief, concise, detailed, comprehensive, and
  original.

R2 stores only complete narration segment sets that already existed when the owner
published or updated the link. Audio remains content-addressed in each user's
private Drive, while the shared R2 keys are scoped by token and publication
generation.

The public response exposes neither the owner's email nor their Google Drive file
IDs. Authentication credentials and Drive tokens never enter D1, R2, or the public
document payload.

## Lifecycle

1. The owner selects **Share** in the Mac or web app.
2. The web app immediately creates or reuses the capture's stable capability URL.
3. In the background, the worker reads the synchronized personal Drive copy,
   publishes the Markdown variants, and copies only complete existing narration.
4. **Update link** creates a new atomic generation while keeping the URL stable.
5. **Stop sharing** deletes the D1 record, text variants, and corresponding R2
   objects, making the link unavailable.

The link UI is optimistic: it returns immediately with a preparing state and updates
as the background publication completes.

## Recipient experience

The public reader works without an account and provides the same conciseness
selector as the personal library. If published audio exists, it plays those
segments; otherwise the reader may use device speech without persisting it.

**Add to my library** requires the recipient to sign in and connect their personal
Google Drive. It creates an independent capture with a new capture ID, writes the
source and summaries into the recipient's normal `library/` structure, and copies
published narration into the recipient's private Drive audio store. Later updates
or revocation of the share do not change an already imported personal copy.

## Security properties

Tokens use 24 cryptographically random bytes encoded as 32 URL-safe characters.
They are designed to be unguessable, not private after forwarding. Public share
responses disable shared caching, and mutations require an authenticated account
plus same-origin requests.

Anyone with a link can read and forward the published document until the owner
revokes it. Content requiring recipient identity checks would need a different,
access-controlled sharing mode.
