# Briefly TypeScript SDK

Use custom TypeScript or JavaScript parsers to capture resources into Briefly.
The first matching adapter extracts the content; otherwise Briefly performs
native ingestion. Source handling runs in your Node.js process, and Briefly
continues to own saving, duplicate handling, summaries, and synchronization.

## Install locally

The SDK runs on Node.js 22.18+ with the macOS Briefly app. Repository development
requires Node.js 24+. This package is not yet published to npm. From the
repository root:

```sh
npm ci
npm run build --workspace @readbriefly/sdk
```

Then, from your script's project, install this directory using its absolute path:

```sh
npm install /path/to/sharedlibrary/packages/sdk
```

Use ESM (`.mjs`, or `"type": "module"` in your project's package.json). Open
Briefly before making API calls. The SDK locates the installed app and connects
to its bundled MCP helper; it does not launch the app. No LLM or API key is
required to call the SDK. Briefly's own summary processing uses the user's
existing processing configuration.

## Basic usage

```ts
import { Briefly } from "@readbriefly/sdk";

const briefly = new Briefly();
try {
  const result = await briefly.ingest("https://example.com/article");
  console.log(result.id, result.status);

  // Supply source content from any parser, file reader, API, or agent.
  await briefly.save({
    title: "Research notes",
    content: "# Research notes\n\nThe original material to keep...",
  });
} finally {
  await briefly.close();
}
```

`save` never fetches its URL. An optional URL provides canonical identity:
saving it again replaces the existing source and supplied summaries. Summaries
omitted from that save are removed; if neither summary is supplied, Briefly
queues processing. Without a URL, each save creates a new document.

## Custom handling

```ts
import { Briefly, type SourceAdapter } from "@readbriefly/sdk";

const releaseNotes: SourceAdapter = {
  id: "personal.release-notes",
  matches: (url) => url.hostname === "updates.example.com"
    && url.pathname.startsWith("/releases/"),
  async extract(url) {
    // Replace this example with the source's actual acquisition and parsing.
    const response = await fetch(url, { signal: AbortSignal.timeout(20_000) });
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    const content = await response.text(); // This example assumes a plain-text source.
    return { title: "Release notes", content };
  },
};

const briefly = new Briefly({ adapters: [releaseNotes] });
try {
  console.log(await briefly.preview("https://updates.example.com/releases/latest"));
  // When ready to save, use await briefly.capture(theSameURL).
} finally {
  await briefly.close();
}
```

Adapters are ordinary objects with `id`, synchronous `matches(URL)`, and
`extract(URL)`. Add parsing libraries in your own project as needed. Adapter
order is precedence. Capture uses native `ingest` only when no adapter matches;
a failing custom adapter produces `adapter_failed` and never silently falls
back. Call `ingest` explicitly to choose native handling.

An adapter returns `SaveInput`: required `title` (up to 200 characters), required
source `content` (500,000), optional `url` (2,048), optional `concise` (100,000),
and optional `detailed` (500,000). Capture defaults an omitted URL to the input
URL, so repeated custom captures update the same document. Return a canonical
URL explicitly when the source has several URLs for the same item. Embedded
URL credentials and unrecognized document fields are rejected.

Behavior such as selecting replies, combining pages, filtering records, or
creating specialized summaries belongs in your adapter or surrounding script.
There are no arbitrary app hooks, tags, attachments, channel registration, or
per-document processing instructions in this initial API.

## Preview and example

`preview(url)` requires no Briefly installation or connection. For a custom
adapter it returns `{ kind: "custom", adapterId, url, document }`. Extraction
still runs and can make network requests. For native handling it returns
`{ kind: "native", url }`, describing the route without fetching or saving.
`capture` extracts afresh; to save exactly a custom preview, call
`save(preview.document)`.

The runnable example reads a public GitHub issue using the
[GitHub REST API](https://docs.github.com/en/rest/issues/issues#get-an-issue).
From this package after building:

```sh
node examples/github-issue.ts https://github.com/octocat/Hello-World/issues/1
# Add --save to capture after reviewing the preview, with Briefly open:
node examples/github-issue.ts https://github.com/octocat/Hello-World/issues/1 --save
```

Copy the example into your project to extend it. It uses unauthenticated GitHub
requests, subject to GitHub's public rate limit. Custom handlers run with the
script's normal permissions and own their authentication. Briefly's signed-in
browser cookies are not available to external handlers. See [AGENTS.md](AGENTS.md)
for the adapter-authoring workflow.

## API and errors

| Method | Behavior |
| --- | --- |
| `capture(url)` | Custom extraction and save, or native ingestion |
| `preview(url)` | Extract a custom preview, or describe native routing |
| `ingest(url)` | Always use Briefly's native extraction |
| `save(document)` | Save supplied source content and optional summaries |
| `search({ q?, limit? })` | Search summaries, or list recent items; limit 1–10 |
| `read({ id, detail?, cursor? })` | Read a summary; pass returned `next` as `cursor` |
| `close()` | Release the helper process; the client cannot be reused |

Construction does no I/O. The first API operation connects lazily over MCP
stdio. An optional absolute `helperPath` selects an app or development helper.
`requestTimeoutMs` defaults to five minutes for API requests; initialization
has a separate 15-second deadline. Adapter request deadlines are owned by the
adapter, as in the example.

Writes return `{ id, status: "ready" | "processing" }`. `processing` means
the document is saved but has no summary. The current app API does not expose
whether a summary job is active or failed, so the SDK does not offer an
automatic wait-until-ready operation. Reads paginate at 12,000 characters.

Failures throw `BrieflyError` with a `code` and `message`. Native errors such as
`library_unavailable` and `not_found` are preserved. SDK errors include
`invalid_input`, `adapter_failed`, `app_not_found`, `helper_not_found`,
`unsupported_platform`, `connection_failed`, `request_timeout`, `request_failed`,
`invalid_response`, and `client_closed`. An adapter's underlying exception is
available as `cause`. Transport failures can leave write completion uncertain;
inspect the library before retrying. The SDK never retries writes automatically.

This SDK supports external capture workflows on a Mac with Briefly open. It
does not install handlers into Briefly's capture UI or the iPhone share sheet.
Saved documents reach other devices through Briefly's existing sync.

## Develop and package

```sh
# From the repository root:
npm ci
swift build --package-path packages/mcp --product briefly-mcp
npm run check --workspace @readbriefly/sdk
npm test --workspace @readbriefly/sdk
npm pack --workspace @readbriefly/sdk
```

Tests use the real Swift MCP executable against disposable SQLite libraries,
plus a local HTTP source. They never touch the user's library. Set
`BRIEFLY_MCP_HELPER` to an absolute helper path if it is not at the repo's default
Swift build location. The integration suite requires macOS and `sqlite3`.

`npm pack` creates `readbriefly-sdk-0.1.0.tgz` containing compiled JavaScript,
TypeScript declarations, examples, and agent instructions. Install that archive
in another project with `npm install /path/to/readbriefly-sdk-0.1.0.tgz`.
