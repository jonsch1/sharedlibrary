# Shared Library Mobile

Shared Library Mobile is a read-only iPhone and iPad companion for the macOS app. It reads the user's private `iCloud.com.sharedlibrary.app` CloudKit database, caches the last downloaded library locally, and synthesizes spoken audio on-device.

## Run

1. Open `SharedLibraryMobile.xcodeproj` in Xcode.
2. Select the Apple developer team that owns `iCloud.com.sharedlibrary.app`.
3. Run on an iPhone, iPad, or signed-in simulator using the same iCloud account as the Mac.
4. In the macOS app, open Settings → Mobile and choose **Publish Now**.

The target has the CloudKit, remote-notification, and background-audio entitlements. The CloudKit development schema is created by the first successful Mac publication; deploy that schema to production before distributing a release build.

## Data ownership

- Git workspaces remain authoritative.
- The Mac publishes personal captures and records shared with the current stable GitHub ID.
- The mobile app never modifies source content.
- CloudKit stores metadata and text assets only.
- Spoken audio and the listening queue remain on the device.
