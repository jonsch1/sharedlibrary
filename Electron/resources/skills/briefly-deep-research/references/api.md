# Briefly agent API

The desktop app binds an ephemeral HTTP server to `127.0.0.1` and writes its
connection details to `.shared-library/agent-api.json` in the selected
workspace. Every request requires:

```text
Authorization: Bearer <token>
```

The connection file is local-only, mode `0600` on POSIX, and is not included in
Google Drive synchronization.

## Endpoints

### `GET /v1/status`

Check whether the desktop app and agent API are ready.

### `GET /v1/topics`

List `{id, title}` topic definitions.

### `POST /v1/topics`

Create a topic or return the case-insensitive existing match.

```json
{"title": "Battery Recycling"}
```

### `POST /v1/topics/:topicID/sources`

Start asynchronous extraction and summarization for up to 24 approved HTTP(S)
URLs. The API rejects the request unless `approved` is exactly `true`.

```json
{
  "approved": true,
  "urls": ["https://example.com/report"]
}
```

Returns `202` with a job. Source states are `queued`, `extracting`,
`summarizing`, `completed`, `skipped`, or `failed`.

### `GET /v1/jobs/:jobID`

Read current job and per-source status. A completed job may contain individual
failures; inspect `counts` and `sources`.

### `GET /v1/topics/:topicID/items?variant=detailed`

Return topic items plus the requested `brief`, `concise`, `detailed`,
`comprehensive`, or `source` text. Items without that variant return `text:
null` and a status of `processing`, `failed`, or `source-only`.

## Errors

Errors use:

```json
{
  "error": {
    "code": "approval_required",
    "message": "..."
  }
}
```

Treat `401` as a stale or wrong connection file and `409 approval_required` as
a hard stop requiring user approval.
