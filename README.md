# Shared Library Web

The mobile Shared Library client is a private SvelteKit reader hosted with OpenAI
Sites. It syncs text from a user-selected GitHub repository, keeps the most recent
library projection in IndexedDB, and caches generated speech locally. Google Drive is
the durable media store.

## Connections

### GitHub

Create and install one GitHub App with Device Flow enabled. Give it repository
Contents read/write and Metadata read permissions. Configure its public Client ID and
installation URL once for the deployment. Do not grant repository Administration
permission. Users create a private repository first, install the app with access only
to that repository, then click Connect and select it. Arbitrary repository names are
rejected. The backend completes Device Flow, encrypts the user token, and fetches
`.shared-library/library.json` through the GitHub API.

The app never accepts or stores the GitHub App PEM private key.

### Google Drive

Enable the Google Drive API and create one Web application OAuth client. Configure its
Client ID and Client Secret once for the deployment, then register
`https://<production-origin>/api/google/connect/callback` as an authorized redirect
URI. Each user connects their own Google account. The backend encrypts account tokens,
requests the narrow `drive.file` scope, and stores content-addressed audio under a
visible `Shared Library Media` folder in that user’s own Drive.

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
- `GITHUB_APP_CLIENT_ID` and `GITHUB_APP_INSTALL_URL` environment values;
- `GOOGLE_DRIVE_WEB_CLIENT_ID` and a `GOOGLE_DRIVE_WEB_CLIENT_SECRET` secret;
- Sites authentication enabled so every credential row is scoped to
  `oai-authenticated-user-email`.
