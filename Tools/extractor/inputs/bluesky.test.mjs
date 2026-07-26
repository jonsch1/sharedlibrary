import assert from "node:assert/strict";
import test from "node:test";

import {
  fetchBlueskyPost,
  parseBlueskyPostURL
} from "./bluesky.mjs";

test("parseBlueskyPostURL recognizes only post URLs", () => {
  assert.deepEqual(
    parseBlueskyPostURL("https://bsky.app/profile/example.com/post/abc123"),
    { actor: "example.com", rkey: "abc123" }
  );
  assert.equal(
    parseBlueskyPostURL("https://bsky.app/profile/example.com"),
    null
  );
  assert.equal(
    parseBlueskyPostURL(
      "https://bsky.app.evil.example/profile/example.com/post/abc123"
    ),
    null
  );
});

test("fetchBlueskyPost resolves handles and renders a post", async () => {
  const requested = [];
  const result = await fetchBlueskyPost(
    "https://bsky.app/profile/example.com/post/abc123",
    {
      fetchImpl: async (url) => {
        requested.push(String(url));
        return requested.length === 1
          ? jsonResponse({ did: "did:plc:example" })
          : jsonResponse({
              thread: {
                post: {
                  uri: "at://did:plc:example/app.bsky.feed.post/abc123",
                  cid: "bafyexample",
                  author: {
                    displayName: "Example Person",
                    handle: "example.com"
                  },
                  record: {
                    $type: "app.bsky.feed.post",
                    text: "A useful Bluesky post.",
                    createdAt: "2026-07-26T10:00:00.000Z"
                  },
                  likeCount: 3,
                  replyCount: 1
                }
              }
            });
      }
    }
  );

  assert.equal(requested.length, 2);
  assert.match(requested[1], /app\.bsky\.feed\.getPostThread/);
  assert.equal(
    result.title,
    "Bluesky post by Example Person (@example.com): A useful Bluesky post."
  );
  assert.match(result.content, /1 reply \| 3 likes/);
});

function jsonResponse(value) {
  return {
    ok: true,
    status: 200,
    statusText: "OK",
    json: async () => value
  };
}
