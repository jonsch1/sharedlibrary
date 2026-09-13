# App Review notes

No sign-in is required. Briefly opens a local library and all reading and library
management features work while signed out. Sign in with Apple is optional and is
used only for Briefly account features such as publishing an unlisted share link.

## Review recording and devices

- Physical-device recording: [ADD LINK BEFORE SUBMISSION]
- iPhone tested: [ADD DEVICE AND OS BEFORE SUBMISSION]
- iPad tested: [ADD DEVICE AND OS BEFORE SUBMISSION]
- Mac tested: Apple silicon Mac on macOS 26.6.2

## Suggested review path

1. Launch Briefly and complete or skip the three onboarding screens.
2. If the library is empty, choose **Add sample items** on Mac. On iPhone or
   iPad, open the Library tab and choose **Sample items**. This adds five prepared
   items with several topics and concise, detailed, and original reading depths.
   It requires no account, network request, or AI configuration.
3. Open a sample item, switch between its reading depths, search the library,
   add a highlight, move an item to Trash, restore it, and permanently delete it.
4. On Mac, choose Capture. Import a PDF or text file, or paste text or a public
   link. The saved item appears in the Inbox while the Mac prepares it.
5. On iPhone or iPad, use Capture or the share extension to add a link, PDF, or
   text. The phone saves it as a pending Inbox item. It does not extract or
   summarize content. A Mac running Briefly processes it after iCloud sync.
6. A complete library export is available in Settings as either the SQLite
   database or a folder of Markdown files.
7. Optional account controls, including account deletion, are in Settings >
   Account. Account deletion removes the Briefly server account and its public
   shares. It does not delete the user's private local or iCloud library.

## Purpose and audience

Briefly is a personal reading library for people who save articles, PDFs, notes,
and other material and want to return to it without a feed. The Mac imports and
prepares material. The iPhone and iPad apps focus on reading the synced library
and can optionally send new material to the Mac's pending queue.

## External services

- iCloud/CloudKit syncs the user's private library between their Apple devices.
- Sign in with Apple is optional for Briefly account features.
- On Mac, users may configure their own OpenRouter API key or a supported local
  AI command to create summaries. No AI service is required to review the sample
  library or use the reader and library controls.
- Public share links are user initiated and unlisted. There is no public feed,
  social graph, messaging, advertising, or tracking.

The app has the same functionality in every region. It is not for a regulated
industry and does not ship protected third-party material. The five sample items
are original Briefly fixtures.

## In-app purchases

This build does not expose or sell an in-app purchase or subscription. Do not
include the existing subscription records in the review submission.
