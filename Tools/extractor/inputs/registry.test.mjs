import assert from "node:assert/strict";
import test from "node:test";

import { selectInput } from "./registry.mjs";

test("selectInput routes supported links to explicit modules", () => {
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
  assert.equal(selectInput("https://example.com/article")?.id, "generic-html");
  assert.equal(selectInput("file:///tmp/report.html"), null);
});
