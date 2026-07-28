import assert from "node:assert/strict";
import test from "node:test";

import { extractTikTok, parseTikTokURL } from "./tiktok.mjs";

test("TikTok extraction uses the official oEmbed caption and author", async () => {
  const rawUrl =
    "https://www.tiktok.com/@scout2015/video/6718335390845095173";
  const result = await extractTikTok(rawUrl, {
    fetchImpl: async (url) => {
      assert.match(String(url), /^https:\/\/www\.tiktok\.com\/oembed\?url=/);
      return response({
        title: "A useful video caption #example",
        author_name: "Scout",
        thumbnail_url: "https://example.com/thumbnail.jpg"
      });
    }
  });

  assert.equal(result.title, "TikTok by Scout");
  assert.match(result.content, /useful video caption/);
  assert.match(result.content, /thumbnail\.jpg/);
  assert.ok(parseTikTokURL(rawUrl));
  assert.equal(parseTikTokURL("https://example.com/video/123"), null);
});

function response(body) {
  const text = JSON.stringify(body);
  return {
    ok: true,
    status: 200,
    statusText: "OK",
    url: "https://www.tiktok.com/oembed",
    headers: new Headers({ "content-type": "application/json" }),
    arrayBuffer: async () => new TextEncoder().encode(text).buffer
  };
}
