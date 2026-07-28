export const librarySchemaVersion = 3;

export const libraryVariants = [
  'brief',
  'concise',
  'detailed',
  'comprehensive',
  'source'
] as const;

export type LibraryVariant = (typeof libraryVariants)[number];
export type LibraryOrigin = 'personal' | 'shared';
export type LibraryMediaKind = 'audio' | 'favicon';

export interface LibraryMedia {
  kind: LibraryMediaKind;
  path: string;
  contentHash: string;
  byteCount: number;
  contentType: string;
}

export interface LibraryPodcast {
  id: string;
  filename: string;
  title: string;
  schedule: string;
  length: string;
  sources: string[];
}

export interface LibraryText {
  variant: LibraryVariant;
  path?: string;
  contentHash?: string;
  wordCount?: number;
  text?: string;
}

export interface LibraryFile {
  path: string;
  contentHash: string;
  byteCount: number;
}

export interface LibraryEntry {
  id: string;
  captureID?: string;
  entryType?: string;
  podcastID?: string;
  title: string;
  excerpt: string;
  topicIDs: string[];
  topicNames: string[];
  tags: string[];
  sourceURL?: string;
  mediaURL?: string;
  faviconFile?: string;
  audio?: LibraryMedia;
  favicon?: LibraryMedia;
  sourceIDs?: string[];
  sourceURLs?: string[];
  hasAudio?: boolean;
  createdAt?: string;
  updatedAt?: string;
  reviewedAt?: string;
  origin: LibraryOrigin;
  sharedByUsername?: string;
  inboxReferenceID?: string;
  texts: LibraryText[];
}

export interface LibraryProjection {
  schemaVersion: number;
  generatedAt: string;
  files: LibraryFile[];
  entries: LibraryEntry[];
  podcasts?: LibraryPodcast[];
}

function isObject(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}

function isStringArray(value: unknown): value is string[] {
  return Array.isArray(value) && value.every((item) => typeof item === 'string');
}

function isOptionalString(value: unknown): boolean {
  return value === undefined || typeof value === 'string';
}

function isLibraryText(value: unknown): value is LibraryText {
  return (
    isObject(value) &&
    typeof value.variant === 'string' &&
    libraryVariants.includes(value.variant as LibraryVariant) &&
    (typeof value.text === 'string' ||
      (typeof value.path === 'string' &&
        typeof value.contentHash === 'string' &&
        typeof value.wordCount === 'number'))
  );
}

function isLibraryEntry(value: unknown): value is LibraryEntry {
  return (
    isObject(value) &&
    typeof value.id === 'string' &&
    typeof value.title === 'string' &&
    typeof value.excerpt === 'string' &&
    isStringArray(value.topicIDs) &&
    isStringArray(value.topicNames) &&
    isStringArray(value.tags) &&
    (value.origin === 'personal' || value.origin === 'shared') &&
    isOptionalString(value.captureID) &&
    isOptionalString(value.entryType) &&
    isOptionalString(value.podcastID) &&
    isOptionalString(value.sourceURL) &&
    isOptionalString(value.mediaURL) &&
    isOptionalString(value.faviconFile) &&
    (value.audio === undefined || isLibraryMedia(value.audio, 'audio')) &&
    (value.favicon === undefined || isLibraryMedia(value.favicon, 'favicon')) &&
    (value.sourceIDs === undefined || isStringArray(value.sourceIDs)) &&
    (value.sourceURLs === undefined || isStringArray(value.sourceURLs)) &&
    (value.hasAudio === undefined || typeof value.hasAudio === 'boolean') &&
    isOptionalString(value.createdAt) &&
    isOptionalString(value.updatedAt) &&
    isOptionalString(value.reviewedAt) &&
    isOptionalString(value.sharedByUsername) &&
    isOptionalString(value.inboxReferenceID) &&
    Array.isArray(value.texts) &&
    value.texts.every(isLibraryText)
  );
}

function isLibraryMedia(value: unknown, kind: LibraryMediaKind): value is LibraryMedia {
  return (
    isObject(value) &&
    value.kind === kind &&
    typeof value.path === 'string' &&
    value.path.startsWith(`library/${kind === 'audio' ? 'audio' : 'favicons'}/`) &&
    !value.path.split('/').some((component) => !component || component === '.' || component === '..') &&
    typeof value.contentHash === 'string' &&
    /^[a-f0-9]{64}$/.test(value.contentHash) &&
    typeof value.byteCount === 'number' &&
    Number.isSafeInteger(value.byteCount) &&
    value.byteCount > 0 &&
    typeof value.contentType === 'string' &&
    value.contentType.startsWith(kind === 'audio' ? 'audio/' : 'image/')
  );
}

function isLibraryFile(value: unknown): value is LibraryFile {
  return (
    isObject(value) &&
    typeof value.path === 'string' &&
    typeof value.contentHash === 'string' &&
    /^[a-f0-9]{64}$/.test(value.contentHash) &&
    typeof value.byteCount === 'number' &&
    Number.isSafeInteger(value.byteCount) &&
    value.byteCount >= 0
  );
}

function isLibraryPodcast(value: unknown): value is LibraryPodcast {
  return (
    isObject(value) &&
    typeof value.id === 'string' &&
    typeof value.filename === 'string' &&
    typeof value.title === 'string' &&
    typeof value.schedule === 'string' &&
    typeof value.length === 'string' &&
    isStringArray(value.sources)
  );
}

export function parseLibraryProjection(value: unknown): LibraryProjection {
  if (
    !isObject(value) ||
    (value.schemaVersion !== 2 && value.schemaVersion !== librarySchemaVersion) ||
    typeof value.generatedAt !== 'string' ||
    Number.isNaN(Date.parse(value.generatedAt)) ||
    !Array.isArray(value.files) ||
    !value.files.every(isLibraryFile) ||
    !Array.isArray(value.entries) ||
    !value.entries.every(isLibraryEntry) ||
    (value.podcasts !== undefined &&
      (!Array.isArray(value.podcasts) || !value.podcasts.every(isLibraryPodcast)))
  ) {
    throw new Error(
      'This is not a compatible Briefly library index. Open the desktop app and let it synchronize again.'
    );
  }
  const projection = value as unknown as LibraryProjection & {
    entries: Array<LibraryEntry & { sharedByDisplayName?: string }>;
  };
  return {
    ...projection,
    schemaVersion: librarySchemaVersion,
    podcasts: Array.isArray(projection.podcasts) ? projection.podcasts : [],
    entries: projection.entries.map((entry) => {
      const legacy = entry as LibraryEntry & { sharedByDisplayName?: string };
      return {
        ...entry,
        sharedByUsername: entry.sharedByUsername ?? legacy.sharedByDisplayName
      };
    })
  };
}

export function hasSameLibraryContent(
  left: LibraryProjection,
  right: LibraryProjection
): boolean {
  const comparable = (projection: LibraryProjection): LibraryProjection => ({
    ...projection,
    generatedAt: '',
    entries: projection.entries.map((entry) => ({
      ...entry,
      texts: entry.texts?.map((reference) => {
        if (!reference.path || !reference.contentHash) return reference;
        const { text: _cachedText, ...storedReference } = reference;
        return storedReference;
      })
    }))
  });
  return JSON.stringify(comparable(left)) === JSON.stringify(comparable(right));
}

export function retainLoadedLibraryText(
  current: LibraryProjection,
  next: LibraryProjection
): LibraryProjection {
  const currentEntries = new Map(current.entries.map((entry) => [entry.id, entry]));
  return {
    ...next,
    entries: next.entries.map((entry) => {
      const currentEntry = currentEntries.get(entry.id);
      if (!currentEntry) return entry;
      const currentTexts = new Map(
        currentEntry.texts.map((reference) => [reference.variant, reference])
      );
      const texts = entry.texts.map((reference) => {
        if (typeof reference.text === 'string' || !reference.path || !reference.contentHash) {
          return reference;
        }
        const currentReference = currentTexts.get(reference.variant);
        return typeof currentReference?.text === 'string' &&
          currentReference.path === reference.path &&
          currentReference.contentHash === reference.contentHash
          ? { ...reference, text: currentReference.text }
          : reference;
      });
      return texts.some((reference, index) => reference !== entry.texts[index])
        ? { ...entry, texts }
        : entry;
    })
  };
}

export function textFor(
  entry: LibraryEntry,
  variant: LibraryVariant
): LibraryText | undefined {
  return entry.texts.find((text) => text.variant === variant);
}

export function preferredVariant(entry: LibraryEntry): LibraryVariant {
  for (const variant of ['concise', 'brief', 'detailed', 'comprehensive', 'source'] as const) {
    if (textFor(entry, variant)) return variant;
  }
  return 'source';
}

export function isMainLibraryEntry(entry: Pick<LibraryEntry, 'entryType'>): boolean {
  return entry.entryType !== 'podcast_episode' && entry.entryType !== 'podcast_source';
}

export function matchesLibraryEntry(
  entry: Pick<LibraryEntry, 'title' | 'excerpt' | 'topicNames' | 'tags' | 'sharedByUsername'>,
  query: string
): boolean {
  const normalizedQuery = query.trim().toLowerCase();
  return (
    !normalizedQuery ||
    [entry.title, entry.excerpt, ...entry.topicNames, ...entry.tags, entry.sharedByUsername ?? '']
      .join(' ')
      .toLowerCase()
      .includes(normalizedQuery)
  );
}

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
