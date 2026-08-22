# App Review notes

ReadBriefly is a free TestFlight beta. There is no subscription screen or purchase
flow in this build. Sign in with Apple is optional for local library use.

## Suggested review path

1. Launch Briefly and complete or skip onboarding.
2. The app opens the local library after onboarding. The app contains an editable
   sample library with five prepared items, three topics, multiple summary depths,
   tags, and a sample channel when launched with the review configuration.
4. Use the capture action to add a note or public URL, open the saved item, and
   move between summary depths.
5. Capture supported audio or video material to test transcription and voice
   generation, and create a public share from the reader.
6. Account deletion is in Settings > Account. For the review account it deletes
   the server-side account and session data. The sample library is stored only in
   a separate local review database and never syncs into the reviewer's iCloud
   library.

## AI processing

On macOS, open Settings > AI processing. Reviewers may leave the OpenRouter API key
blank and use a locally installed provider CLI, or enter their own OpenRouter API
key. iOS captures and stores items without AI processing in this beta.

The app contains no purchase flow and no advertising or tracking.

The app includes a user-directed embedded browser for capturing authenticated or
otherwise user-selected web sources, so Unrestricted Web Access is declared in
the age-rating questionnaire. Public share links are unlisted and user-initiated;
there is no in-app public feed, social graph, messaging, or discovery of other
users' content.

The library remains on the device and in the user's private CloudKit container.
When a user deliberately requests connected processing on macOS, only the
material needed for that request is sent to the provider they configured, as
described in the Privacy Policy.

App Review contact information is saved for both iOS and macOS using
`hello@readbriefly.fyi` and the owner's supplied phone number.
