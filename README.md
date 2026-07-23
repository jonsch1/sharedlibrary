# Shared Library Web

Shared Library Web is a private, installable SvelteKit reader for the JSON snapshot exported by the Shared Library macOS app. It uses shadcn-svelte components and browser-native speech synthesis.

## Data flow

1. The Mac app builds a unified projection of the personal library and captures shared with the configured stable GitHub ID.
2. It writes `Shared Library Web.json` to the iCloud Drive folder configured under Settings → Mobile.
3. The web app imports that file through the browser's Files picker.
4. The validated snapshot is stored in IndexedDB for offline reading.

The hosted web app contains no personal library content. Re-import the snapshot to pick up a newer iCloud Drive copy.

## Development

```bash
npm install
npm run dev
```

Validation and production build:

```bash
npm run check
npm run build
```

The static output is written to `build/`.
