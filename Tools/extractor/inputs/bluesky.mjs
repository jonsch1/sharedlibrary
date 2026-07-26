const BLUESKY_HOSTS = new Set(["bsky.app", "www.bsky.app"]);

export const blueskyInput = {
  id: "bluesky",
  sourceType: "social-post",
  fallbackToGeneric: false,
  matches(rawUrl) {
    return parseBlueskyPostURL(rawUrl) !== null;
  },
  extract: fetchBlueskyPost
};

export async function fetchBlueskyPost(rawUrl, { fetchImpl = fetch } = {}) {
  const parsed = parseBlueskyPostURL(rawUrl);
  if (!parsed) return null;

  const did = parsed.actor.startsWith("did:")
    ? parsed.actor
    : await resolveBlueskyHandle(parsed.actor, fetchImpl);
  const uri = `at://${did}/app.bsky.feed.post/${parsed.rkey}`;
  const threadURL = new URL(
    "https://public.api.bsky.app/xrpc/app.bsky.feed.getPostThread"
  );
  threadURL.searchParams.set("uri", uri);
  threadURL.searchParams.set("depth", "0");

  const data = await fetchJSON(threadURL, fetchImpl);
  const post = data?.thread?.post;
  const record = post?.record;
  if (
    !post ||
    record?.$type !== "app.bsky.feed.post" ||
    typeof record.text !== "string"
  ) {
    throw new Error("Bluesky post not found.");
  }

  const author = post.author ?? {};
  const displayName = cleanText(author.displayName);
  const handle = cleanText(author.handle) || parsed.actor;
  const authorLine = displayName ? `${displayName} (@${handle})` : `@${handle}`;
  const text = record.text.trim();
  const stats = [
    countLabel(post.replyCount, "reply", "replies"),
    countLabel(post.repostCount, "repost", "reposts"),
    countLabel(post.quoteCount, "quote", "quotes"),
    countLabel(post.likeCount, "like", "likes"),
    countLabel(post.bookmarkCount, "bookmark", "bookmarks")
  ].filter(Boolean);
  const content = [
    authorLine,
    cleanText(record.createdAt),
    "",
    text,
    "",
    stats.length ? stats.join(" | ") : null,
    post.uri ? `Bluesky URI: ${post.uri}` : null,
    post.cid ? `CID: ${post.cid}` : null
  ]
    .filter((line) => line !== null && line !== undefined)
    .join("\n");

  return {
    url: rawUrl,
    title: `Bluesky post by ${authorLine}${text ? `: ${truncate(text, 90)}` : ""}`,
    description: text || null,
    siteName: "Bluesky",
    content
  };
}

export function parseBlueskyPostURL(rawUrl) {
  let url;
  try {
    url = new URL(rawUrl);
  } catch {
    return null;
  }
  if (!BLUESKY_HOSTS.has(url.hostname.toLowerCase())) return null;

  const parts = url.pathname.split("/").filter(Boolean).map(decodeURIComponent);
  if (parts.length !== 4 || parts[0] !== "profile" || parts[2] !== "post") {
    return null;
  }
  return { actor: parts[1], rkey: parts[3] };
}

async function resolveBlueskyHandle(handle, fetchImpl) {
  const url = new URL(
    "https://public.api.bsky.app/xrpc/com.atproto.identity.resolveHandle"
  );
  url.searchParams.set("handle", handle);
  const data = await fetchJSON(url, fetchImpl);
  if (typeof data?.did !== "string" || !data.did) {
    throw new Error(`Could not resolve Bluesky handle: ${handle}`);
  }
  return data.did;
}

async function fetchJSON(url, fetchImpl) {
  const response = await fetchImpl(url, {
    headers: {
      "Accept": "application/json",
      "User-Agent": "Briefly/1.0"
    }
  });
  if (!response.ok) {
    throw new Error(
      `Bluesky API request failed: ${response.status} ${response.statusText}`
    );
  }
  return response.json();
}

function cleanText(value) {
  return typeof value === "string" ? value.trim() : "";
}

function countLabel(value, singular, plural) {
  return Number.isInteger(value)
    ? `${value} ${value === 1 ? singular : plural}`
    : null;
}

function truncate(value, maximumLength) {
  return value.length <= maximumLength
    ? value
    : `${value.slice(0, maximumLength - 1).trimEnd()}…`;
}
