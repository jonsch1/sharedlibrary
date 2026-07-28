import assert from "node:assert/strict";
import test from "node:test";

import { scrapeWithFirecrawl } from "./firecrawl.mjs";

test("Firecrawl sends the v2 scrape contract and returns Markdown", async () => {
  let request;
  const result = await scrapeWithFirecrawl("https://example.com/article", {
    apiKey: "test-key",
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

  assert.equal(request.url, "https://api.firecrawl.dev/v2/scrape");
  assert.equal(request.options.headers.Authorization, "Bearer test-key");
  assert.deepEqual(JSON.parse(request.options.body).formats, ["markdown"]);
  assert.equal(result.title, "Recovered article");
  assert.match(result.content, /Useful content/);

  await assert.rejects(
    scrapeWithFirecrawl("https://example.com/blocked", {
      apiKey: "test-key",
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
