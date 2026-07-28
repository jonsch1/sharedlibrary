import assert from "node:assert/strict";
import test from "node:test";

import { arxivInput, extractArxiv } from "./arxiv.mjs";

test("arXiv papers are fetched as Markdown from Markxiv", async () => {
  const rawUrl = "https://arxiv.org/abs/1706.03762";
  let requestedURL;
  const result = await extractArxiv(rawUrl, {
    fetchImpl: async (url) => {
      requestedURL = String(url);
      return {
        ok: true,
        status: 200,
        statusText: "OK",
        url: requestedURL,
        headers: new Headers({ "content-type": "text/markdown" }),
        text: async () => "# Attention Is All You Need\n\nPaper content."
      };
    }
  });

  assert.equal(requestedURL, "https://markxiv.org/abs/1706.03762");
  assert.equal(result.url, rawUrl);
  assert.equal(result.title, "Attention Is All You Need");
  assert.match(result.content, /Paper content/);
  assert.equal(arxivInput.matches(rawUrl), true);
  assert.equal(arxivInput.matches("https://arxiv.org.evil.example/abs/1"), false);
});
