const X_HOSTS = new Set([
  "x.com",
  "www.x.com",
  "mobile.x.com",
  "twitter.com",
  "www.twitter.com",
  "mobile.twitter.com"
]);

export function parseXStatusUrl(rawUrl) {
  let parsed;
  try {
    parsed = new URL(rawUrl);
  } catch {
    return null;
  }

  if (!X_HOSTS.has(parsed.hostname.toLowerCase())) {
    return null;
  }

  const parts = parsed.pathname.split("/").filter(Boolean).map(decodeURIComponent);
  const statusIndex = parts.findIndex((part, index) => index > 0 && part.toLowerCase() === "status");
  const postID = statusIndex >= 0 ? parts[statusIndex + 1] : null;
  if (!postID || !/^\d+$/u.test(postID)) {
    return null;
  }

  const actor = parts[statusIndex - 1];
  return {
    actor,
    postID,
    apiUrl: `https://api.fxtwitter.com/${encodeURIComponent(actor)}/status/${postID}`
  };
}

export async function fetchXContent(rawUrl, { fetchImpl = fetch } = {}) {
  const parsed = parseXStatusUrl(rawUrl);
  if (!parsed) {
    return null;
  }

  const response = await fetchImpl(parsed.apiUrl, {
    headers: {
      "Accept": "application/json",
      "User-Agent": "Briefly/1.0"
    }
  });
  if (!response.ok) {
    throw new Error(`X metadata request failed: ${response.status} ${response.statusText}`);
  }

  const payload = await response.json();
  return payload?.tweet?.article
    ? xArticleToExtractedContent(rawUrl, payload)
    : xPostToExtractedContent(rawUrl, payload);
}

export const xInput = {
  id: "x",
  sourceType: "social-post",
  fallbackToGeneric: true,
  matches(rawUrl) {
    return parseXStatusUrl(rawUrl) !== null;
  },
  extract(rawUrl, context = {}) {
    return fetchXContent(rawUrl, context);
  }
};

export function xArticleToExtractedContent(rawUrl, payload) {
  const tweet = payload?.tweet;
  const article = tweet?.article;
  if (!article || typeof article.title !== "string") {
    throw new Error("X Article response did not contain a valid article.");
  }

  const body = renderArticle(article);
  if (!body) {
    throw new Error("X Article response did not contain readable content.");
  }

  return {
    url: rawUrl,
    title: cleanArticleText(article.title),
    description: cleanArticleText(article.preview_text) || null,
    siteName: "X",
    content: body,
    wordCount: countWords(body),
    totalCharacters: body.length
  };
}

export function xPostToExtractedContent(rawUrl, payload) {
  const tweet = payload?.tweet;
  if (!tweet || typeof tweet !== "object") {
    throw new Error("X response did not contain a post.");
  }

  const text = cleanArticleText(
    typeof tweet.raw_text === "string"
      ? tweet.raw_text
      : typeof tweet.raw_text?.text === "string"
        ? tweet.raw_text.text
        : tweet.text
  );
  const authorName = cleanArticleText(tweet.author?.name);
  const screenName = cleanArticleText(tweet.author?.screen_name);
  const author = authorName && screenName
    ? `${authorName} (@${screenName})`
    : authorName || (screenName ? `@${screenName}` : "X user");
  const quotedText = cleanArticleText(
    typeof tweet.quote?.raw_text === "string"
      ? tweet.quote.raw_text
      : typeof tweet.quote?.raw_text?.text === "string"
        ? tweet.quote.raw_text.text
        : tweet.quote?.text
  );
  const quotedScreenName = cleanArticleText(tweet.quote?.author?.screen_name);
  const stats = [
    countLabel(tweet.replies, "reply", "replies"),
    countLabel(tweet.retweets, "repost", "reposts"),
    countLabel(tweet.likes, "like", "likes"),
    countLabel(tweet.bookmarks, "bookmark", "bookmarks"),
    countLabel(tweet.views, "view", "views")
  ].filter(Boolean);
  const cardURL = cleanArticleText(
    tweet.twitter_card?.url
      ?? tweet.twitter_card?.card_url
      ?? tweet.twitter_card?.binding_values?.card_url?.string_value
  );

  const content = [
    author,
    cleanArticleText(tweet.created_at),
    "",
    text || "[Media post]",
    tweet.replying_to
      ? `Replying to @${cleanArticleText(tweet.replying_to)}`
      : null,
    quotedText
      ? `\n> ${quotedScreenName ? `@${quotedScreenName}: ` : ""}${quotedText.replaceAll("\n", "\n> ")}`
      : null,
    cardURL ? `\nLink: ${cardURL}` : null,
    stats.length ? `\n${stats.join(" · ")}` : null
  ]
    .filter((line) => line !== null && line !== undefined)
    .join("\n")
    .trim();

  return {
    url: rawUrl,
    title: `Post by ${author}${text ? `: ${truncate(text, 90)}` : ""}`,
    description: text || null,
    siteName: "X",
    content,
    wordCount: countWords(content),
    totalCharacters: content.length
  };
}

function renderArticle(article) {
  const blocks = Array.isArray(article.content?.blocks) ? article.content.blocks : [];
  const entities = normalizeEntityMap(article.content?.entityMap);
  const mediaURLs = new Map(
    (Array.isArray(article.media_entities) ? article.media_entities : [])
      .map((media) => [String(media?.media_id ?? ""), cleanText(media?.media_info?.original_img_url)])
      .filter(([mediaID, mediaURL]) => mediaID && mediaURL)
  );

  const renderedBlocks = [];
  const coverURL = cleanText(article.cover_media?.media_info?.original_img_url);
  if (coverURL) {
    renderedBlocks.push(`![Cover image](${markdownURL(coverURL)})`);
  }

  for (const block of blocks) {
    const rendered = renderBlock(block, entities, mediaURLs);
    if (rendered) {
      renderedBlocks.push(rendered);
    }
  }

  return cleanArticleText(renderedBlocks.join("\n\n"));
}

function renderBlock(block, entities, mediaURLs) {
  const type = cleanText(block?.type) || "unstyled";
  if (type === "atomic") {
    return renderAtomicBlock(block, entities, mediaURLs);
  }

  const text = renderInlineText(block, entities);
  if (!text) {
    return "";
  }

  const headingLevels = {
    "header-one": 1,
    "header-two": 2,
    "header-three": 3,
    "header-four": 4,
    "header-five": 5,
    "header-six": 6
  };
  if (headingLevels[type]) {
    return `${"#".repeat(headingLevels[type])} ${text}`;
  }

  const indentation = "  ".repeat(Number.isInteger(block?.depth) ? Math.max(0, block.depth) : 0);
  if (type === "unordered-list-item") {
    return `${indentation}- ${text}`;
  }
  if (type === "ordered-list-item") {
    return `${indentation}1. ${text}`;
  }
  if (type === "blockquote") {
    return text.split("\n").map((line) => `> ${line}`).join("\n");
  }
  if (type === "code-block") {
    const fence = text.includes("```") ? "````" : "```";
    return `${fence}\n${text}\n${fence}`;
  }

  return text;
}

function renderAtomicBlock(block, entities, mediaURLs) {
  const media = [];
  for (const range of Array.isArray(block?.entityRanges) ? block.entityRanges : []) {
    const entity = entities.get(String(range?.key));
    if (entity?.type !== "MEDIA") {
      continue;
    }

    for (const item of Array.isArray(entity.data?.mediaItems) ? entity.data.mediaItems : []) {
      const mediaURL = mediaURLs.get(String(item?.mediaId ?? ""));
      if (mediaURL) {
        media.push(`![Article image](${markdownURL(mediaURL)})`);
      }
    }
  }
  return [...new Set(media)].join("\n\n");
}

function renderInlineText(block, entities) {
  const value = typeof block?.text === "string" ? block.text : "";
  if (!value) {
    return "";
  }

  const styleRanges = validRanges(block.inlineStyleRanges, value.length)
    .map((range) => ({ ...range, value: cleanText(range.value ?? range.style).toUpperCase() }))
    .filter((range) => range.value);
  const entityRanges = validRanges(block.entityRanges, value.length)
    .map((range) => ({ ...range, entity: entities.get(String(range.key)) }))
    .filter((range) => range.entity);

  const boundaries = new Set([0, value.length]);
  for (const range of [...styleRanges, ...entityRanges]) {
    boundaries.add(range.offset);
    boundaries.add(range.offset + range.length);
  }
  const sortedBoundaries = [...boundaries].sort((left, right) => left - right);

  const segments = [];
  for (let index = 0; index < sortedBoundaries.length - 1; index += 1) {
    const start = sortedBoundaries[index];
    const end = sortedBoundaries[index + 1];
    const styles = styleRanges
      .filter((range) => range.offset <= start && range.offset + range.length >= end)
      .map((range) => range.value)
      .sort();
    const link = entityRanges.find((range) =>
      range.offset <= start
      && range.offset + range.length >= end
      && range.entity?.type === "LINK"
      && cleanText(range.entity?.data?.url)
    )?.entity?.data?.url;
    const signature = `${styles.join(",")}|${link ?? ""}`;
    const text = value.slice(start, end);

    if (segments.at(-1)?.signature === signature) {
      segments.at(-1).text += text;
    } else {
      segments.push({ signature, text, styles, link });
    }
  }

  return segments.map(renderInlineSegment).join("");
}

function renderInlineSegment(segment) {
  if (!segment.text || !segment.text.trim()) {
    return segment.text;
  }

  const leadingWhitespace = segment.text.match(/^\s*/u)?.[0] ?? "";
  const trailingWhitespace = segment.text.match(/\s*$/u)?.[0] ?? "";
  let content = segment.text.slice(
    leadingWhitespace.length,
    segment.text.length - trailingWhitespace.length
  );

  if (segment.styles.includes("CODE") || segment.styles.includes("MONOSPACE")) {
    const marker = content.includes("`") ? "``" : "`";
    content = `${marker}${content}${marker}`;
  }
  if (segment.styles.includes("BOLD")) {
    content = `**${content}**`;
  }
  if (segment.styles.includes("ITALIC")) {
    content = `_${content}_`;
  }
  if (segment.styles.includes("STRIKETHROUGH")) {
    content = `~~${content}~~`;
  }
  if (segment.styles.includes("UNDERLINE")) {
    content = `<u>${content}</u>`;
  }
  if (segment.link) {
    content = `[${content.replaceAll("]", "\\]")}](${markdownURL(segment.link)})`;
  }

  return `${leadingWhitespace}${content}${trailingWhitespace}`;
}

function normalizeEntityMap(rawEntityMap) {
  if (Array.isArray(rawEntityMap)) {
    return new Map(
      rawEntityMap
        .filter((entry) => entry && entry.key !== undefined && entry.value)
        .map((entry) => [String(entry.key), entry.value])
    );
  }
  if (rawEntityMap && typeof rawEntityMap === "object") {
    return new Map(Object.entries(rawEntityMap));
  }
  return new Map();
}

function validRanges(rawRanges, textLength) {
  return (Array.isArray(rawRanges) ? rawRanges : [])
    .map((range) => ({
      ...range,
      offset: Number(range?.offset),
      length: Number(range?.length)
    }))
    .filter((range) =>
      Number.isInteger(range.offset)
      && Number.isInteger(range.length)
      && range.offset >= 0
      && range.length > 0
      && range.offset + range.length <= textLength
    );
}

function markdownURL(value) {
  return cleanText(value).replaceAll("(", "%28").replaceAll(")", "%29");
}

function cleanText(value) {
  return typeof value === "string" ? value.trim() : "";
}

function cleanArticleText(value) {
  return cleanText(value).replace(/[\u200B-\u200D\u2060\uFEFF]/gu, "");
}

function countWords(value) {
  return value.split(/\s+/u).filter(Boolean).length;
}

function countLabel(value, singular, plural) {
  return Number.isFinite(Number(value))
    ? `${Number(value).toLocaleString("en-US")} ${Number(value) === 1 ? singular : plural}`
    : null;
}

function truncate(value, maxLength) {
  return value.length <= maxLength
    ? value
    : `${value.slice(0, maxLength - 1).trimEnd()}…`;
}
