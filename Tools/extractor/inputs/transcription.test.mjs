import assert from "node:assert/strict";
import test from "node:test";

import { transcribeMedia } from "./transcription.mjs";

test("transcription fallback sends authenticated media requests", async () => {
  let request;
  const result = await transcribeMedia("https://cdn.example.com/episode.mp3", {
    downloadMedia: async () => new Uint8Array([4, 5, 6]),
    endpoint: "https://transcribe.example.com",
    includeTranscriptTimestamps: true,
    token: "session-token",
    fetchImpl: async (url, init) => {
      request = { url, init };
      return response(JSON.stringify({ language: "en", text: "[0:01] Hello." }));
    }
  });

  assert.equal(request.url, "https://transcribe.example.com");
  assert.equal(request.init.headers.Authorization, "Bearer session-token");
  assert.deepEqual([...request.init.body], [4, 5, 6]);
  assert.equal(request.init.headers["Content-Type"], "application/octet-stream");
  assert.equal(request.init.headers["X-Briefly-Include-Timestamps"], "1");
  assert.deepEqual(result, { language: "en", text: "[0:01] Hello." });
});

test("YouTube fallback uploads locally resolved audio", async () => {
  let request;
  const result = await transcribeMedia("https://youtu.be/abc1234", {
    downloadMedia: async (_url, directory) => {
      assert.equal(directory, "/tmp/keep-audio");
      return new Uint8Array([1, 2, 3]);
    },
    endpoint: "https://transcribe.example.com",
    mediaOutputDirectory: "/tmp/keep-audio",
    token: "session-token",
    fetchImpl: async (url, init) => {
      request = { url, init };
      return response(JSON.stringify({ language: "en", text: "Uploaded audio." }));
    }
  });

  assert.deepEqual([...request.init.body], [1, 2, 3]);
  assert.equal(request.init.headers["Content-Type"], "application/octet-stream");
  assert.equal(request.init.headers["X-Briefly-Include-Timestamps"], "0");
  assert.deepEqual(result, { language: "en", text: "Uploaded audio." });
});

function response(body) {
  return {
    ok: true,
    status: 200,
    statusText: "OK",
    url: "https://transcribe.example.com",
    headers: new Headers({ "content-type": "application/json" }),
    arrayBuffer: async () => new TextEncoder().encode(body).buffer
  };
}
