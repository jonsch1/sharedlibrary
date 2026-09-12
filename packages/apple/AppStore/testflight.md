# TestFlight setup

## Beta app information

- Beta app description: Briefly turns articles, videos, podcasts, papers, and
  notes into a calm, searchable library. Save from the app or share extension,
  choose a reading depth, listen to generated audio, and keep your library in
  sync across Apple devices.
- Feedback email: `hello@readbriefly.fyi`
- Privacy policy: `https://www.readbriefly.fyi/privacy`

## What to test

Save a web page with the share extension and directly in Briefly. Confirm that
it appears in the library and finishes processing. Open the result at multiple
reading depths, search for it, and try audio playback. If you use more than one
device, confirm that the item and its attachments synchronize. Also try one
channel and report confusing states, failed captures, missing content, sync
problems, audio issues, or crashes through TestFlight feedback.

Do not use irreplaceable source material as the only copy during beta testing.

## Suggested groups

- `Internal`: App Store Connect users. Use this first because internal builds
  do not need TestFlight App Review.
- `Early Access`: invited external testers. The first external build must pass
  TestFlight App Review before testing can begin.

Do not enable a public invitation link until the private external group has
been tested and its capacity and eligibility criteria have been chosen.

## Repository release command

From `packages/apple/`, choose a build number that has not already been uploaded for the
current marketing version. First create and verify the archive without sending
anything to Apple:

```bash
BUILD_NUMBER=<number> ./scripts/testflight.sh archive
```

Next, prove that Xcode can re-sign that archive for App Store distribution and
produce an IPA without uploading it:

```bash
BUILD_NUMBER=<number> ./scripts/testflight.sh export
```

Then upload that exact archive:

```bash
BUILD_NUMBER=<number> ./scripts/testflight.sh upload
```

The latest uploaded beta is build `8` for version `1.0`.

The export and upload actions refuse to rebuild or replace the archive, ensuring
the artifact inspected locally is the one sent to Apple. They use Xcode's
signed-in Apple account and automatic signing by default. For unattended use,
set `ASC_KEY_PATH`, `ASC_KEY_ID`, and `ASC_ISSUER_ID` to an App Store Connect API
key with appropriate access. Never store the `.p8` key in this repository.

Artifacts and Derived Data are retained under `packages/apple/.build/testflight/`, which
is ignored by Git. Keep the `.xcarchive` for every build distributed to testers
so its debug symbols remain available for crash investigation.

## App Store Connect steps after processing

1. Open **ReadBriefly > TestFlight** and select the processed iOS build.
2. Confirm export compliance. The project declares
   `ITSAppUsesNonExemptEncryption = NO`; the owner remains responsible for the
   final attestation.
3. Add the build to `Internal`, select the App Store Connect users who should
   test, and install it through the TestFlight app.
4. After an internal smoke test, create `Early Access`, add the beta information
   above, attach the build, and submit it for TestFlight App Review.
5. Once approved, invite external testers by email. TestFlight builds expire
   after 90 days, so upload a new build before the active one expires.
