import { createHash } from "node:crypto";
import { DOMParser, parseHTML } from "linkedom";

import { fetchText, isHTTPURL } from "./http.mjs";

const maximumItems = 100;

export async function discoverSource(rawSource, context = {}) {
  const sourceURL = normalizeSource(rawSource);
  const fetched = await fetchText(sourceURL, {
    ...context,
    maximumBytes: 20_000_000
  });
  const direct = parseFeed(fetched.text, fetched.finalURL);
  if (direct) {
    return {
      ...applyChannelPolicy(direct, fetched.finalURL),
      source: rawSource,
      sourceURL: fetched.finalURL
    };
  }
  const hackerNews = parseHackerNews(fetched.text, fetched.finalURL);
  if (hackerNews) {
    return { ...hackerNews, source: rawSource, sourceURL: fetched.finalURL };
  }

  const candidates = await feedCandidates(fetched.text, fetched.finalURL, context);
  for (const candidate of candidates) {
    try {
      const response = await fetchText(candidate, {
        ...context,
        maximumBytes: 20_000_000
      });
      const feed = parseFeed(response.text, response.finalURL);
      if (feed) {
        return {
          ...applyChannelPolicy(feed, fetched.finalURL),
          source: rawSource,
          sourceURL: fetched.finalURL,
          feedURL: response.finalURL
        };
      }
    } catch {
      // A broken discovery link should not stop the page-change fallback.
    }
  }

  const document = parseHTML(fetched.text).document;
  const title =
    document.querySelector('meta[property="og:title"]')?.getAttribute("content") ||
    document.querySelector("title")?.textContent?.trim() ||
    new URL(fetched.finalURL).hostname;
  return {
    source: rawSource,
    sourceURL: fetched.finalURL,
    title,
    kind: "page",
    items: [
      {
        id: createHash("sha256").update(fetched.text).digest("hex"),
        title,
        url: fetched.finalURL,
        publishedAt: null
      }
    ]
  };
}

export function applyChannelPolicy(discovered, rawChannelURL) {
  const url = new URL(rawChannelURL);
  const latestOnly =
    discovered.kind === "podcast" ||
    url.hostname === "podcasts.apple.com" ||
    url.hostname.endsWith("youtube.com");
  if (!latestOnly || discovered.items.length < 2) return discovered;
  const latest = discovered.items
    .map((item, index) => ({ item, index, time: Date.parse(item.publishedAt ?? "") }))
    .sort((left, right) =>
      Number.isFinite(left.time) && Number.isFinite(right.time)
        ? right.time - left.time
        : left.index - right.index
    )[0].item;
  return { ...discovered, items: [latest] };
}

export function parseHackerNews(html, rawURL) {
  const url = new URL(rawURL);
  if (url.hostname !== "news.ycombinator.com" || url.pathname !== "/front") {
    return null;
  }
  const document = parseHTML(html).document;
  const items = [...document.querySelectorAll("tr.athing")]
    .flatMap((row) => {
      const link = row.querySelector(".titleline > a");
      const itemURL = absoluteHTTPURL(link?.getAttribute("href"), rawURL);
      return itemURL
        ? [{
            id: row.getAttribute("id") || itemURL,
            title: link.textContent?.trim() || itemURL,
            url: itemURL,
            publishedAt: null
          }]
        : [];
    })
    .slice(0, 5);
  return items.length
    ? { title: "Hacker News front page", kind: "feed", items }
    : null;
}

export function normalizeSource(value) {
  const source = String(value ?? "").trim();
  if (/^arxiv:/iu.test(source)) {
    const query = source.slice(source.indexOf(":") + 1).trim();
    if (!query) throw new Error("An arXiv source needs a search query.");
    const url = new URL("https://export.arxiv.org/api/query");
    url.searchParams.set("search_query", `all:${query}`);
    url.searchParams.set("start", "0");
    url.searchParams.set("max_results", "50");
    url.searchParams.set("sortBy", "submittedDate");
    url.searchParams.set("sortOrder", "descending");
    return url.toString();
  }
  if (!isHTTPURL(source)) {
    throw new Error("Podcast sources must be HTTP(S) URLs or arxiv: queries.");
  }
  return source;
}

export function parseFeed(xml, feedURL) {
  if (!/<(?:rss|feed)\b/iu.test(xml)) return null;
  const document = new DOMParser().parseFromString(xml, "text/xml");
  const channel = document.querySelector("channel");
  const atom = document.documentElement?.tagName?.toLowerCase().endsWith("feed");
  if (!channel && !atom) return null;

  const root = channel ?? document.documentElement;
  const elements = channel
    ? [...channel.querySelectorAll("item")]
    : [...root.querySelectorAll("entry")];
  const items = elements
    .map((element) => {
      const link = channel
        ? childText(element, "link")
        : [...element.children]
            .find((child) => {
              if (!child.tagName.toLowerCase().endsWith("link")) return false;
              const relation = child.getAttribute("rel");
              return !relation || relation === "alternate";
            })
            ?.getAttribute("href");
      const url = absoluteHTTPURL(link, feedURL);
      const id =
        childText(element, channel ? "guid" : "id") ||
        url ||
        createHash("sha256")
          .update(
            [
              childText(element, "title"),
              childText(element, channel ? "pubdate" : "published") ||
                childText(element, "updated")
            ].join("\n")
          )
          .digest("hex");
      if (!url) return null;
      return {
        id,
        title: childText(element, "title") || url,
        url,
        publishedAt:
          validDate(
            childText(element, channel ? "pubdate" : "published") ||
              childText(element, "updated") ||
              childText(element, "dc:date")
          ) ?? null
      };
    })
    .filter(Boolean)
    .slice(0, maximumItems);
  if (!items.length) return null;
  return {
    title: childText(root, "title") || new URL(feedURL).hostname,
    kind: channel && /<enclosure\b[^>]*\btype=["']audio\//iu.test(xml)
      ? "podcast"
      : "feed",
    feedURL,
    items
  };
}

async function feedCandidates(html, rawURL, context) {
  const document = parseHTML(html).document;
  const candidates = [
    ...document.querySelectorAll(
      'link[rel~="alternate"][type*="rss"], link[rel~="alternate"][type*="atom"]'
    )
  ]
    .map((element) => absoluteHTTPURL(element.getAttribute("href"), rawURL))
    .filter(Boolean);

  const youtubeID =
    document.querySelector('meta[itemprop="channelId"]')?.getAttribute("content") ||
    /["']channelId["']\s*:\s*["']([^"']+)["']/u.exec(html)?.[1];
  if (youtubeID) {
    candidates.unshift(
      `https://www.youtube.com/feeds/videos.xml?channel_id=${encodeURIComponent(youtubeID)}`
    );
  }

  const url = new URL(rawURL);
  if (url.hostname.toLowerCase() === "podcasts.apple.com") {
    const showID = url.pathname.match(/\/id(\d+)(?:\/|$)/u)?.[1];
    if (showID) {
      try {
        const lookup = await fetchText(
          `https://itunes.apple.com/lookup?id=${showID}&entity=podcast`,
          { ...context, maximumBytes: 2_000_000 }
        );
        const value = JSON.parse(lookup.text);
        const feedURL = (Array.isArray(value?.results) ? value.results : []).find(
          (result) => result?.kind === "podcast" && typeof result.feedUrl === "string"
        )?.feedUrl;
        if (absoluteHTTPURL(feedURL, rawURL)) candidates.unshift(feedURL);
      } catch {
        // The ordinary discovery candidates and page fallback remain usable.
      }
    }
  }
  return [...new Set(candidates)].slice(0, 5);
}

function childText(element, tagName) {
  const normalized = tagName.toLowerCase();
  const child = [...element.children].find(
    (candidate) => candidate.tagName.toLowerCase() === normalized
  );
  return child?.textContent?.replace(/\s+/gu, " ").trim() ?? "";
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

function validDate(value) {
  if (!value || Number.isNaN(Date.parse(value))) return null;
  return new Date(value).toISOString();
}
