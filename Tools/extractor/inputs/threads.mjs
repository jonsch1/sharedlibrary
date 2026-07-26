import { extractHTMLMetadata } from "./generic-html.mjs";
import { fetchText } from "./http.mjs";

const THREADS_HOSTS = new Set([
  "threads.com",
  "www.threads.com",
  "threads.net",
  "www.threads.net"
]);
const THREADS_USER_AGENT =
  "Mozilla/5.0 (compatible; Googlebot/2.1; +http://www.google.com/bot.html)";

export const threadsInput = {
  id: "threads",
  sourceType: "social-post",
  fallbackToGeneric: true,
  matches(rawUrl) {
    return parseThreadsPostURL(rawUrl) !== null;
  },
  extract: extractThreads
};

export async function extractThreads(rawUrl, context = {}) {
  const parsed = parseThreadsPostURL(rawUrl);
  if (!parsed) return null;

  const fetched = await fetchText(rawUrl, {
    ...context,
    headers: {
      ...context.headers,
      "User-Agent": THREADS_USER_AGENT
    }
  });
  const metadata = extractHTMLMetadata(fetched.text, fetched.finalURL);
  const content = metadata.description?.trim();
  if (!content) throw new Error("Threads post did not contain readable text.");

  return {
    url: rawUrl,
    canonicalURL: metadata.canonicalURL,
    title: metadata.title ?? `Threads post by @${parsed.actor}`,
    description: content,
    siteName: metadata.siteName ?? "Threads",
    content
  };
}

export function parseThreadsPostURL(rawUrl) {
  let url;
  try {
    url = new URL(rawUrl);
  } catch {
    return null;
  }
  if (!THREADS_HOSTS.has(url.hostname.toLowerCase())) return null;

  const parts = url.pathname.split("/").filter(Boolean).map(decodeURIComponent);
  if (
    parts.length !== 3 ||
    !parts[0].startsWith("@") ||
    parts[1] !== "post" ||
    !parts[2]
  ) {
    return null;
  }
  return { actor: parts[0].slice(1), postID: parts[2] };
}
