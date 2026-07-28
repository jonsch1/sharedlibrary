import assert from "node:assert/strict";
import test from "node:test";

import { normalizeSource, parseFeed } from "./feed.mjs";

test("parses RSS and Atom feed items into stable source updates", () => {
  const rss = parseFeed(
    `<?xml version="1.0"?><rss><channel><title>Example</title>
      <item><guid>one</guid><title>First</title><link>/first</link><pubDate>Sun, 26 Jul 2026 10:00:00 GMT</pubDate></item>
    </channel></rss>`,
    "https://example.com/feed.xml"
  );
  assert.equal(rss.title, "Example");
  assert.equal(rss.items[0].id, "one");
  assert.equal(rss.items[0].url, "https://example.com/first");

  const atom = parseFeed(
    `<feed xmlns="http://www.w3.org/2005/Atom"><title>arXiv</title><entry>
      <id>paper-1</id><title>A paper</title><published>2026-07-26T10:00:00Z</published>
      <link rel="alternate" href="https://arxiv.org/abs/2607.00001" />
    </entry></feed>`,
    "https://export.arxiv.org/api/query"
  );
  assert.equal(atom.items[0].id, "paper-1");
  assert.equal(atom.items[0].url, "https://arxiv.org/abs/2607.00001");
});

test("turns an arXiv shorthand into a normal query URL", () => {
  const url = new URL(normalizeSource("arxiv:agent alignment"));
  assert.equal(url.hostname, "export.arxiv.org");
  assert.equal(url.searchParams.get("search_query"), "all:agent alignment");
  assert.throws(() => normalizeSource("not a source"), /HTTP/);
});
