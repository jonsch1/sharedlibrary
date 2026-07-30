import type { DesktopLibrarySnapshot } from '../shared/contracts.js';
import type {
  DiscoveredSourceItem,
  ExtractedContent,
  ExtractionService
} from './extraction.js';
import type { LibraryService } from './library.js';
import type { ProcessingService } from './processing.js';

export interface SavedItem {
  entryID: string;
  title: string;
  sourceURL?: string;
  created: boolean;
  snapshot: DesktopLibrarySnapshot;
}

export interface SaveItemOptions {
  discovered?: DiscoveredSourceItem;
  extracted?: ExtractedContent;
  topicIDs?: string[];
  saveAudio?: boolean;
  reuseExisting?: boolean;
  syncReason?: string;
}

export class ItemService {
  private processingQueue: Promise<unknown> = Promise.resolve();

  constructor(
    private readonly library: LibraryService,
    private readonly extraction: Pick<ExtractionService, 'extractURL'>,
    private readonly processing: Pick<ProcessingService, 'process'>,
    private readonly onLibraryChanged: () => Promise<DesktopLibrarySnapshot>,
    private readonly onSyncRequested: (reason: string) => void
  ) {}

  async save(value: string, options: SaveItemOptions = {}): Promise<SavedItem> {
    const sourceURL = httpURL(value);
    let snapshot = await this.library.snapshot();
    if (sourceURL && options.reuseExisting !== false) {
      const existing = findSource(snapshot, sourceURL);
      if (existing) return saved(existing, snapshot, false);
    }
    const extracted =
      options.extracted ??
      (sourceURL
        ? await this.extraction.extractURL(
            sourceURL,
            options.saveAudio === true,
            options.discovered
          )
        : undefined);
    const resolvedURL = httpURL(extracted?.sourceURL ?? '');
    if (resolvedURL && options.reuseExisting !== false) {
      const existing = findSource(snapshot, resolvedURL);
      if (existing) return saved(existing, snapshot, false);
    }
    const stored =
      extracted && options.saveAudio !== true
        ? { ...extracted, audio: undefined }
        : extracted;
    const captureID = await this.library.captureText(
      value,
      stored,
      options.topicIDs
    );
    const entryID = `personal:${captureID}`;
    snapshot = await this.onLibraryChanged();
    this.onSyncRequested(options.syncReason ?? 'new item');
    const entry = snapshot.entries.find((candidate) => candidate.id === entryID);
    if (!entry) throw new Error('The saved item could not be found in the library.');
    return saved(entry, snapshot, true);
  }

  process(
    entryID: string,
    topicID?: string,
    syncReason = 'processed item'
  ): Promise<string> {
    const result = this.processingQueue.then(async () => {
      const processedID = await this.processing.process(
        entryID,
        this.library,
        topicID
      );
      await this.onLibraryChanged();
      this.onSyncRequested(syncReason);
      return processedID;
    });
    this.processingQueue = result.then(() => undefined, () => undefined);
    return result;
  }
}

export function sourceIdentity(value: string): string {
  let url: URL;
  try {
    url = new URL(value);
  } catch {
    return value.trim();
  }
  url.hash = '';
  const host = url.hostname.toLowerCase().replace(/^www\./u, '');
  const parts = url.pathname.split('/').filter(Boolean).map(decodeURIComponent);
  const status = parts.findIndex(
    (part, index) => index > 0 && part.toLowerCase() === 'status'
  );
  if (
    status >= 0 &&
    ['x.com', 'twitter.com'].includes(host) &&
    /^\d+$/u.test(parts[status + 1] ?? '')
  ) {
    return `x:status:${parts[status + 1]}`;
  }
  if (host === 'redd.it' && /^[a-z0-9]+$/iu.test(parts[0] ?? '')) {
    return `reddit:post:${parts[0].toLowerCase()}`;
  }
  const comments = parts.findIndex((part) => part.toLowerCase() === 'comments');
  if (
    (host === 'reddit.com' || host.endsWith('.reddit.com')) &&
    comments >= 0 &&
    /^[a-z0-9]+$/iu.test(parts[comments + 1] ?? '')
  ) {
    return `reddit:post:${parts[comments + 1].toLowerCase()}`;
  }
  if (host === 'bsky.app' && parts[0] === 'profile' && parts[2] === 'post' && parts[3]) {
    return `bluesky:post:${parts[1]}:${parts[3]}`;
  }
  const youtubeID =
    host === 'youtu.be'
      ? parts[0]
      : host.endsWith('youtube.com')
        ? url.searchParams.get('v')
        : null;
  if (youtubeID) return `youtube:video:${youtubeID}`;
  for (const key of [...url.searchParams.keys()]) {
    if (
      key.toLowerCase().startsWith('utm_') ||
      ['fbclid', 'gclid', 'mc_cid', 'mc_eid'].includes(key.toLowerCase())
    ) {
      url.searchParams.delete(key);
    }
  }
  return url.toString();
}

function httpURL(value: string): string | null {
  try {
    const url = new URL(value.trim());
    return ['http:', 'https:'].includes(url.protocol) &&
      !url.username &&
      !url.password
      ? url.toString()
      : null;
  } catch {
    return null;
  }
}

function findSource(snapshot: DesktopLibrarySnapshot, sourceURL: string) {
  const identity = sourceIdentity(sourceURL);
  // ponytail: linear scan is enough for local libraries; index identities if it becomes slow.
  return snapshot.entries.find(
    (entry) => entry.sourceURL && sourceIdentity(entry.sourceURL) === identity
  );
}

function saved(
  entry: DesktopLibrarySnapshot['entries'][number],
  snapshot: DesktopLibrarySnapshot,
  created: boolean
): SavedItem {
  return {
    entryID: entry.id,
    title: entry.title,
    sourceURL: entry.sourceURL,
    created,
    snapshot
  };
}
