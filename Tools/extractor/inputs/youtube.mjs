import { extractHTMLMetadata } from "./generic-html.mjs";
import { fetchText } from "./http.mjs";

const YOUTUBE_HOSTS = new Set([
  "youtube.com",
  "www.youtube.com",
  "m.youtube.com",
  "music.youtube.com",
  "youtube-nocookie.com",
  "www.youtube-nocookie.com"
]);

export const youtubeInput = {
  id: "youtube",
  sourceType: "video",
  fallbackToGeneric: false,
  matches(rawUrl) {
    return extractYouTubeVideoID(rawUrl) !== null;
  },
  extract: extractYouTube
};

export async function extractYouTube(rawUrl, context = {}) {
  const videoID = extractYouTubeVideoID(rawUrl);
  if (!videoID) return null;

  const fetched = await fetchText(rawUrl, context);
  const player = extractYouTubePlayerResponse(fetched.text);
  const metadata = extractHTMLMetadata(fetched.text, fetched.finalURL);
  const video = player?.videoDetails ?? {};
  const microformat = player?.microformat?.playerMicroformatRenderer ?? {};
  const title = cleanText(video.title) || metadata.title;
  const description =
    cleanText(video.shortDescription) ||
    cleanText(microformat.description?.simpleText) ||
    metadata.description;
  const author = cleanText(video.author);

  let tracks =
    player?.captions?.playerCaptionsTracklistRenderer?.captionTracks ?? [];
  let transcript = null;
  let transcriptError = null;
  if (Array.isArray(tracks) && tracks.length > 0) {
    try {
      if (tracks.some((track) => /[?&]exp=xp[ev](?:&|$)/u.test(track?.baseUrl))) {
        tracks = await fetchCaptionTracksWithoutProofToken(videoID, context);
      }
      transcript = await fetchPreferredTranscript(tracks, context);
    } catch (error) {
      transcriptError = error instanceof Error ? error.message : String(error);
    }
  }

  const content = transcript?.segments?.length
    ? `Transcript:\n${formatTranscript(
        transcript.segments,
        context.includeTranscriptTimestamps === true
      )}`
    : unavailableTranscriptContent({ author, description });

  return {
    url: rawUrl,
    title: title || `YouTube video ${videoID}`,
    description: description || null,
    siteName: "YouTube",
    content,
    transcriptAvailable: Boolean(transcript?.segments?.length),
    transcriptLanguage: transcript?.languageCode ?? null,
    transcriptError
  };
}

async function fetchCaptionTracksWithoutProofToken(videoID, context) {
  const response = await fetchText(
    "https://www.youtube.com/youtubei/v1/player?prettyPrint=false",
    {
      ...context,
      body: JSON.stringify({
        context: {
          client: {
            clientName: "IOS",
            clientVersion: "21.26.4",
            deviceMake: "Apple",
            deviceModel: "iPhone16,2",
            hl: "en",
            osName: "iPhone",
            osVersion: "18.3.2.22D82"
          }
        },
        videoId: videoID
      }),
      headers: {
        "Content-Type": "application/json",
        "User-Agent":
          "com.google.ios.youtube/21.26.4 (iPhone16,2; U; CPU iOS 18_3_2 like Mac OS X;)",
        "X-YouTube-Client-Name": "5",
        "X-YouTube-Client-Version": "21.26.4"
      },
      maximumBytes: 10_000_000,
      method: "POST"
    }
  );
  const player = JSON.parse(response.text);
  return player?.captions?.playerCaptionsTracklistRenderer?.captionTracks ?? [];
}

export function extractYouTubeVideoID(rawUrl) {
  let url;
  try {
    url = new URL(rawUrl);
  } catch {
    return null;
  }
  const hostname = url.hostname.toLowerCase().replace(/\.$/u, "");
  if (hostname === "youtu.be") {
    return validVideoID(url.pathname.split("/").filter(Boolean)[0]);
  }
  if (!YOUTUBE_HOSTS.has(hostname)) return null;
  if (url.pathname === "/watch") {
    return validVideoID(url.searchParams.get("v"));
  }
  const [kind, candidate] = url.pathname.split("/").filter(Boolean);
  return ["shorts", "live", "embed"].includes(kind)
    ? validVideoID(candidate)
    : null;
}

export function extractYouTubePlayerResponse(html) {
  const markers = [
    /(?:var\s+)?ytInitialPlayerResponse\s*=\s*/gu,
    /"ytInitialPlayerResponse"\s*:\s*/gu
  ];
  for (const marker of markers) {
    for (const match of html.matchAll(marker)) {
      const start = (match.index ?? 0) + match[0].length;
      const serialized = balancedJSONObject(html, start);
      if (!serialized) continue;
      try {
        return JSON.parse(serialized);
      } catch {
        // Keep looking for another player response on the page.
      }
    }
  }
  return null;
}

async function fetchPreferredTranscript(tracks, context) {
  const track = [...tracks]
    .filter((candidate) => typeof candidate?.baseUrl === "string")
    .sort((left, right) => transcriptTrackScore(right) - transcriptTrackScore(left))[0];
  if (!track) return null;

  const url = new URL(track.baseUrl);
  url.searchParams.set("fmt", "json3");
  const response = await fetchText(url.toString(), {
    ...context,
    headers: { "Accept": "application/json,text/xml;q=0.9,*/*;q=0.1" },
    maximumBytes: 10_000_000
  });
  const segments = parseCaptionResponse(response.text);
  return segments.length
    ? {
        languageCode: cleanText(track.languageCode) || null,
        segments
      }
    : null;
}

export function parseCaptionResponse(text) {
  try {
    const payload = JSON.parse(text);
    return (Array.isArray(payload?.events) ? payload.events : [])
      .map((event) => {
        const content = (Array.isArray(event?.segs) ? event.segs : [])
          .map((segment) => cleanText(segment?.utf8))
          .filter(Boolean)
          .join("");
        return {
          startMilliseconds: Number(event?.tStartMs) || 0,
          text: content
        };
      })
      .filter((segment) => segment.text);
  } catch {
    return parseXMLCaptions(text);
  }
}

function parseXMLCaptions(text) {
  const segments = [];
  for (const match of text.matchAll(
    /<text\b[^>]*\bstart="([^"]+)"[^>]*>([\s\S]*?)<\/text>/giu
  )) {
    const content = decodeEntities(match[2]).replace(/<[^>]+>/gu, "");
    const normalized = cleanText(content);
    if (!normalized) continue;
    segments.push({
      startMilliseconds: Math.round((Number(match[1]) || 0) * 1000),
      text: normalized
    });
  }
  return segments;
}

function formatTranscript(segments, includeTimestamps) {
  return segments
    .map((segment) =>
      includeTimestamps
        ? `[${formatTimestamp(segment.startMilliseconds)}] ${segment.text}`
        : segment.text
    )
    .join("\n");
}

function unavailableTranscriptContent({ author, description }) {
  return [
    "Transcript unavailable for this video.",
    author ? `Channel: ${author}` : null,
    description ? `\nDescription:\n${description}` : null
  ]
    .filter(Boolean)
    .join("\n");
}

function transcriptTrackScore(track) {
  const language = cleanText(track?.languageCode).toLowerCase();
  const manual = track?.kind === "asr" ? 0 : 10;
  const english = language === "en" || language.startsWith("en-") ? 2 : 0;
  return manual + english;
}

function balancedJSONObject(text, offset) {
  const start = text.indexOf("{", offset);
  if (start < 0 || start - offset > 20) return null;
  let depth = 0;
  let quoted = false;
  let escaped = false;
  for (let index = start; index < text.length; index += 1) {
    const character = text[index];
    if (quoted) {
      if (escaped) {
        escaped = false;
      } else if (character === "\\") {
        escaped = true;
      } else if (character === '"') {
        quoted = false;
      }
      continue;
    }
    if (character === '"') {
      quoted = true;
    } else if (character === "{") {
      depth += 1;
    } else if (character === "}") {
      depth -= 1;
      if (depth === 0) return text.slice(start, index + 1);
    }
  }
  return null;
}

function validVideoID(value) {
  const candidate = cleanText(value);
  return /^[A-Za-z0-9_-]{6,20}$/u.test(candidate) ? candidate : null;
}

function cleanText(value) {
  return typeof value === "string"
    ? value.replace(/\u00a0/gu, " ").replace(/[ \t]+/gu, " ").trim()
    : "";
}

function formatTimestamp(milliseconds) {
  const seconds = Math.max(0, Math.floor(milliseconds / 1000));
  const hours = Math.floor(seconds / 3600);
  const minutes = Math.floor((seconds % 3600) / 60);
  const remainder = seconds % 60;
  return hours > 0
    ? `${hours}:${String(minutes).padStart(2, "0")}:${String(remainder).padStart(2, "0")}`
    : `${minutes}:${String(remainder).padStart(2, "0")}`;
}

function decodeEntities(value) {
  return value
    .replaceAll("&amp;", "&")
    .replaceAll("&lt;", "<")
    .replaceAll("&gt;", ">")
    .replaceAll("&quot;", '"')
    .replaceAll("&#39;", "'");
}
