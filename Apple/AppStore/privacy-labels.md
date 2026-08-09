# App Privacy answers

Use the final privacy report from the archive as the last check. Based on the
current native app and published Privacy Policy, select **Yes, we collect data**,
then declare the following. None is used for tracking or advertising.

| Data type | Purposes | Linked to user | Tracking |
| --- | --- | --- | --- |
| Contact Info > Email Address | App Functionality | Yes | No |
| Purchases > Purchase History | App Functionality | Yes | No |
| Identifiers > User ID | App Functionality | Yes | No |
| User Content > Other User Content | App Functionality; Product Personalization | Yes | No |
| Browsing History | App Functionality | Yes | No |
| Other Data | App Functionality | Yes | No |

Why these are included:

- Sign in with Apple supplies the account email and provider identifier.
- The server associates App Store product/transaction status with the account.
- Connected processing can receive user-selected source text, prompts, topics,
  and URLs. Public shares retain selected summaries, metadata, and source URLs
  until revoked.
- Account-scoped service usage counters and short-lived concurrency leases enforce
  membership allowances and prevent abuse.

Do not declare the following unless the finished archive or implementation changes:

- Tracking, advertising, precise/coarse location, contacts, health, payment-card
  data, crash data, or native-app analytics.
- Private CloudKit data collected by Apple. Apple says developers aren't
  responsible for disclosing data Apple collects through its frameworks.
- Material processed only on-device.
- Request inputs that the developer and processors keep only for the time needed
  to service that request. Apple does not treat this as collection for the label.

Public URLs:

- Privacy Policy: https://www.readbriefly.fyi/privacy
- Privacy Choices: leave blank unless a native privacy-choice page is added.

