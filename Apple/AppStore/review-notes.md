# App Review notes

ReadBriefly is local-first. Sign-in is not required to launch the app, capture local
material, or browse the local library. Sign in with Apple is the only account
mechanism and is used for connected services and the ReadBriefly membership; no
separate demo username or password is required.

## Suggested review path

1. Launch Briefly and use the capture action to add a note or a public URL.
2. Open the saved item and use the reading-depth control to move between summary
   lengths.
3. Open Settings > Account and choose Sign in with Apple.
4. Choose Explore Briefly Plus. The subscription screen presents the localized
   App Store price and monthly renewal period, with Restore Purchases, Terms, and
   Privacy kept visible.
5. With an active membership, capture an item to test managed processing,
   transcription, voice generation, and public-share creation.
6. Account deletion is in Settings > Account in the finished review build. It
   explains that App Store subscriptions must be cancelled separately and asks
   for confirmation before deleting server-side account data and revoking Sign in
   with Apple authorization.

The subscription product ID is `fyi.readbriefly.plus.monthly`. It provides ongoing
hosted AI processing, web extraction fallback, transcription, voice generation,
usage allowances, and public share links. The app contains no external purchase
flow and no advertising or tracking.

The app includes a user-directed embedded browser for capturing authenticated or
otherwise user-selected web sources, so Unrestricted Web Access is declared in
the age-rating questionnaire. Public share links are unlisted and user-initiated;
there is no in-app public feed, social graph, messaging, or discovery of other
users' content.

The library remains on the device and in the user's private CloudKit container.
When a user deliberately requests connected processing, only the material needed
for that request is sent to the providers described in the Privacy Policy.

App Review contact information is saved for both iOS and macOS using
`hello@readbriefly.fyi` and the owner's supplied phone number.
