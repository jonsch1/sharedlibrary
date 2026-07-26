# Briefly workspace input API v1

## Package layout

```text
.briefly/inputs/example-site/
  input.json
  input.mjs
  input.test.mjs
  fixtures/
```

Briefly rescans this directory for every extraction. Packages are local to the
workspace and are not included in the Google Drive library mirror.

## Manifest

`input.json` is declarative so Briefly can route a URL without executing
extension code.

```json
{
  "apiVersion": 1,
  "id": "example-site",
  "sourceType": "article",
  "priority": 100,
  "match": {
    "hosts": ["news.example.com", "*.journal.example"],
    "pathPrefixes": ["/articles/"]
  },
  "entry": "input.mjs",
  "fallback": "builtin"
}
```

- `apiVersion` must be `1`.
- `id` and `sourceType` use lowercase letters, numbers, and single hyphens.
- `priority` is an integer from `-1000` to `1000`; higher workspace inputs win.
- `match.hosts` accepts exact hosts and `*.` subdomain wildcards.
- `match.pathPrefixes` is optional. An empty list matches every path.
- `entry` defaults to `input.mjs` and must remain inside the package.
- `fallback` is `builtin` or `none`. Prefer `builtin` while developing.

Matching workspace inputs run before built-in inputs and the generic HTML
extractor.

## Module

Default-export an object containing `extract`:

```js
export default {
  async extract(request, briefly) {
    const response = await briefly.fetch(request.url);
    const data = await response.json();

    return {
      sourceURL: request.url.href,
      title: data.title,
      description: data.description,
      siteName: "Example",
      content: data.body
    };
  }
};
```

`request` contains:

- `url`: a `URL` instance.
- `options.transcriptTimestamps`: whether timed transcript text was requested.
- `signal`: aborted near the extension execution deadline.

`briefly` contains:

- `apiVersion`: `1`.
- `fetch(url, init?)`: buffered HTTP(S) fetch with redirect handling, a
  20 MB response limit, and a 30-second default timeout. The returned object
  provides `ok`, `status`, `statusText`, `url`, `headers`, `text()`, and
  `json()`. `init.timeoutMilliseconds` may be at most 120 seconds.
- `fetchText(url, init?)`: shorthand returning the response body as text.
- `extractHTML({url, html})`: Briefly metadata, JSON-LD, Readability, and
  sanitized-text extraction.
- `log(message)`: writes an extraction diagnostic without corrupting the result.

Global `fetch` is replaced with the same bounded implementation.

## Result

Return a JSON-serializable object:

```js
{
  sourceURL: "https://news.example.com/articles/42",
  title: "An optional title",
  description: "Optional source description",
  siteName: "Optional site name",
  content: "Required non-empty source content",
  metadata: {
    author: "Optional extension-specific JSON metadata"
  }
}
```

`sourceURL` must be HTTP(S). Briefly adds `extractor`, `sourceType`,
`totalCharacters`, and `wordCount`. Unknown JSON fields are retained, but
extensions should keep large or private data out of results.

## Isolation

The selected module runs in a separate process with a scrubbed environment.
It can read its own package and the bundled input runtime. Filesystem writes,
child processes, workers, and reads elsewhere are denied. Network access is
available because extraction requires it.

Do not depend on npm packages outside the extension directory. Prefer the
provided API and pure JavaScript helpers stored inside the package.
