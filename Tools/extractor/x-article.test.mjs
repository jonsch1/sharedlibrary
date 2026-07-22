import assert from "node:assert/strict";
import test from "node:test";

import {
  fetchXArticle,
  parseXStatusUrl,
  xArticleToExtractedContent
} from "./x-article.mjs";

test("parseXStatusUrl recognizes X and Twitter status links", () => {
  assert.deepEqual(
    parseXStatusUrl("https://x.com/cerebras/status/2077822555159945507?s=20"),
    {
      actor: "cerebras",
      postID: "2077822555159945507",
      apiUrl: "https://api.fxtwitter.com/cerebras/status/2077822555159945507"
    }
  );
  assert.equal(
    parseXStatusUrl("https://mobile.twitter.com/example/status/123/photo/1")?.postID,
    "123"
  );
  assert.equal(parseXStatusUrl("https://example.com/cerebras/status/123"), null);
  assert.equal(parseXStatusUrl("https://x.com/cerebras"), null);
});

test("xArticleToExtractedContent renders structured blocks as Markdown", () => {
  const sourceURL = "https://x.com/example/status/123";
  const extracted = xArticleToExtractedContent(sourceURL, articlePayload());

  assert.equal(extracted.url, sourceURL);
  assert.equal(extracted.title, "A useful article");
  assert.equal(extracted.description, "A short preview");
  assert.equal(extracted.siteName, "X");
  assert.equal(extracted.totalCharacters, extracted.content.length);
  assert.ok(extracted.wordCount > 10);
  assert.equal(
    extracted.content,
    [
      "![Cover image](https://images.example/cover.jpg)",
      "**Read** [docs](https://example.com/docs) today.",
      "## Details",
      "- First item",
      "  1. Nested item",
      "![Article image](https://images.example/diagram.jpg)",
      "```\nlet answer = 42;\n```"
    ].join("\n\n")
  );
});

test("fetchXArticle uses the public status endpoint and ignores ordinary posts", async () => {
  let requestedURL;
  const extracted = await fetchXArticle("https://x.com/example/status/123", {
    fetchImpl: async (url) => {
      requestedURL = url;
      return {
        ok: true,
        json: async () => articlePayload()
      };
    }
  });
  assert.equal(requestedURL, "https://api.fxtwitter.com/example/status/123");
  assert.equal(extracted?.title, "A useful article");

  const ordinaryPost = await fetchXArticle("https://x.com/example/status/456", {
    fetchImpl: async () => ({
      ok: true,
      json: async () => ({ tweet: { text: "Just a regular post" } })
    })
  });
  assert.equal(ordinaryPost, null);
});

function articlePayload() {
  return {
    tweet: {
      article: {
        title: "A useful article",
        preview_text: "A short preview",
        cover_media: {
          media_info: { original_img_url: "https://images.example/cover.jpg" }
        },
        content: {
          blocks: [
            {
              type: "unstyled",
              text: "Read docs today.",
              inlineStyleRanges: [{ offset: 0, length: 4, style: "Bold" }],
              entityRanges: [{ offset: 5, length: 4, key: 0 }]
            },
            { type: "header-two", text: "Details\u200B\u200C\u200D\u2060\uFEFF" },
            { type: "unordered-list-item", text: "First item", depth: 0 },
            { type: "ordered-list-item", text: "Nested item", depth: 1 },
            { type: "atomic", text: " ", entityRanges: [{ offset: 0, length: 1, key: 1 }] },
            { type: "code-block", text: "let answer = 42;" }
          ],
          entityMap: [
            {
              key: "0",
              value: { type: "LINK", data: { url: "https://example.com/docs" } }
            },
            {
              key: "1",
              value: {
                type: "MEDIA",
                data: { mediaItems: [{ mediaId: "media-1" }] }
              }
            }
          ]
        },
        media_entities: [
          {
            media_id: "media-1",
            media_info: { original_img_url: "https://images.example/diagram.jpg" }
          }
        ]
      }
    }
  };
}
