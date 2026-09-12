import { sourceVariant, type LibraryVariant } from './reading-depth.ts';

export function shouldRenderSourceAsPlainText(
  variant: LibraryVariant,
  sourceURL?: string
): boolean {
  return variant === sourceVariant && Boolean(youtubeVideoID(sourceURL));
}

function youtubeVideoID(value?: string): string | undefined {
  if (!value) return undefined;
  try {
    const url = new URL(value);
    if (url.protocol !== 'http:' && url.protocol !== 'https:') return undefined;
    const hostname = url.hostname.toLowerCase().replace(/\.$/, '');
    if (hostname === 'youtu.be') return url.pathname.split('/').filter(Boolean)[0];
    const isYouTubeHost =
      hostname === 'youtube.com' ||
      hostname.endsWith('.youtube.com') ||
      hostname === 'youtube-nocookie.com' ||
      hostname.endsWith('.youtube-nocookie.com');
    if (!isYouTubeHost) return undefined;
    const videoID =
      url.pathname === '/watch'
        ? url.searchParams.get('v')
        : /^\/(?:embed|live|shorts|v)\/[^/]+/.test(url.pathname)
          ? url.pathname.split('/').filter(Boolean)[1]
          : null;
    return videoID || undefined;
  } catch {
    return undefined;
  }
}

export function sourceTextParagraphs(text: string): string[] {
  const paragraphs: string[] = [];
  let current: string[] = [];
  const flush = (): void => {
    const paragraph = current.join(' ').replace(/[ \t]+/g, ' ').trim();
    if (paragraph) paragraphs.push(paragraph);
    current = [];
  };
  for (const rawLine of text.replace(/\r\n?/g, '\n').split('\n')) {
    let line = rawLine.trim();
    if (!line) {
      flush();
      continue;
    }
    const speakerTurn = /^>{2,}\s*(.*)$/.exec(line);
    if (speakerTurn) {
      flush();
      line = speakerTurn[1].trim();
      if (!line) continue;
    }
    current.push(line);
  }
  flush();
  return paragraphs;
}
