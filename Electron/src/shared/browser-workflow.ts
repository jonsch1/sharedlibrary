export function cleanRepeatedItems(values: string[]): string[] {
  const items = values
    .map((value) => value.split(/\r?\n/u).map((line) => line.trim()).filter(Boolean))
    .filter((lines) => lines.length);
  if (items.length < 2) return items.map((lines) => lines.join('\n'));
  const common = items
    .slice(1)
    .reduce(
      (lines, item) => new Set([...lines].filter((line) => item.includes(line))),
      new Set(items[0])
    );
  const cleaned = items.map((lines) => lines.filter((line) => !common.has(line)));
  return (cleaned.some((lines) => lines.length) ? cleaned : items)
    .map((lines) => lines.join('\n'));
}

export function xProfileURL(value: string): string | null {
  try {
    const url = new URL(value);
    const parts = url.pathname.split('/').filter(Boolean);
    return ['x.com', 'www.x.com', 'twitter.com', 'www.twitter.com'].includes(
      url.hostname.toLowerCase()
    ) &&
      parts.length === 1 &&
      /^[A-Za-z0-9_]{1,15}$/u.test(parts[0])
      ? `https://x.com/${parts[0]}`
      : null;
  } catch {
    return null;
  }
}

export interface XProfilePost {
  id: string;
  url: string;
  text: string;
  publishedAt: string | null;
  pinned?: boolean;
}

export function xChannelItems(posts: XProfilePost[], handle: string) {
  const seen = new Set<string>();
  const unique = posts.filter((post) => {
    if (post.pinned || seen.has(post.id)) return false;
    seen.add(post.id);
    return true;
  });
  const ordered = unique.every(({ publishedAt }) =>
    Number.isFinite(Date.parse(publishedAt ?? ''))
  )
    ? unique.toSorted(
        (left, right) =>
          Date.parse(right.publishedAt ?? '') - Date.parse(left.publishedAt ?? '')
      )
    : unique;
  const selected = ordered.slice(0, 5);
  const cleaned = cleanRepeatedItems(selected.map(({ text }) => text));
  return selected.map((post, index) => ({
    id: post.id,
    title:
      cleaned[index]?.split('\n').find(Boolean)?.slice(0, 160) ||
      `@${handle} post`,
    url: post.url,
    publishedAt: post.publishedAt
  }));
}

export function redditCommunityFeedURL(value: string): string | null {
  try {
    const url = new URL(value);
    const match =
      ['reddit.com', 'www.reddit.com', 'old.reddit.com'].includes(
        url.hostname.toLowerCase()
      ) &&
      /^\/r\/([A-Za-z0-9_]+)(?:\/(hot|new|top))?\/?$/u.exec(url.pathname);
    return match
      ? `https://www.reddit.com/r/${match[1]}/${match[2] ?? 'hot'}/.rss?limit=5`
      : null;
  } catch {
    return null;
  }
}

export function redditChannelFromAtom(
  xml: string,
  source: string,
  feedURL: string
) {
  const community =
    /^\/r\/([^/]+)/u.exec(new URL(source).pathname)?.[1] ?? 'Reddit';
  const items = [...xml.matchAll(/<entry>([\s\S]*?)<\/entry>/giu)]
    .slice(0, 5)
    .flatMap(([, entry]) => {
      const id = xmlText(entry, 'id');
      const title = xmlText(entry, 'title');
      const url = decodeXML(
        /<link\b[^>]*\bhref="([^"]+)"/iu.exec(entry)?.[1] ?? ''
      );
      if (!id || !title || !url) return [];
      const html = decodeXML(xmlText(entry, 'content'));
      const linkedURL = [...html.matchAll(/\bhref="([^"]+)"/giu)]
        .map((match) => decodeXML(match[1]))
        .find((candidate) => {
          try {
            return !new URL(candidate).hostname.endsWith('reddit.com');
          } catch {
            return false;
          }
        });
      const author = xmlText(entry, 'name');
      return [{
        id: `${id}:headless-2`,
        title,
        url,
        publishedAt: validDate(xmlText(entry, 'published')),
        linkedURL,
        content: [
          `Reddit post in r/${community}`,
          author ? `Posted by ${author}` : '',
          linkedURL ? `Linked article: ${linkedURL}` : '',
          `Discussion: ${url}`
        ].filter(Boolean).join('\n\n')
      }];
    });
  if (!items.length) throw new Error('Reddit returned no readable posts.');
  return {
    source,
    sourceURL: source,
    feedURL,
    title: `r/${community}`,
    kind: 'feed' as const,
    items
  };
}

function xmlText(value: string, tag: string): string {
  return decodeXML(
    new RegExp(`<${tag}\\b[^>]*>([\\s\\S]*?)<\\/${tag}>`, 'iu')
      .exec(value)?.[1] ?? ''
  ).replace(/\s+/gu, ' ').trim();
}

function decodeXML(value: string): string {
  return value.replace(
    /&(#x[\da-f]+|#\d+|amp|apos|gt|lt|quot);/giu,
    (_, entity: string) => {
      const normalized = entity.toLowerCase();
      if (normalized.startsWith('#x')) {
        return String.fromCodePoint(Number.parseInt(normalized.slice(2), 16));
      }
      if (normalized.startsWith('#')) {
        return String.fromCodePoint(Number.parseInt(normalized.slice(1), 10));
      }
      return { amp: '&', apos: "'", gt: '>', lt: '<', quot: '"' }[normalized] ?? '';
    }
  );
}

function validDate(value: string): string | null {
  return value && Number.isFinite(Date.parse(value))
    ? new Date(value).toISOString()
    : null;
}
