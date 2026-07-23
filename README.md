# Shared Library Web

Shared Library Web is a private, installable SvelteKit reader for the JSON snapshot exported by the Shared Library macOS app. It uses shadcn-svelte components, optional OpenRouter narration, and browser-native speech synthesis as an offline fallback.

## Data flow

1. The Mac app builds a unified projection of the personal library and captures shared with the configured stable GitHub ID.
2. It writes `Shared Library Web.json` to the iCloud Drive folder configured under Settings → Mobile.
3. The web app imports that file through the browser's Files picker.
4. The validated snapshot is stored in IndexedDB for offline reading.

The hosted web app contains no personal library content. Re-import the snapshot to pick up a newer iCloud Drive copy.

## Narration

Audio settings connect the signed-in Shared Library user to OpenRouter through its OAuth PKCE flow. The user-controlled API key is encrypted with AES-GCM and stored in the site's private D1 database, allowing the connection to survive Safari-to-Home-Screen handoffs on iOS without exposing the key to browser JavaScript. It is never added to the library snapshot, iCloud Drive, or Git.

Narration uses `x-ai/grok-voice-tts-1.0` and progressively plays MP3 output as it arrives through a same-origin server endpoint. The service worker keeps the completed stream in the browser Cache API for later replay. Disconnecting removes the encrypted credential for the signed-in user; clearing the device-local audio cache is a separate action.

When OpenRouter is not connected or the device is offline, the reader falls back to browser-native speech synthesis. Text is sent to OpenRouter and xAI only when the user requests narration.

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
