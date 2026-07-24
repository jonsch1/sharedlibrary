import type { LibraryVariant } from './contracts.js';

const youtubeVideoPath = /^\/(?:embed|live|shorts|v)\/[^/]+/;

export function shouldRenderSourceAsPlainText(
  variant: LibraryVariant,
  sourceURL?: string
): boolean {
  return variant === 'source' && isYouTubeVideoURL(sourceURL);
}

function isYouTubeVideoURL(value?: string): boolean {
  if (!value) return false;

  try {
    const url = new URL(value);
    if (url.protocol !== 'http:' && url.protocol !== 'https:') return false;

    const hostname = url.hostname.toLowerCase().replace(/\.$/, '');
    if (hostname === 'youtu.be') return url.pathname.split('/').filter(Boolean).length > 0;

    const isYouTubeHost =
      hostname === 'youtube.com' ||
      hostname.endsWith('.youtube.com') ||
      hostname === 'youtube-nocookie.com' ||
      hostname.endsWith('.youtube-nocookie.com');
    if (!isYouTubeHost) return false;

    return (
      (url.pathname === '/watch' && Boolean(url.searchParams.get('v'))) ||
      youtubeVideoPath.test(url.pathname)
    );
  } catch {
    return false;
  }
}
