import assert from "node:assert/strict";
import test from "node:test";

import {
  extractGenericHTML,
  extractGenericHTMLFromSource
} from "./generic-html.mjs";

test("generic HTML extraction uses page metadata and readable article text", () => {
  const result = extractGenericHTMLFromSource(
    "https://example.com/posts/reliable-inputs",
    `<!doctype html>
      <html>
        <head>
          <title>Fallback title</title>
          <meta property="og:title" content="Reliable inputs">
          <meta property="og:description" content="A useful extraction example.">
          <meta property="og:site_name" content="Example">
          <link rel="canonical" href="/canonical/reliable-inputs">
        </head>
        <body>
          <nav>Unrelated navigation</nav>
          <article>
            <h1>Reliable inputs</h1>
            <p>${"A deliberate input pipeline keeps fetching and extraction behavior understandable. ".repeat(6)}</p>
          </article>
        </body>
      </html>`
  );

  assert.equal(result.url, "https://example.com/posts/reliable-inputs");
  assert.equal(
    result.canonicalURL,
    "https://example.com/canonical/reliable-inputs"
  );
  assert.equal(result.title, "Reliable inputs");
  assert.equal(result.description, "A useful extraction example.");
  assert.equal(result.siteName, "Example");
  assert.match(result.content, /deliberate input pipeline/);
  assert.doesNotMatch(result.content, /Unrelated navigation/);
});

test("generic HTML extraction rejects binary responses", async () => {
  await assert.rejects(
    extractGenericHTML("https://example.com/report.pdf", {
      fetchImpl: async () => response("%PDF-1.7", {
        contentType: "application/pdf"
      })
    }),
    /Unsupported link content type: application\/pdf/
  );
});

function response(body, { contentType = "text/html", url = "https://example.com/" } = {}) {
  return {
    ok: true,
    status: 200,
    statusText: "OK",
    url,
    headers: new Headers({ "content-type": contentType }),
    text: async () => body
  };
}
