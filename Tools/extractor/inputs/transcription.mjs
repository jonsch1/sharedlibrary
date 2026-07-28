import { execFile } from "node:child_process";
import { mkdtemp, readFile, readdir, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { promisify } from "node:util";

import { fetchText } from "./http.mjs";

const execFileAsync = promisify(execFile);
const YOUTUBE_HOSTS = new Set([
  "youtu.be",
  "youtube.com",
  "www.youtube.com",
  "m.youtube.com",
  "music.youtube.com",
  "youtube-nocookie.com",
  "www.youtube-nocookie.com"
]);

export async function transcribeMedia(
  mediaURL,
  {
    downloadMedia = downloadTranscriptionMedia,
    endpoint,
    fetchImpl,
    includeTranscriptTimestamps = false,
    mediaOutputDirectory,
    token
  }
) {
  const localAudio = await downloadMedia(mediaURL, mediaOutputDirectory, {
    fetchImpl
  });
  const response = await fetchText(endpoint, {
    body: localAudio,
    headers: {
      "Authorization": `Bearer ${token}`,
      "Content-Type": "application/octet-stream",
      "X-Briefly-Include-Timestamps": includeTranscriptTimestamps ? "1" : "0"
    },
    fetchImpl,
    maximumBytes: 40_000_000,
    method: "POST",
    timeoutMilliseconds: 1_800_000
  });
  const result = JSON.parse(response.text);
  const text = typeof result?.text === "string" ? result.text.trim() : "";
  if (!text) throw new Error("The transcription service returned no transcript.");
  return {
    language: typeof result.language === "string" ? result.language : null,
    text
  };
}

export async function downloadTranscriptionMedia(
  url,
  outputDirectory,
  { fetchImpl } = {}
) {
  if (isYouTubeURL(url)) return downloadMediaAudio(url, outputDirectory);
  return (
    await fetchText(url, {
      fetchImpl,
      maximumBytes: 250_000_000,
      timeoutMilliseconds: 180_000
    })
  ).bytes;
}

export async function downloadMediaAudio(url, outputDirectory) {
  const directory =
    outputDirectory || (await mkdtemp(join(tmpdir(), "briefly-youtube-")));
  try {
    const existing = (await readdir(directory))[0];
    if (existing) return new Uint8Array(await readFile(join(directory, existing)));
    await execFileAsync(
      "yt-dlp",
      ["--no-playlist", "--format", "worstaudio", "--output", join(directory, "media.%(ext)s"), url],
      { maxBuffer: 1_000_000, timeout: 180_000 }
    );
    const [filename] = await readdir(directory);
    if (!filename) throw new Error("Audio download returned no media.");
    return new Uint8Array(await readFile(join(directory, filename)));
  } finally {
    if (!outputDirectory) {
      await rm(directory, { force: true, recursive: true });
    }
  }
}

function isYouTubeURL(rawURL) {
  try {
    return YOUTUBE_HOSTS.has(new URL(rawURL).hostname.toLowerCase());
  } catch {
    return false;
  }
}
