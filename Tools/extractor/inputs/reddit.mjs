import { fetchText } from "./http.mjs";

const REDDIT_HOSTS = new Set([
  "old.reddit.com",
  "reddit.com",
  "www.reddit.com"
]);

export const redditInput = {
  id: "reddit",
  sourceType: "social-post",
  fallbackToGeneric: false,
  matches(rawUrl) {
    return parseRedditPostURL(rawUrl) !== null;
  },
  extract: extractReddit
};

export async function extractReddit(rawUrl, context = {}) {
  const post = parseRedditPostURL(rawUrl);
  if (!post) return null;

  try {
    const fetched = await fetchText(post.jsonURL, {
      ...context,
      headers: {
        ...context.headers,
        Accept: "application/json",
        "User-Agent": "Briefly/1.0"
      }
    });
    return redditJSONResult(rawUrl, JSON.parse(fetched.text));
  } catch {
    const fetched = await fetchText(
      `https://www.reddit.com/oembed?url=${encodeURIComponent(rawUrl)}`,
      {
        ...context,
        headers: { ...context.headers, Accept: "application/json" }
      }
    );
    const data = JSON.parse(fetched.text);
    const title = cleanText(data.title);
    const author = cleanText(data.author_name);
    if (!title) throw new Error("Reddit did not return readable post metadata.");
    return {
      url: rawUrl,
      title,
      description: author ? `Posted by u/${author}` : null,
      siteName: "Reddit",
      content: [author ? `Posted by u/${author}` : "", title]
        .filter(Boolean)
        .join("\n\n")
    };
  }
}

export function parseRedditPostURL(rawUrl) {
  let url;
  try {
    url = new URL(rawUrl);
  } catch {
    return null;
  }
  const host = url.hostname.toLowerCase();
  let postID = "";
  if (host === "redd.it") {
    postID = url.pathname.split("/").filter(Boolean)[0] ?? "";
  } else if (REDDIT_HOSTS.has(host)) {
    postID =
      url.pathname.match(/\/comments\/([a-z0-9]+)(?:\/|$)/iu)?.[1] ?? "";
  }
  if (!postID) return null;
  return {
    postID,
    jsonURL:
      `https://www.reddit.com/comments/${postID}.json` +
      "?raw_json=1&limit=20&depth=2&sort=top"
  };
}

function redditJSONResult(rawUrl, listings) {
  const post =
    listings?.[0]?.data?.children?.find(({ kind }) => kind === "t3")?.data;
  if (!post?.title) throw new Error("Reddit did not return a readable post.");

  const body = cleanBody(post.selftext);
  const linkedURL =
    typeof post.url_overridden_by_dest === "string"
      ? post.url_overridden_by_dest
      : "";
  const comments = flattenComments(listings?.[1]?.data?.children ?? []).slice(0, 20);
  const content = [
    [
      post.author ? `Posted by u/${post.author}` : "",
      post.subreddit_name_prefixed ? `in ${post.subreddit_name_prefixed}` : ""
    ].filter(Boolean).join(" "),
    body || (linkedURL ? `[Open linked content](${linkedURL})` : ""),
    comments.length
      ? `## Top comments\n\n${comments.map(({ author, body: comment }) =>
          `**u/${author}**\n\n${comment}`).join("\n\n")}`
      : ""
  ].filter(Boolean).join("\n\n");

  return {
    url: rawUrl,
    canonicalURL:
      typeof post.permalink === "string"
        ? new URL(post.permalink, "https://www.reddit.com").toString()
        : null,
    title: cleanText(post.title),
    description: body ? cleanText(body).slice(0, 280) : null,
    siteName: "Reddit",
    content
  };
}

function flattenComments(children, output = []) {
  for (const child of children) {
    if (child?.kind !== "t1") continue;
    const body = cleanBody(child.data?.body);
    const author = cleanText(child.data?.author);
    if (body && author && !["[deleted]", "[removed]"].includes(body)) {
      output.push({ author, body });
    }
    const replies = child.data?.replies?.data?.children;
    if (Array.isArray(replies)) flattenComments(replies, output);
  }
  return output;
}

function cleanBody(value) {
  return typeof value === "string" ? value.trim() : "";
}

function cleanText(value) {
  return typeof value === "string" ? value.replace(/\s+/gu, " ").trim() : "";
}
