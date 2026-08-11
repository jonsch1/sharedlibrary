# App Review notes

ReadBriefly has a hard membership paywall after onboarding. A Briefly account and
active monthly membership are required to enter the library. Customers create the
account with Sign in with Apple and purchase the membership through StoreKit.

The username and password in App Store Connect's App Review Information grant a
review-only, complimentary Plus session. They do not change the Apple Account on
the review device and do not create or simulate an App Store transaction. The
production backend is live and the credentials do not expire during review.

## Suggested review path

1. Launch Briefly and complete or skip onboarding.
2. On the membership screen, choose **App Review access**.
3. Enter the username and password from App Store Connect's App Review
   Information. The app opens an editable sample library with five prepared
   items, three topics, multiple summary depths, tags, and a sample channel.
4. Use the capture action to add a note or public URL, open the saved item, and
   move between summary depths.
5. Capture supported audio or video material to test transcription and voice
   generation, and create a public share from the reader.
6. Account deletion is in Settings > Account. For the review account it deletes
   the server-side account and session data. The sample library is stored only in
   a separate local review database and never syncs into the reviewer's iCloud
   library.

## Sign in with Apple and StoreKit path

To test the customer purchase flow, sign out from Settings > Account. On the
membership screen, use Sign in with Apple with the Apple Account configured on
the review device. The screen then presents the submitted StoreKit product's
localized price and monthly renewal period, Subscribe action, Restore Purchases,
Terms, and Privacy. A verified StoreKit transaction activates the membership.

The subscription product ID is `fyi.readbriefly.plus.monthly`. It provides ongoing
access to the native app, hosted AI processing, web extraction fallback,
transcription, voice generation, usage allowances, private iCloud synchronization,
and public share links. The app contains no external purchase flow and no
advertising or tracking.

The app includes a user-directed embedded browser for capturing authenticated or
otherwise user-selected web sources, so Unrestricted Web Access is declared in
the age-rating questionnaire. Public share links are unlisted and user-initiated;
there is no in-app public feed, social graph, messaging, or discovery of other
users' content.

The library remains on the device and in the user's private CloudKit container.
If membership ends, access pauses but those files are not deleted. When a user
deliberately requests connected processing, only the material needed for that
request is sent to the providers described in the Privacy Policy.

App Review contact information is saved for both iOS and macOS using
`hello@readbriefly.fyi` and the owner's supplied phone number.
