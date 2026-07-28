import assert from "node:assert/strict";
import test from "node:test";

import {
  extractYouTube,
  extractYouTubePlayerResponse,
  extractYouTubeVideoID,
  parseCaptionResponse
} from "./youtube.mjs";

test("extractYouTubeVideoID recognizes video URLs but not channel pages", () => {
  assert.equal(
    extractYouTubeVideoID("https://www.youtube.com/watch?v=abc1234"),
    "abc1234"
  );
  assert.equal(
    extractYouTubeVideoID("https://youtu.be/abc1234?t=20"),
    "abc1234"
  );
  assert.equal(
    extractYouTubeVideoID("https://youtube.com/shorts/abc1234"),
    "abc1234"
  );
  assert.equal(extractYouTubeVideoID("https://youtube.com/@briefly"), null);
  assert.equal(
    extractYouTubeVideoID("https://youtube.com.evil.example/watch?v=abc1234"),
    null
  );
});

test("extractYouTubePlayerResponse reads balanced player JSON", () => {
  const player = extractYouTubePlayerResponse(
    `<script>var ytInitialPlayerResponse = ${JSON.stringify({
      videoDetails: { title: "A title with a } brace" }
    })};</script>`
  );
  assert.equal(player?.videoDetails?.title, "A title with a } brace");
});

test("YouTube extraction fetches creator captions without media downloads", async () => {
  const page = youtubePage({
    captionTracks: [
      {
        baseUrl: "https://www.youtube.com/api/timedtext?v=abc1234&lang=en",
        languageCode: "en"
      }
    ]
  });
  const requested = [];
  const result = await extractYouTube(
    "https://www.youtube.com/watch?v=abc1234",
    {
      includeTranscriptTimestamps: true,
      fetchImpl: async (url) => {
        requested.push(String(url));
        return requested.length === 1
          ? response(page, "text/html", String(url))
          : response(
              JSON.stringify({
                events: [
                  { tStartMs: 1200, segs: [{ utf8: "First line." }] },
                  { tStartMs: 62500, segs: [{ utf8: "Second line." }] }
                ]
              }),
              "application/json",
              String(url)
            );
      }
    }
  );

  assert.equal(requested.length, 2);
  assert.match(requested[1], /fmt=json3/);
  assert.equal(result.title, "An owned pipeline");
  assert.equal(result.transcriptAvailable, true);
  assert.equal(
    result.content,
    "Transcript:\n[0:01] First line.\n[1:02] Second line."
  );
});

test("YouTube extraction bypasses proof-token caption tracks", async () => {
  const page = youtubePage({
    captionTracks: [
      {
        baseUrl:
          "https://www.youtube.com/api/timedtext?v=abc1234&exp=xpe&lang=en",
        languageCode: "en"
      }
    ]
  });
  const requested = [];
  const result = await extractYouTube(
    "https://www.youtube.com/watch?v=abc1234",
    {
      fetchImpl: async (url) => {
        requested.push(String(url));
        if (requested.length === 1) {
          return response(page, "text/html", String(url));
        }
        if (requested.length === 2) {
          return response(
            JSON.stringify({
              captions: {
                playerCaptionsTracklistRenderer: {
                  captionTracks: [
                    {
                      baseUrl:
                        "https://www.youtube.com/api/timedtext?v=abc1234&lang=en",
                      languageCode: "en"
                    }
                  ]
                }
              }
            }),
            "application/json",
            String(url)
          );
        }
        return response(
          JSON.stringify({
            events: [{ tStartMs: 0, segs: [{ utf8: "Recovered captions." }] }]
          }),
          "application/json",
          String(url)
        );
      }
    }
  );

  assert.equal(requested.length, 3);
  assert.match(requested[1], /youtubei\/v1\/player/);
  assert.doesNotMatch(requested[2], /exp=xpe/);
  assert.equal(result.content, "Transcript:\nRecovered captions.");
  assert.equal(result.transcriptAvailable, true);
});

test("YouTube extraction returns metadata when captions are unavailable", async () => {
  const result = await extractYouTube(
    "https://www.youtube.com/watch?v=abc1234",
    {
      fetchImpl: async (url) =>
        response(youtubePage({ captionTracks: [] }), "text/html", String(url))
    }
  );

  assert.equal(result.transcriptAvailable, false);
  assert.equal(result.title, "An owned pipeline");
  assert.match(result.content, /^Transcript unavailable for this video\./);
  assert.match(result.content, /Channel: Briefly/);
  assert.match(result.content, /Description:\nHow the pipeline works\./);
});

test("YouTube extraction transcribes media when captions are unavailable", async () => {
  const requested = [];
  const result = await extractYouTube(
    "https://www.youtube.com/watch?v=abc1234",
    {
      includeTranscriptTimestamps: true,
      fetchImpl: async (url) =>
        response(youtubePage({ captionTracks: [] }), "text/html", String(url)),
      async transcribeMedia(url) {
        requested.push(url);
        return { language: "en", text: "[0:01] Generated transcript." };
      }
    }
  );

  assert.deepEqual(requested, ["https://www.youtube.com/watch?v=abc1234"]);
  assert.equal(result.transcriptAvailable, true);
  assert.equal(result.transcriptLanguage, "en");
  assert.equal(result.content, "Transcript:\n[0:01] Generated transcript.");
});

test("parseCaptionResponse also accepts XML caption responses", () => {
  assert.deepEqual(
    parseCaptionResponse(
      '<transcript><text start="1.5">Hello &amp; goodbye.</text></transcript>'
    ),
    [{ startMilliseconds: 1500, text: "Hello & goodbye." }]
  );
});

function youtubePage({ captionTracks }) {
  return `<!doctype html>
    <html>
      <head><meta property="og:title" content="Fallback video title"></head>
      <body>
        <script>var ytInitialPlayerResponse = ${JSON.stringify({
          videoDetails: {
            title: "An owned pipeline",
            author: "Briefly",
            shortDescription: "How the pipeline works."
          },
          captions: {
            playerCaptionsTracklistRenderer: { captionTracks }
          }
        })};</script>
      </body>
    </html>`;
}

function response(body, contentType, url) {
  return {
    ok: true,
    status: 200,
    statusText: "OK",
    url,
    headers: new Headers({ "content-type": contentType }),
    text: async () => body
  };
}
