import assert from "node:assert/strict";
import test from "node:test";

import { extractLink, selectInput } from "./registry.mjs";

test("selectInput routes supported links to explicit modules", () => {
  assert.equal(selectInput("https://arxiv.org/abs/1706.03762")?.id, "arxiv");
  assert.equal(
    selectInput("https://www.youtube.com/watch?v=abc1234")?.id,
    "youtube"
  );
  assert.equal(
    selectInput("https://x.com/example/status/123")?.id,
    "x"
  );
  assert.equal(
    selectInput("https://bsky.app/profile/example.com/post/abc")?.id,
    "bluesky"
  );
  assert.equal(
    selectInput("https://www.threads.com/@example/post/abc")?.id,
    "threads"
  );
  assert.equal(
    selectInput("https://www.reddit.com/r/example/comments/abc123/a_post/")?.id,
    "reddit"
  );
  assert.equal(
    selectInput("https://www.tiktok.com/@example/video/123")?.id,
    "tiktok"
  );
  assert.equal(selectInput("https://example.com/article")?.id, "generic-html");
  assert.equal(selectInput("file:///tmp/report.html"), null);
});

test("Firecrawl replaces failed and blocked generic extraction", async () => {
  const fallback = async (url) => ({
    url,
    title: "Recovered article",
    content: "The complete article body recovered by Firecrawl."
  });
  const failed = await extractLink("https://example.com/forbidden", {
    fetchImpl: async () => response("Forbidden", 403),
    firecrawlFallback: fallback
  });
  const blocked = await extractLink("https://example.com/challenge", {
    fetchImpl: async () =>
      response("<title>Checking your browser - reCAPTCHA</title>"),
    firecrawlFallback: fallback
  });

  assert.equal(failed.extractor, "firecrawl");
  assert.equal(blocked.extractor, "firecrawl");
  assert.match(blocked.content, /complete article body/);
});

function response(body, status = 200) {
  return {
    ok: status >= 200 && status < 300,
    status,
    statusText: status === 200 ? "OK" : "Forbidden",
    url: "https://example.com/",
    headers: new Headers({ "content-type": "text/html" }),
    arrayBuffer: async () => new TextEncoder().encode(body).buffer
  };
}
