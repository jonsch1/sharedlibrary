# Compliance answers

## Age rating

Use the current questionnaire and answer conservatively:

- Parental controls: No
- Age assurance: No
- Unrestricted web access: Yes
- User-generated content: No (shares are unlisted and there is no broad in-app
  distribution or discovery)
- Social media: No
- Messaging and chat: No
- Advertising: No
- Every content-frequency descriptor: None, unless the finished app ships its own
  editorial content in one of those categories

Expected result: 16+ on Apple OS version 26 storefronts and 17+ on earlier OS
versions because the app contains a user-directed embedded browser.

## Export compliance

The current code uses ordinary HTTPS/TLS supplied by Apple's operating systems
and SHA-256 hashing for the Sign in with Apple nonce. No proprietary or
non-standard encryption was found. The likely App Store Connect result is exempt
encryption with no documentation required, and the finished target should set:

`ITSAppUsesNonExemptEncryption = NO`

This remains an owner legal attestation. If the finished app adds its own crypto
implementation, VPN, secure communications product, or non-standard algorithm,
re-run the export questionnaire rather than using this default.

## Content rights

Briefly accesses third-party articles, feeds, videos, podcasts, and social posts at
the user's direction. Answer that the app accesses third-party content, then the
owner must attest that the app is permitted to do so in the selected storefronts.
The public Terms already require users to respect copyright, paywalls, privacy,
and source terms, but the App Store Connect attestation still belongs to the owner.

## DSA and storefront availability

For EU distribution, confirm trader status in App Store Connect. Only the owner
can make that legal attestation. Trader verification can make the supplied
address, phone, and email public on the App Store product page.

## Encryption and privacy-manifest build handoff

The finished archive should contain a valid privacy manifest and pass Xcode's
Generate Privacy Report check before upload. App Store Connect rejects invalid
manifests and required-reason API omissions.
