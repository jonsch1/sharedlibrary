# Shared Library Web

The mobile Shared Library client is a private SvelteKit reader hosted with OpenAI
Sites. It syncs text from a user-selected GitHub repository, keeps the most recent
library projection in IndexedDB, and caches generated speech locally. Google Drive is
the durable media store.

## Connections

### GitHub

Create and install a GitHub App with Device Flow enabled. Give it repository
Contents read/write and Metadata read permissions, then enter its public Client ID in
the Connections panel. The backend completes Device Flow, encrypts the user token, and
fetches `.shared-library/library.json` through the GitHub API.

The app never accepts or stores the GitHub App PEM private key.

### Google Drive

Enable the Google Drive API and create a Web application OAuth client. Enter the
Client ID and Client Secret in Connections, then register the exact callback URL shown
by the app as an authorized redirect URI. The backend encrypts the client secret and
tokens. It requests the narrow `drive.file` scope and stores content-addressed objects
under a visible `Shared Library Media` folder.

### OpenRouter

OpenRouter OAuth is optional and account-scoped. Its key is encrypted in D1 and used
only by the server-side speech route. Audio playback waits for a complete MP3 response,
then starts immediately from the local blob. New segments are cached in the browser
and copied to Google Drive in the background.

## Development

```bash
npm install
npm run check
npm run test:worker
npm run db:generate
npm run build:sites
```

Database definitions live in `db/schema.ts`; generated migrations live in `drizzle/`.
The worker creates missing tables defensively during requests as well.

The deployment needs:

- a D1 binding named `DB`;
- an `OPENROUTER_CREDENTIAL_KEY` secret containing 32 random bytes encoded as
  64 hexadecimal characters;
- Sites authentication enabled so every credential row is scoped to
  `oai-authenticated-user-email`.
