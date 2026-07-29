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
