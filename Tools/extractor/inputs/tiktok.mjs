import { fetchText } from "./http.mjs";

const TIKTOK_HOSTS = new Set([
  "m.tiktok.com",
  "tiktok.com",
  "vm.tiktok.com",
  "www.tiktok.com"
]);

export const tiktokInput = {
  id: "tiktok",
  sourceType: "social-post",
  fallbackToGeneric: true,
  matches(rawUrl) {
    return parseTikTokURL(rawUrl) !== null;
  },
  extract: extractTikTok
};

export async function extractTikTok(rawUrl, context = {}) {
  if (!parseTikTokURL(rawUrl)) return null;
  const fetched = await fetchText(
    `https://www.tiktok.com/oembed?url=${encodeURIComponent(rawUrl)}`,
    {
      ...context,
      headers: { ...context.headers, Accept: "application/json" }
    }
  );
  const data = JSON.parse(fetched.text);
  const caption = cleanText(data.title);
  const author = cleanText(data.author_name);
  if (!caption && !author) {
    throw new Error("TikTok did not return readable post metadata.");
  }

  return {
    url: rawUrl,
    title: author ? `TikTok by ${author}` : "TikTok post",
    description: caption || null,
    siteName: "TikTok",
    content: [
      author ? `Author: ${author}` : "",
      caption,
      typeof data.thumbnail_url === "string"
        ? `Thumbnail: ${data.thumbnail_url}`
        : ""
    ].filter(Boolean).join("\n\n")
  };
}

export function parseTikTokURL(rawUrl) {
  try {
    const url = new URL(rawUrl);
    if (!TIKTOK_HOSTS.has(url.hostname.toLowerCase())) return null;
    return url.pathname !== "/" ? url : null;
  } catch {
    return null;
  }
}

function cleanText(value) {
  return typeof value === "string" ? value.replace(/\s+/gu, " ").trim() : "";
}
