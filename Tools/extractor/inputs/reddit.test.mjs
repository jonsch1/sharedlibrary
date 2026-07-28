import assert from "node:assert/strict";
import test from "node:test";

import { extractReddit, parseRedditPostURL } from "./reddit.mjs";

test("Reddit extraction reads the post and top comments from public JSON", async () => {
  const rawUrl = "https://www.reddit.com/r/example/comments/abc123/a_post/";
  const result = await extractReddit(rawUrl, {
    fetchImpl: async (url) => {
      assert.match(String(url), /comments\/abc123\.json/);
      return response([
        {
          data: {
            children: [{
              kind: "t3",
              data: {
                author: "writer",
                permalink: "/r/example/comments/abc123/a_post/",
                selftext: "The full post body.",
                subreddit_name_prefixed: "r/example",
                title: "A post"
              }
            }]
          }
        },
        {
          data: {
            children: [{
              kind: "t1",
              data: { author: "reader", body: "A useful comment.", replies: "" }
            }]
          }
        }
      ]);
    }
  });

  assert.equal(result.title, "A post");
  assert.match(result.content, /full post body/);
  assert.match(result.content, /useful comment/);
  assert.equal(parseRedditPostURL("https://redd.it/abc123")?.postID, "abc123");
});

test("Reddit extraction falls back to official oEmbed when JSON is blocked", async () => {
  let requests = 0;
  const result = await extractReddit(
    "https://www.reddit.com/r/example/comments/abc123/a_post/",
    {
      fetchImpl: async () => {
        requests += 1;
        if (requests === 1) return response("blocked", 403);
        return response({ title: "A post", author_name: "writer" });
      }
    }
  );

  assert.equal(requests, 2);
  assert.equal(result.title, "A post");
  assert.match(result.content, /u\/writer/);
});

function response(body, status = 200) {
  const text = typeof body === "string" ? body : JSON.stringify(body);
  return {
    ok: status >= 200 && status < 300,
    status,
    statusText: status === 200 ? "OK" : "Forbidden",
    url: "https://www.reddit.com/",
    headers: new Headers({ "content-type": "application/json" }),
    arrayBuffer: async () => new TextEncoder().encode(text).buffer
  };
}
