import { DOMParser, parseHTML } from "linkedom";

import { fetchText } from "./http.mjs";

const PODCAST_NAMESPACE_URLS = new Set([
  "https://podcastindex.org/namespace/1.0",
  "https://github.com/Podcastindex-org/podcast-namespace/blob/main/docs/1.0.md"
]);
const TRANSCRIPT_TYPES = new Map([
  ["text/vtt", 4],
  ["text/html", 3],
  ["application/json", 2],
  ["application/x-subrip", 1],
  ["application/srt", 1],
  ["text/plain", 1]
]);

export async function extractPublishedPodcastTranscript(rawUrl, fetched, context = {}) {
  if (isPodcastFeed(fetched.text)) {
    const feed = parsePodcastFeed(fetched.text, fetched.finalURL);
    return feed ? podcastResult(rawUrl, feed, feed.items[0], context) : null;
  }
  if (!looksLikePodcastPage(fetched.text, fetched.finalURL)) return null;

  const page = podcastPage(fetched.text, fetched.finalURL);
  const appleFeedURL = await discoverAppleFeed(fetched.finalURL, context).catch(
    () => null
  );
  if (appleFeedURL) page.feedURLs.unshift(appleFeedURL);
  for (const feedURL of page.feedURLs) {
    try {
      const feedResponse = await fetchText(feedURL, {
        ...context,
        maximumBytes: 20_000_000
      });
      const feed = parsePodcastFeed(feedResponse.text, feedResponse.finalURL);
      const episode = matchingEpisode(feed?.items ?? [], page);
      if (feed && episode) {
        return podcastResult(rawUrl, feed, episode, context);
      }
    } catch {
      // A broken feed link should not prevent ordinary page extraction.
    }
  }
  return null;
}

export function parsePodcastFeed(xml, feedURL) {
  if (!isPodcastFeed(xml)) return null;
  const document = new DOMParser().parseFromString(xml, "text/xml");
  const channel = document.querySelector("channel");
  if (!channel) return null;
  const items = [...channel.querySelectorAll("item")].map((item) => ({
    title: childText(item, "title"),
    description: htmlText(
      childText(item, "content:encoded") ||
        childText(item, "description") ||
        childText(item, "itunes:summary")
    ),
    guid: childText(item, "guid"),
    link: absoluteHTTPURL(childText(item, "link"), feedURL),
    mediaURL: absoluteHTTPURL(
      item.querySelector("enclosure")?.getAttribute("url"),
      feedURL
    ),
    transcripts: [...item.querySelectorAll("*")]
      .filter(isPodcastTranscriptElement)
      .map((element) => ({
        language: cleanText(element.getAttribute("language")),
        type: transcriptType(element),
        url: absoluteHTTPURL(element.getAttribute("url"), feedURL)
      }))
      .filter((transcript) => transcript.url && TRANSCRIPT_TYPES.has(transcript.type))
      .sort(
        (left, right) =>
          TRANSCRIPT_TYPES.get(right.type) - TRANSCRIPT_TYPES.get(left.type)
      )
  }));

  return {
    title: childText(channel, "title"),
    items
  };
}

export function parseTranscript(text, type) {
  if (type === "text/html") return htmlText(text);
  if (type === "application/json") {
    const payload = JSON.parse(text);
    const segments = Array.isArray(payload?.segments) ? payload.segments : [];
    return segments
      .map((segment, index) => {
        const body = cleanText(segment?.body);
        if (!body) return "";
        const speaker = cleanText(segment?.speaker);
        const previousSpeaker = cleanText(segments[index - 1]?.speaker);
        return speaker && speaker !== previousSpeaker ? `${speaker}: ${body}` : body;
      })
      .filter(Boolean)
      .join(" ");
  }
  if (type === "text/vtt" || type === "application/x-subrip" || type === "application/srt") {
    return text
      .replace(/^\uFEFF?WEBVTT[^\n]*\n/iu, "")
      .split(/\r?\n\s*\r?\n/gu)
      .map((block) =>
        block
          .split(/\r?\n/gu)
          .filter(
            (line) =>
              !/^\d+$/u.test(line.trim()) &&
              !/^\s*(?:\d{1,2}:)?\d{2}:\d{2}[.,]\d{3}\s+-->/u.test(line)
          )
          .join(" ")
          .replace(/<v\s+([^>]+)>/giu, "$1: ")
          .replace(/<[^>]+>/gu, "")
          .trim()
      )
      .filter(Boolean)
      .join("\n");
  }
  return text.trim();
}

async function podcastResult(rawUrl, feed, episode, context) {
  if (!episode) return null;
  const transcript = episode.transcripts[0];
  let content = "Transcript unavailable for this podcast episode.";
  let transcriptAvailable = false;
  let transcriptLanguage = null;
  let transcriptError = null;
  if (transcript) {
    try {
      const response = await fetchText(transcript.url, {
        ...context,
        headers: {
          ...context.headers,
          "Accept": `${transcript.type},text/plain;q=0.9,*/*;q=0.1`
        },
        maximumBytes: 20_000_000
      });
      const transcriptText =
        response.text || new TextDecoder().decode(response.bytes);
      const parsed = cleanText(parseTranscript(transcriptText, transcript.type));
      if (!parsed) throw new Error("The published podcast transcript was empty.");
      content = `Transcript:\n${parsed}`;
      transcriptAvailable = true;
      transcriptLanguage = transcript.language || null;
    } catch (error) {
      transcriptError = error instanceof Error ? error.message : String(error);
    }
  }
  if (!transcriptAvailable && episode.mediaURL && context.transcribeMedia) {
    try {
      const fallback = await context.transcribeMedia(episode.mediaURL);
      content = `Transcript:\n${fallback.text}`;
      transcriptAvailable = true;
      transcriptLanguage = fallback.language;
      transcriptError = null;
    } catch (error) {
      transcriptError = error instanceof Error ? error.message : String(error);
    }
  }
  if (!transcriptAvailable && episode.description) {
    content += `\n\nDescription:\n${episode.description}`;
  }

  return {
    url: rawUrl,
    title: episode.title || feed.title || "Podcast episode",
    description: episode.description || null,
    faviconURL: new URL("/favicon.ico", episode.link || rawUrl).toString(),
    siteName: feed.title || null,
    content,
    mediaURL: episode.mediaURL,
    extractor: "podcast",
    sourceType: "podcast",
    transcriptAvailable,
    transcriptLanguage,
    transcriptError
  };
}

function isPodcastFeed(text) {
  return (
    /<rss\b/iu.test(text) &&
    /<item\b/iu.test(text) &&
    (/<(?:[\w.-]+:)?transcript\b/iu.test(text) ||
      /<enclosure\b[^>]*\btype=["']audio\//iu.test(text) ||
      /xmlns:itunes=/iu.test(text))
  );
}

function looksLikePodcastPage(html, rawUrl) {
  const hostname = new URL(rawUrl).hostname.toLowerCase();
  return (
    hostname === "podcasts.apple.com" ||
    /["']PodcastEpisode["']/iu.test(html) ||
    /<audio\b/iu.test(html) ||
    /property=["']og:(?:audio|type)["'][^>]*content=["'][^"']*(?:audio|podcast)/iu.test(
      html
    )
  );
}

function podcastPage(html, rawUrl) {
  const document = parseHTML(html).document;
  const metadataTitle =
    document.querySelector('meta[property="og:title"]')?.getAttribute("content") ||
    document.querySelector("title")?.textContent;
  const canonical =
    document.querySelector('link[rel="canonical"]')?.getAttribute("href") || rawUrl;
  const feedURLs = [
    ...document.querySelectorAll('link[rel~="alternate"][type*="rss"], a[href]')
  ]
    .filter((element) => {
      if (element.tagName.toLowerCase() === "link") return true;
      return /\brss\b/iu.test(element.textContent ?? "");
    })
    .map((element) => absoluteHTTPURL(element.getAttribute("href"), rawUrl))
    .filter(Boolean);
  return {
    canonicalURL: absoluteHTTPURL(canonical, rawUrl),
    feedURLs: [...new Set(feedURLs)].slice(0, 3),
    title: cleanTitle(metadataTitle)
  };
}

async function discoverAppleFeed(rawUrl, context) {
  const url = new URL(rawUrl);
  if (url.hostname.toLowerCase() !== "podcasts.apple.com") return null;
  const showID = url.pathname.match(/\/id(\d+)(?:\/|$)/u)?.[1];
  if (!showID) return null;
  const response = await fetchText(
    `https://itunes.apple.com/lookup?id=${showID}&entity=podcast`,
    {
      ...context,
      maximumBytes: 2_000_000
    }
  );
  const payload = JSON.parse(response.text);
  const feedURL = (Array.isArray(payload?.results) ? payload.results : []).find(
    (result) => result?.kind === "podcast" && typeof result.feedUrl === "string"
  )?.feedUrl;
  return absoluteHTTPURL(feedURL, rawUrl);
}

function matchingEpisode(items, page) {
  return items
    .map((item) => ({
      item,
      score:
        (sameURL(item.link, page.canonicalURL) ? 10 : 0) +
        (cleanTitle(item.title) === page.title ? 5 : 0) +
        (page.canonicalURL && item.guid?.includes(page.canonicalURL) ? 2 : 0)
    }))
    .sort((left, right) => right.score - left.score)
    .find((candidate) => candidate.score > 0)?.item;
}

function isPodcastTranscriptElement(element) {
  const [prefix, name] = element.tagName.toLowerCase().split(":");
  if (!name || name !== "transcript") return false;
  for (let current = element; current; current = current.parentElement) {
    const namespace = current.getAttribute?.(`xmlns:${prefix}`);
    if (PODCAST_NAMESPACE_URLS.has(namespace)) return true;
  }
  return prefix === "podcast";
}

function transcriptType(element) {
  const declared = cleanText(element.getAttribute("type")).toLowerCase();
  if (declared) return declared.split(";")[0];
  const path = cleanText(element.getAttribute("url")).toLowerCase();
  if (path.endsWith(".vtt")) return "text/vtt";
  if (path.endsWith(".srt")) return "application/x-subrip";
  if (path.endsWith(".json")) return "application/json";
  if (path.endsWith(".html") || path.endsWith(".htm")) return "text/html";
  return "text/plain";
}

function childText(element, tagName) {
  const child = [...element.children].find(
    (candidate) => candidate.tagName.toLowerCase() === tagName
  );
  return cleanText(child?.textContent);
}

function htmlText(value) {
  if (!value) return "";
  return cleanText(
    parseHTML(`<!doctype html><html><body>${value}</body></html>`).document.body
      ?.textContent
  );
}

function sameURL(left, right) {
  if (!left || !right) return false;
  try {
    const normalize = (value) => {
      const url = new URL(value);
      url.hash = "";
      url.searchParams.sort();
      return url.toString().replace(/\/$/u, "");
    };
    return normalize(left) === normalize(right);
  } catch {
    return false;
  }
}

function absoluteHTTPURL(value, baseURL) {
  if (!value) return null;
  try {
    const url = new URL(value, baseURL);
    return url.protocol === "http:" || url.protocol === "https:"
      ? url.toString()
      : null;
  } catch {
    return null;
  }
}

function cleanTitle(value) {
  return cleanText(value).replace(/\s*[|–—-]\s*(?:Apple )?Podcasts?$/iu, "");
}

function cleanText(value) {
  return typeof value === "string"
    ? value
        .replace(/\u00a0/gu, " ")
        .replace(/[ \t]+/gu, " ")
        .replace(/\n{3,}/gu, "\n\n")
        .trim()
    : "";
}
