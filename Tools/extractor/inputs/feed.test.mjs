import assert from "node:assert/strict";
import test from "node:test";

import {
  discoverSource,
  normalizeSource,
  parseFeed,
  parseHackerNews
} from "./feed.mjs";

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

test("Hacker News front returns its top five stories", () => {
  const rows = Array.from(
    { length: 7 },
    (_, index) =>
      `<tr class="athing" id="${index}"><td class="title"><span class="titleline"><a href="item?id=${index}">Story ${index}</a></span></td></tr>`
  ).join("");
  const source = parseHackerNews(
    `<table>${rows}</table>`,
    "https://news.ycombinator.com/front"
  );
  assert.equal(source.items.length, 5);
  assert.equal(source.items[0].title, "Story 0");
  assert.equal(source.items[0].url, "https://news.ycombinator.com/item?id=0");
});

test("a podcast page channel returns only its latest episode", async () => {
  const pageURL = "https://podcasts.apple.com/de/podcast/show/id1519234952";
  const feedURL = "https://example.com/podcast.xml";
  const source = await discoverSource(pageURL, {
    fetchImpl: fixtureFetch({
      [pageURL]: "<html><title>Podcast</title></html>",
      "https://itunes.apple.com/lookup?id=1519234952&entity=podcast": JSON.stringify({
        results: [{ kind: "podcast", feedUrl: feedURL }]
      }),
      [feedURL]: `<rss><channel><title>Podcast</title>
        <item><guid>older</guid><title>Older</title><link>https://example.com/older</link>
          <pubDate>Mon, 27 Jul 2026 10:00:00 GMT</pubDate>
          <enclosure url="https://cdn.example.com/older.mp3" type="audio/mpeg" /></item>
        <item><guid>latest</guid><title>Latest</title><link>https://example.com/latest</link>
          <pubDate>Tue, 28 Jul 2026 10:00:00 GMT</pubDate>
          <enclosure url="https://cdn.example.com/latest.mp3" type="audio/mpeg" /></item>
      </channel></rss>`
    })
  });

  assert.equal(source.kind, "podcast");
  assert.deepEqual(source.items.map(({ id }) => id), ["latest"]);
  assert.equal(source.items[0].url, "https://example.com/latest");
});

test("a YouTube channel returns only its latest video", async () => {
  const pageURL = "https://www.youtube.com/@matt-ari";
  const feedURL =
    "https://www.youtube.com/feeds/videos.xml?channel_id=UC_MATT_ARI";
  const source = await discoverSource(pageURL, {
    fetchImpl: fixtureFetch({
      [pageURL]: `<html><head><meta itemprop="channelId" content="UC_MATT_ARI" /></head></html>`,
      [feedURL]: `<feed xmlns="http://www.w3.org/2005/Atom"><title>Matt &amp; Ari</title>
        <entry><id>older</id><title>Older</title><published>2026-07-27T10:00:00Z</published>
          <link rel="alternate" href="https://www.youtube.com/watch?v=older" /></entry>
        <entry><id>latest</id><title>Latest</title><published>2026-07-28T10:00:00Z</published>
          <link rel="alternate" href="https://www.youtube.com/watch?v=latest" /></entry>
      </feed>`
    })
  });

  assert.deepEqual(source.items.map(({ id }) => id), ["latest"]);
  assert.equal(source.items[0].url, "https://www.youtube.com/watch?v=latest");
});

function fixtureFetch(values) {
  return async (url) => {
    const body = values[String(url)];
    if (body === undefined) return new Response("Not found", { status: 404 });
    return new Response(body, {
      status: 200,
      headers: {
        "content-type": body.trimStart().startsWith("{")
          ? "application/json"
          : "text/html"
      }
    });
  };
}
