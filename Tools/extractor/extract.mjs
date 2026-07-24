#!/usr/bin/env node
import { createLinkPreviewClient } from "@steipete/summarize-core/content";
import { fetchXContent } from "./x-article.mjs";

const url = process.argv[2]?.trim();

if (!url) {
  console.error("Usage: node extract.mjs <url>");
  process.exit(2);
}

const requestedFirecrawlMode = (
  process.env.BRIEFLY_FIRECRAWL_MODE ??
  process.env.SHARED_LIBRARY_FIRECRAWL_MODE
)?.trim();
const firecrawlMode = ["off", "auto", "always"].includes(requestedFirecrawlMode)
  ? requestedFirecrawlMode
  : process.env.FIRECRAWL_API_KEY
    ? "auto"
    : "off";
const includeTranscriptTimestamps =
  parseBoolean(
    process.env.BRIEFLY_TRANSCRIPT_TIMESTAMPS ??
      process.env.SHARED_LIBRARY_TRANSCRIPT_TIMESTAMPS
  ) ?? false;

const client = createLinkPreviewClient({
  env: process.env,
  onProgress(event) {
    if (event.kind === "fetch-html-start") {
      console.error(`fetching ${event.url}`);
    }
    if (event.kind === "transcript-start") {
      console.error(event.hint ?? `transcript ${event.service}`);
    }
  }
});

try {
  let xContent = null;
  try {
    xContent = await fetchXContent(url);
  } catch (error) {
    console.error(`X lookup failed; using standard extraction: ${error instanceof Error ? error.message : String(error)}`);
  }

  const extracted = xContent ?? await fetchBlueskyPost(url) ?? await client.fetchLinkContent(url, {
    format: "text",
    firecrawl: firecrawlMode,
    transcriptTimestamps: includeTranscriptTimestamps,
    youtubeTranscript: "auto",
    mediaTranscript: "auto",
    embeddedVideo: "auto",
    timeoutMs: 120000
  });
  process.stdout.write(`${JSON.stringify(extracted)}\n`);
} catch (error) {
  console.error(error instanceof Error ? error.message : String(error));
  process.exit(1);
}

async function fetchBlueskyPost(rawUrl) {
  const parsed = parseBlueskyPostUrl(rawUrl);
  if (!parsed) {
    return null;
  }

  const did = parsed.actor.startsWith("did:")
    ? parsed.actor
    : await resolveBlueskyHandle(parsed.actor);
  const uri = `at://${did}/app.bsky.feed.post/${parsed.rkey}`;
  const threadUrl = new URL("https://public.api.bsky.app/xrpc/app.bsky.feed.getPostThread");
  threadUrl.searchParams.set("uri", uri);
  threadUrl.searchParams.set("depth", "0");

  const data = await fetchJson(threadUrl);
  const post = data?.thread?.post;
  const record = post?.record;
  if (!post || record?.$type !== "app.bsky.feed.post" || typeof record.text !== "string") {
    throw new Error("Bluesky post not found.");
  }

  const author = post.author ?? {};
  const displayName = cleanText(author.displayName);
  const handle = cleanText(author.handle) || parsed.actor;
  const authorLine = displayName ? `${displayName} (@${handle})` : `@${handle}`;
  const createdAt = cleanText(record.createdAt);
  const text = record.text.trim();
  const titleText = text ? `: ${truncate(text, 90)}` : "";
  const stats = [
    countLabel(post.replyCount, "reply", "replies"),
    countLabel(post.repostCount, "repost", "reposts"),
    countLabel(post.quoteCount, "quote", "quotes"),
    countLabel(post.likeCount, "like", "likes"),
    countLabel(post.bookmarkCount, "bookmark", "bookmarks")
  ].filter(Boolean);
  const content = [
    authorLine,
    createdAt,
    "",
    text,
    "",
    stats.length ? stats.join(" | ") : null,
    post.uri ? `Bluesky URI: ${post.uri}` : null,
    post.cid ? `CID: ${post.cid}` : null
  ].filter((line) => line !== null && line !== undefined).join("\n");

  return {
    url: rawUrl,
    title: `Bluesky post by ${authorLine}${titleText}`,
    description: text,
    siteName: "Bluesky",
    content,
    wordCount: countWords(content),
    totalCharacters: content.length
  };
}

function parseBlueskyPostUrl(rawUrl) {
  let parsed;
  try {
    parsed = new URL(rawUrl);
  } catch {
    return null;
  }

  if (!["bsky.app", "www.bsky.app"].includes(parsed.hostname)) {
    return null;
  }

  const parts = parsed.pathname.split("/").filter(Boolean).map(decodeURIComponent);
  if (parts.length !== 4 || parts[0] !== "profile" || parts[2] !== "post") {
    return null;
  }

  return { actor: parts[1], rkey: parts[3] };
}

async function resolveBlueskyHandle(handle) {
  const url = new URL("https://public.api.bsky.app/xrpc/com.atproto.identity.resolveHandle");
  url.searchParams.set("handle", handle);
  const data = await fetchJson(url);
  if (typeof data?.did !== "string" || data.did.length === 0) {
    throw new Error(`Could not resolve Bluesky handle: ${handle}`);
  }
  return data.did;
}

async function fetchJson(url) {
  const response = await fetch(url, {
    headers: {
      "Accept": "application/json",
      "User-Agent": "Briefly/1.0"
    }
  });
  if (!response.ok) {
    throw new Error(`Bluesky API request failed: ${response.status} ${response.statusText}`);
  }
  return response.json();
}

function cleanText(value) {
  return typeof value === "string" ? value.trim() : "";
}

function countLabel(value, singular, plural) {
  return Number.isInteger(value) ? `${value} ${value === 1 ? singular : plural}` : null;
}

function countWords(value) {
  return value.split(/\s+/u).filter(Boolean).length;
}

function truncate(value, maxLength) {
  if (value.length <= maxLength) {
    return value;
  }
  return `${value.slice(0, maxLength - 1).trimEnd()}...`;
}

function parseBoolean(value) {
  if (typeof value !== "string") {
    return null;
  }
  const normalized = value.trim().toLowerCase();
  if (["1", "true", "yes", "on"].includes(normalized)) {
    return true;
  }
  if (["0", "false", "no", "off"].includes(normalized)) {
    return false;
  }
  return null;
}
