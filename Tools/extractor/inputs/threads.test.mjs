import assert from "node:assert/strict";
import test from "node:test";

import { extractThreads, parseThreadsPostURL } from "./threads.mjs";

test("Threads post URLs use their public preview metadata", async () => {
  const rawUrl = "https://www.threads.com/@threads/post/CwVVlQlOe53";
  let userAgent;
  const result = await extractThreads(rawUrl, {
    fetchImpl: async (_url, options) => {
      userAgent = options.headers["User-Agent"];
      return {
        ok: true,
        status: 200,
        statusText: "OK",
        url: rawUrl,
        headers: new Headers({ "content-type": "text/html" }),
        text: async () => `<html><head>
          <meta property="og:title" content="Threads (@threads) on Threads">
          <meta property="og:description" content="Threads on web is here 🤩">
          <meta property="og:site_name" content="Threads">
        </head></html>`
      };
    }
  });

  assert.match(userAgent, /Googlebot/);
  assert.equal(result.title, "Threads (@threads) on Threads");
  assert.equal(result.content, "Threads on web is here 🤩");
  assert.deepEqual(parseThreadsPostURL(rawUrl), {
    actor: "threads",
    postID: "CwVVlQlOe53"
  });
  assert.equal(parseThreadsPostURL("https://threads.com/@threads"), null);
});
