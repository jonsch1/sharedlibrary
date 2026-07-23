# Shared Library Web

The mobile Shared Library client is a private SvelteKit reader hosted with OpenAI
Sites. Google Drive supplies a lightweight file index, mirrored Markdown documents,
and generated audio. IndexedDB keeps the index and downloaded documents available
offline, and narration is cached locally.

## Google Drive

Enable the Google Drive API and create one Web application OAuth client. Configure
its Client ID and Client Secret once for the deployment, then register
`https://<production-origin>/api/google/connect/callback` as an authorized redirect
URI. Each user connects their own Google account.

The backend encrypts account tokens and requests only `drive.file`. It can therefore
access only files Shared Library creates or that the user explicitly opens with it,
not the rest of the user's Drive. The app mirrors `library/` and `topics.md`, stores a
rebuildable metadata-only index under `.shared-library/`, and keeps content-addressed
audio under `audio/` in a visible `Shared Library` folder. It reuses an existing
`Shared Library Media` folder during migration.

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
npm run build:sites
```

Database definitions live in `db/schema.ts`; generated migrations live in
`drizzle/`. The worker also creates missing active tables defensively.

The deployment needs:

- a D1 binding named `DB`;
- an `OPENROUTER_CREDENTIAL_KEY` secret containing 32 random bytes encoded as
  64 hexadecimal characters;
- `GOOGLE_DRIVE_WEB_CLIENT_ID` and a `GOOGLE_DRIVE_WEB_CLIENT_SECRET` secret;
- Sites authentication enabled so every credential row is scoped to
  `oai-authenticated-user-email`.
