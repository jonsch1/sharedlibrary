import type { LibraryVariant } from './contracts.js';

const youtubeVideoPath = /^\/(?:embed|live|shorts|v)\/[^/]+/;

export function shouldRenderSourceAsPlainText(
  variant: LibraryVariant,
  sourceURL?: string
): boolean {
  return variant === 'source' && Boolean(youtubeVideoID(sourceURL));
}

function youtubeVideoID(value?: string): string | undefined {
  if (!value) return undefined;

  try {
    const url = new URL(value);
    if (url.protocol !== 'http:' && url.protocol !== 'https:') return undefined;

    const hostname = url.hostname.toLowerCase().replace(/\.$/, '');
    if (hostname === 'youtu.be') {
      return url.pathname.split('/').filter(Boolean)[0];
    }

    const isYouTubeHost =
      hostname === 'youtube.com' ||
      hostname.endsWith('.youtube.com') ||
      hostname === 'youtube-nocookie.com' ||
      hostname.endsWith('.youtube-nocookie.com');
    if (!isYouTubeHost) return undefined;

    const videoID =
      url.pathname === '/watch'
        ? url.searchParams.get('v')
        : youtubeVideoPath.test(url.pathname)
          ? url.pathname.split('/').filter(Boolean)[1]
          : null;
    return videoID || undefined;
  } catch {
    return undefined;
  }
}
