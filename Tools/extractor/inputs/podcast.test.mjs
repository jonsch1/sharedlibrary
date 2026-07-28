import assert from "node:assert/strict";
import test from "node:test";

import { extractLink } from "./registry.mjs";
import { parsePodcastFeed, parseTranscript } from "./podcast.mjs";

test("podcast episode pages use published RSS transcripts", async () => {
  const requested = [];
  const result = await extractLink("https://example.com/episodes/owned-inputs", {
    fetchImpl: async (url) => {
      requested.push(String(url));
      if (requested.length === 1) {
        return response(
          `<!doctype html><html><head>
            <title>Owned inputs — Example Podcast</title>
            <meta property="og:title" content="Owned inputs">
            <link rel="canonical" href="https://example.com/episodes/owned-inputs">
            <link rel="alternate" type="application/rss+xml" href="/podcast.xml">
            <script type="application/ld+json">{"@type":"PodcastEpisode"}</script>
          </head><body><p>Episode notes.</p></body></html>`,
          "text/html",
          String(url)
        );
      }
      if (requested.length === 2) {
        return response(podcastFeed(), "application/rss+xml", String(url));
      }
      return response(
        `WEBVTT

00:00:00.000 --> 00:00:02.000
<v Ada>A published transcript.

00:00:02.000 --> 00:00:04.000
No media download needed.`,
        "application/octet-stream",
        String(url)
      );
    }
  });

  assert.deepEqual(requested, [
    "https://example.com/episodes/owned-inputs",
    "https://example.com/podcast.xml",
    "https://cdn.example.com/owned-inputs.vtt"
  ]);
  assert.equal(result.extractor, "podcast");
  assert.equal(result.sourceType, "podcast");
  assert.equal(result.title, "Owned inputs");
  assert.equal(result.transcriptAvailable, true);
  assert.equal(
    result.content,
    "Transcript:\nAda: A published transcript.\nNo media download needed."
  );
});

test("podcast feeds remain useful when the latest episode has no transcript", async () => {
  const result = await extractLink("https://example.com/podcast.xml", {
    fetchImpl: async (url) =>
      response(
        podcastFeed({ transcript: "", description: "What this episode covers." }),
        "application/rss+xml",
        String(url)
      )
  });

  assert.equal(result.transcriptAvailable, false);
  assert.match(result.content, /^Transcript unavailable/);
  assert.match(result.content, /What this episode covers\./);
});

test("podcast feeds transcribe enclosure audio when no transcript is published", async () => {
  const requested = [];
  const result = await extractLink("https://example.com/podcast.xml", {
    fetchImpl: async (url) =>
      response(
        podcastFeed({ transcript: "", description: "What this episode covers." }),
        "application/rss+xml",
        String(url)
      ),
    async transcribeMedia(url) {
      requested.push(url);
      return { language: "en", text: "Generated podcast transcript." };
    }
  });

  assert.deepEqual(requested, ["https://cdn.example.com/episode.mp3"]);
  assert.equal(result.transcriptAvailable, true);
  assert.equal(result.transcriptLanguage, "en");
  assert.equal(result.mediaURL, "https://cdn.example.com/episode.mp3");
  assert.equal(result.content, "Transcript:\nGenerated podcast transcript.");
});

test("podcast feeds fall back when a published transcript cannot be retrieved", async () => {
  const requested = [];
  const result = await extractLink("https://example.com/podcast.xml", {
    fetchImpl: async (url) => {
      requested.push(String(url));
      if (requested.length === 1) {
        return response(podcastFeed(), "application/rss+xml", String(url));
      }
      throw new Error("Published transcript failed.");
    },
    async transcribeMedia(url) {
      requested.push(url);
      return { language: "en", text: "Recovered from audio." };
    }
  });

  assert.equal(requested.at(-1), "https://cdn.example.com/episode.mp3");
  assert.equal(result.content, "Transcript:\nRecovered from audio.");
  assert.equal(result.transcriptError, null);
});

test("podcast transcript parsers support the standard JSON and SRT formats", () => {
  assert.equal(
    parseTranscript(
      JSON.stringify({
        segments: [
          { speaker: "Ada", body: "First" },
          { speaker: "Ada", body: "line." },
          { speaker: "Grace", body: "Second line." }
        ]
      }),
      "application/json"
    ),
    "Ada: First line. Grace: Second line."
  );
  assert.equal(
    parseTranscript(
      "1\n00:00:00,000 --> 00:00:02,000\nAda: First line.\n\n2\n00:00:02,000 --> 00:00:04,000\nSecond line.",
      "application/x-subrip"
    ),
    "Ada: First line.\nSecond line."
  );
});

test("podcast feeds accept alternate namespace prefixes", () => {
  const feed = parsePodcastFeed(podcastFeed(), "https://example.com/podcast.xml");
  assert.equal(feed?.items[0]?.transcripts[0]?.url, "https://cdn.example.com/owned-inputs.vtt");
});

test("Apple Podcasts episode links resolve the publisher feed", async () => {
  const requested = [];
  const result = await extractLink(
    "https://podcasts.apple.com/us/podcast/example/id12345?i=67890",
    {
      fetchImpl: async (url) => {
        requested.push(String(url));
        if (requested.length === 1) {
          return response(
            '<html><head><meta property="og:title" content="Owned inputs"></head></html>',
            "text/html",
            String(url)
          );
        }
        if (requested.length === 2) {
          return response(
            JSON.stringify({
              results: [{ kind: "podcast", feedUrl: "https://example.com/podcast.xml" }]
            }),
            "application/json",
            String(url)
          );
        }
        if (requested.length === 3) {
          return response(podcastFeed(), "application/rss+xml", String(url));
        }
        return response("Published transcript.", "text/plain", String(url));
      }
    }
  );

  assert.equal(requested[1], "https://itunes.apple.com/lookup?id=12345&entity=podcast");
  assert.equal(result.extractor, "podcast");
  assert.equal(result.content, "Transcript:\nPublished transcript.");
});

function podcastFeed({
  transcript = '<p:transcript url="https://cdn.example.com/owned-inputs.vtt" type="text/vtt" language="en"/>',
  description = "Episode notes."
} = {}) {
  return `<?xml version="1.0"?>
    <rss version="2.0" xmlns:p="https://podcastindex.org/namespace/1.0">
      <channel>
        <title>Example Podcast</title>
        <item>
          <title>Owned inputs</title>
          <link>https://example.com/episodes/owned-inputs</link>
          <description>${description}</description>
          <enclosure url="https://cdn.example.com/episode.mp3" type="audio/mpeg"/>
          ${transcript}
        </item>
      </channel>
    </rss>`;
}

function response(body, contentType, url) {
  const bytes = new TextEncoder().encode(body);
  return {
    ok: true,
    status: 200,
    statusText: "OK",
    url,
    headers: new Headers({ "content-type": contentType }),
    arrayBuffer: async () =>
      bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength),
    text: async () => body
  };
}
