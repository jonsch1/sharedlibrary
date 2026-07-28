import assert from "node:assert/strict";
import test from "node:test";

import { scrapeWithFirecrawl } from "./firecrawl.mjs";

test("Briefly's Worker returns Firecrawl Markdown without exposing its key", async () => {
  let request;
  const result = await scrapeWithFirecrawl("https://example.com/article", {
    endpoint: "https://www.readbriefly.fyi/api/extraction/firecrawl",
    token: "session-token",
    fetchImpl: async (url, options) => {
      request = { url, options };
      return response({
        success: true,
        data: {
          markdown: "# Recovered article\n\nUseful content.",
          metadata: {
            title: "Recovered article",
            sourceURL: "https://example.com/article"
          }
        }
      });
    }
  });

  assert.equal(
    request.url,
    "https://www.readbriefly.fyi/api/extraction/firecrawl"
  );
  assert.equal(
    request.options.headers.Cookie,
    "shared_library_session=session-token"
  );
  assert.equal(request.options.headers.Authorization, undefined);
  assert.deepEqual(JSON.parse(request.options.body), {
    url: "https://example.com/article"
  });
  assert.equal(result.title, "Recovered article");
  assert.match(result.content, /Useful content/);

  await assert.rejects(
    scrapeWithFirecrawl("https://example.com/blocked", {
      endpoint: "https://www.readbriefly.fyi/api/extraction/firecrawl",
      token: "session-token",
      fetchImpl: async () =>
        response({
          success: true,
          data: {
            markdown: "Checking your browser before continuing. reCAPTCHA.",
            metadata: { title: "Checking your browser - reCAPTCHA" }
          }
        })
    }),
    /access or error interstitial/
  );
});

function response(body) {
  return {
    ok: true,
    status: 200,
    statusText: "OK",
    json: async () => body
  };
}
