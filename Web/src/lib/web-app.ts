import {
  type AccountProvider,
  type AICommandPreferences,
  type DesktopConnectionStatus,
  type DesktopLibraryEntry,
  type DesktopLibrarySnapshot,
  type DesktopOperationResult,
  type DesktopPlatform,
  type DesktopSyncStatus,
  type PodcastSnapshot,
  type ProcessingPreferences,
  type PromptPreferences,
  type SharedLibraryDesktopAPI
} from '../../../Shared/contracts.js';
import {
  type LibraryEntry,
  type LibraryProjection,
  demoProjection,
  loadLibraryProjection,
  loadLibraryText,
  loadRawLibraryText,
  textFor
} from '$lib/library.js';
import {
  consumeGoogleDriveConnectionResult,
  loadGoogleDriveConnection,
  syncGoogleDriveLibrary,
  type GoogleDriveConnection
} from '$lib/google-drive.js';
import {
  emptyICloudLibraryMessage,
  fetchICloudLibraryFile,
  fetchICloudLibraryMediaURL,
  iCloudIdentity,
  syncICloudLibrary,
  type SyncProvider
} from '$lib/icloud.js';
import {
  loadShareLinkStatus,
  publishShareLink,
  revokeShareLink,
  type ShareLinkSource
} from '$lib/share-links.js';
import {
  consumeBillingResult,
  loadBillingStatus,
  type BillingStatus
} from '$lib/billing.js';

type AccountStatus = {
  authenticated: boolean;
  syncProvider?: SyncProvider | null;
  icloud?: { configured?: boolean; connected?: boolean };
};

const emptyProjection: LibraryProjection = {
  schemaVersion: 3,
  generatedAt: new Date(0).toISOString(),
  files: [],
  entries: [],
  podcasts: []
};

const idleSync: DesktopSyncStatus = {
  phase: 'idle',
  message: 'Sign in and choose a sync service.'
};

const emptyProcessingPreferences: ProcessingPreferences = {
  topics: [],
  prompt: '',
  defaultPrompt: ''
};

const emptyPromptPreferences: PromptPreferences = { prompts: [] };

const emptyAICommandPreferences: AICommandPreferences = {
  defaultProcessingCommand: '',
  processingCommand: '',
  agentCommand: '',
  processingPresets: [],
  agentPresets: []
};

function unavailable(feature: string): never {
  throw new Error(`${feature} is available in the desktop app.`);
}

function browserPlatform(): DesktopPlatform {
  const platform = navigator.platform.toLowerCase();
  if (platform.includes('mac')) return 'darwin';
  if (platform.includes('win')) return 'win32';
  return 'linux';
}

export function createWebAppBridge(): {
  api: SharedLibraryDesktopAPI;
  loadDemo(): Promise<DesktopLibrarySnapshot>;
  start(): () => void;
} {
  let projection = emptyProjection;
  let account: AccountStatus = { authenticated: false };
  let billing: BillingStatus | null = null;
  let google: GoogleDriveConnection = { configured: false, connected: false };
  let provider: SyncProvider | null = null;
  let icloud = { configured: false, connected: false };
  let syncStatus = idleSync;
  let initializePromise: Promise<void> | null = null;
  let syncPromise: Promise<void> | null = null;
  let demoMode = false;
  const entryByID = new Map<string, LibraryEntry>();
  const libraryListeners = new Set<(snapshot: DesktopLibrarySnapshot) => void>();
  const syncListeners = new Set<(status: DesktopSyncStatus) => void>();

  function updateSync(next: DesktopSyncStatus): void {
    syncStatus = next;
    for (const listener of syncListeners) listener(next);
  }

  async function resolveMediaURL(
    entry: LibraryEntry,
    kind: 'audio' | 'favicon'
  ): Promise<string | undefined> {
    const media = entry[kind];
    if (!media) return kind === 'audio' ? entry.mediaURL : undefined;
    if (provider === 'google') return `/api/media/${kind}/${media.contentHash}`;
    if (provider !== 'icloud') return kind === 'audio' ? entry.mediaURL : undefined;
    try {
      return await fetchICloudLibraryMediaURL(media);
    } catch {
      return kind === 'audio' ? entry.mediaURL : undefined;
    }
  }

  async function desktopEntry(entry: LibraryEntry): Promise<DesktopLibraryEntry> {
    const [audioURL, faviconURL] = await Promise.all([
      resolveMediaURL(entry, 'audio'),
      resolveMediaURL(entry, 'favicon')
    ]);
    return {
      id: entry.id,
      captureID: entry.captureID ?? entry.id,
      entryType: entry.entryType,
      podcastID: entry.podcastID,
      filename:
        entry.texts.find(({ variant }) => variant === 'source')?.path?.split('/').at(-1) ??
        `${entry.captureID ?? entry.id}.md`,
      title: entry.title,
      excerpt: entry.excerpt,
      topicIDs: entry.topicIDs,
      topicNames: entry.topicNames,
      tags: entry.tags,
      sourceURL: entry.sourceURL,
      mediaURL: entry.mediaURL,
      faviconFile: entry.faviconFile,
      sourceIDs: entry.sourceIDs,
      sourceURLs: entry.sourceURLs,
      createdAt: entry.createdAt,
      updatedAt: entry.updatedAt,
      hasAudio: Boolean(audioURL),
      origin: entry.origin,
      sharedByUsername: entry.sharedByUsername,
      audioURL,
      faviconURL,
      availableVariants: entry.texts.map(({ variant }) => variant)
    };
  }

  async function snapshot(): Promise<DesktopLibrarySnapshot> {
    entryByID.clear();
    for (const entry of projection.entries) entryByID.set(entry.id, entry);
    const entries = await Promise.all(projection.entries.map(desktopEntry));
    return {
      workspacePath: provider ? `${provider === 'icloud' ? 'iCloud' : 'Google Drive'} library` : '',
      platform: browserPlatform(),
      generatedAt: projection.generatedAt,
      topics: [...new Set(entries.flatMap(({ topicNames }) => topicNames))].sort((left, right) =>
        left.localeCompare(right)
      ),
      entries
    };
  }

  async function emitLibrary(): Promise<void> {
    const next = await snapshot();
    for (const listener of libraryListeners) listener(next);
  }

  async function refreshConnections(): Promise<void> {
    const [accountResponse, nextGoogle, nextBilling] = await Promise.all([
      fetch('/api/auth/status', { cache: 'no-store' }),
      loadGoogleDriveConnection(),
      loadBillingStatus()
    ]);
    account = accountResponse.ok
      ? ((await accountResponse.json()) as AccountStatus)
      : { authenticated: false };
    google = nextGoogle;
    billing = nextBilling;
    provider = account.syncProvider ?? null;
    icloud = {
      configured: account.icloud?.configured === true,
      connected:
        provider === 'icloud' &&
        Boolean((await iCloudIdentity().catch(() => null))?.userRecordName)
    };
  }

  async function synchronize(showMessage: boolean): Promise<void> {
    if (syncPromise) return syncPromise;
    if (
      !provider ||
      (provider === 'google' && !google.connected) ||
      (provider === 'icloud' && !icloud.connected) ||
      (billing?.configured && !billing.entitled)
    ) {
      return;
    }
    syncPromise = (async () => {
      updateSync({
        phase: 'checking',
        message: `Checking ${provider === 'icloud' ? 'iCloud' : 'Google Drive'}…`
      });
      try {
        const syncLibrary =
          provider === 'icloud' ? syncICloudLibrary : syncGoogleDriveLibrary;
        const next = await syncLibrary(
          (available) => {
            projection = available;
          },
          (completed, total) => {
            updateSync({
              phase: 'downloading',
              message: `Saving ${completed} of ${total} files locally…`
            });
          }
        );
        if (!next) throw new Error(emptyICloudLibraryMessage);
        projection = next;
        await emitLibrary();
        updateSync({
          phase: 'up-to-date',
          message: showMessage ? 'Library synchronized.' : 'Library is up to date.',
          updatedAt: new Date().toISOString()
        });
      } catch (error) {
        updateSync({
          phase: 'error',
          message:
            error instanceof Error ? error.message : 'The library could not be synchronized.'
        });
        if (showMessage) throw error;
      } finally {
        syncPromise = null;
      }
    })();
    return syncPromise;
  }

  async function initialize(): Promise<void> {
    if (initializePromise) return initializePromise;
    initializePromise = (async () => {
      consumeGoogleDriveConnectionResult();
      consumeBillingResult();
      const url = new URL(window.location.href);
      if (url.searchParams.has('apple') || url.searchParams.has('icloud')) {
        url.searchParams.delete('apple');
        url.searchParams.delete('icloud');
        window.history.replaceState({}, '', `${url.pathname}${url.search}${url.hash}`);
      }
      projection = (await loadLibraryProjection().catch(() => null)) ?? emptyProjection;
      await refreshConnections();
      if (provider && (!billing?.configured || billing.entitled)) {
        await navigator.storage?.persist?.().catch(() => false);
        await synchronize(false);
      }
    })();
    return initializePromise;
  }

  async function connectionStatus(): Promise<DesktopConnectionStatus> {
    await initialize();
    return {
      authenticated: account.authenticated,
      entitled: !billing?.configured || billing.entitled,
      syncProvider: provider,
      google: {
        configured: google.configured,
        connected: google.connected,
        connectedAt: google.connectedAt
      },
      icloud,
      sync: syncStatus
    };
  }

  function podcastSnapshot(): PodcastSnapshot {
    const podcasts = (projection.podcasts ?? []).map((podcast) => ({
      ...podcast,
      prompt: '',
      prioritizeForMe: false,
      status: 'ready' as const,
      message: '',
      episodes: projection.entries
        .filter(
          (entry) =>
            entry.entryType === 'podcast_episode' && entry.podcastID === podcast.id
        )
        .map((entry) => entryByID.get(entry.id))
        .filter((entry): entry is LibraryEntry => Boolean(entry))
        .map((entry) => ({
          id: entry.id,
          captureID: entry.captureID ?? entry.id,
          entryType: entry.entryType,
          podcastID: entry.podcastID,
          filename:
            entry.texts.find(({ variant }) => variant === 'source')?.path?.split('/').at(-1) ??
            `${entry.captureID ?? entry.id}.md`,
          title: entry.title,
          excerpt: entry.excerpt,
          topicIDs: entry.topicIDs,
          topicNames: entry.topicNames,
          tags: entry.tags,
          sourceURL: entry.sourceURL,
          mediaURL: entry.mediaURL,
          sourceIDs: entry.sourceIDs,
          sourceURLs: entry.sourceURLs,
          createdAt: entry.createdAt,
          updatedAt: entry.updatedAt,
          hasAudio: Boolean(entry.audio || entry.mediaURL),
          origin: entry.origin,
          sharedByUsername: entry.sharedByUsername,
          availableVariants: entry.texts.map(({ variant }) => variant)
        })),
      sourceStatuses: []
    }));
    return {
      generatedAt: projection.generatedAt,
      podcasts,
      channels: [],
      maximumPodcasts: podcasts.length
    };
  }

  async function shareSource(entry: LibraryEntry): Promise<ShareLinkSource | undefined> {
    if (provider !== 'icloud') return undefined;
    const texts = await Promise.all(
      entry.texts.map(async (reference) => ({
        variant: reference.variant,
        markdown: await loadRawLibraryText(reference, fetchICloudLibraryFile)
      }))
    );
    return {
      filename:
        entry.texts.find(({ variant }) => variant === 'source')?.path?.split('/').at(-1) ??
        `${entry.captureID ?? entry.id}.md`,
      title: entry.title,
      excerpt: entry.excerpt,
      topicIDs: entry.topicIDs,
      topicNames: entry.topicNames,
      tags: entry.tags,
      sourceURL: entry.sourceURL,
      createdAt: entry.createdAt,
      updatedAt: entry.updatedAt,
      texts
    };
  }

  const api: SharedLibraryDesktopAPI = {
    async getSnapshot() {
      await initialize();
      return snapshot();
    },
    async chooseWorkspace() {
      return unavailable('Choosing a local workspace');
    },
    async refresh() {
      await initialize();
      await synchronize(true);
      return snapshot();
    },
    async readText(entryID, variant) {
      if (!demoMode) await initialize();
      const entry = entryByID.get(entryID);
      const reference = entry && textFor(entry, variant);
      return reference ? loadLibraryText(reference) : '';
    },
    async writeText() {
      return unavailable('Editing');
    },
    async trashCapture() {
      return unavailable('Moving items to Trash');
    },
    async captureClipboard(): Promise<DesktopOperationResult> {
      return unavailable('Capture');
    },
    async capturePDF(): Promise<DesktopOperationResult> {
      return unavailable('PDF capture');
    },
    async openExternal(url) {
      window.open(url, '_blank', 'noopener,noreferrer');
    },
    async openAgent() {
      return unavailable('Agents');
    },
    async revealEntry() {
      return unavailable('Revealing local files');
    },
    async showEntryContextMenu() {
      return unavailable('Native context menus');
    },
    getConnectionStatus: connectionStatus,
    async signIn(provider: AccountProvider) {
      window.location.assign(`/api/auth/${provider}/start`);
      return connectionStatus();
    },
    async manageAccount() {
      window.location.assign(
        provider === 'icloud' && !icloud.connected ? '/api/icloud/authorize' : '/account'
      );
      return connectionStatus();
    },
    async syncNow() {
      await initialize();
      await synchronize(true);
      return connectionStatus();
    },
    async getShortcutPreferences() {
      return {
        captureShortcut: 'CommandOrControl+G',
        defaultCaptureShortcut: 'CommandOrControl+G',
        registered: false
      };
    },
    async setCaptureShortcut() {
      return unavailable('System-wide shortcuts');
    },
    async getAudioPreferences() {
      return { saveCapturedAudio: false };
    },
    async setSaveCapturedAudio() {
      return unavailable('Captured audio settings');
    },
    async getAboutYou() {
      return '';
    },
    async setAboutYou() {
      return unavailable('Personal agent context');
    },
    async getIngestionStatus() {
      return { phase: 'idle', activeCount: 0, message: 'All sources are ready.' };
    },
    async getProcessingPreferences() {
      return emptyProcessingPreferences;
    },
    async updateProcessingPreferences() {
      return unavailable('Processing preferences');
    },
    async getPromptPreferences() {
      return emptyPromptPreferences;
    },
    async updatePromptPreference() {
      return unavailable('Prompt settings');
    },
    async getAICommandPreferences() {
      return emptyAICommandPreferences;
    },
    async updateAICommandPreferences() {
      return unavailable('AI command settings');
    },
    async testAIProcessingCommand() {
      return unavailable('Local AI commands');
    },
    async getPodcasts() {
      if (!demoMode) await initialize();
      await snapshot();
      return podcastSnapshot();
    },
    async savePodcast() {
      return unavailable('Audio brief authoring');
    },
    async removePodcast() {
      return unavailable('Audio brief authoring');
    },
    async checkPodcast() {
      return unavailable('Audio brief authoring');
    },
    async runPodcast() {
      return unavailable('Audio brief authoring');
    },
    async revealPodcast() {
      return unavailable('Revealing local files');
    },
    async addChannel() {
      return unavailable('Channel management');
    },
    async checkChannel() {
      return unavailable('Channel management');
    },
    async updateChannel() {
      return unavailable('Channel management');
    },
    async loadMoreChannel() {
      return unavailable('Channel management');
    },
    async removeChannel() {
      return unavailable('Channel management');
    },
    async loginChannel() {
      return unavailable('Channel sign-in');
    },
    async getShareLink(entryID) {
      await initialize();
      const entry = entryByID.get(entryID);
      if (!entry) throw new Error('The selected document is unavailable.');
      return loadShareLinkStatus(entry.captureID ?? entry.id);
    },
    async publishShareLink(entryID) {
      await initialize();
      const entry = entryByID.get(entryID);
      if (!entry || entry.origin !== 'personal') {
        throw new Error('Only personal library documents can be shared.');
      }
      const result = await publishShareLink(
        entry.captureID ?? entry.id,
        await shareSource(entry)
      );
      if (result.status === 'ready' && result.url) {
        await navigator.clipboard.writeText(result.url);
      }
      return result;
    },
    revokeShareLink,
    onLibraryChanged(listener) {
      libraryListeners.add(listener);
      return () => libraryListeners.delete(listener);
    },
    onIngestionStatus() {
      return () => {};
    },
    onSyncStatus(listener) {
      syncListeners.add(listener);
      return () => syncListeners.delete(listener);
    },
    onPodcastsChanged() {
      return () => {};
    }
  };

  function start(): () => void {
    let lastSync = 0;
    let reloading = false;
    const synchronizeWhenUseful = (): void => {
      if (!navigator.onLine || Date.now() - lastSync < 30_000) return;
      lastSync = Date.now();
      void synchronize(false);
    };
    const activateLatestVersion = (): void => {
      if (reloading) return;
      reloading = true;
      window.location.reload();
    };
    const interval = window.setInterval(synchronizeWhenUseful, 30_000);
    window.addEventListener('online', synchronizeWhenUseful);
    window.addEventListener('focus', synchronizeWhenUseful);
    document.addEventListener('visibilitychange', synchronizeWhenUseful);
    navigator.serviceWorker?.addEventListener('controllerchange', activateLatestVersion);
    return () => {
      window.clearInterval(interval);
      window.removeEventListener('online', synchronizeWhenUseful);
      window.removeEventListener('focus', synchronizeWhenUseful);
      document.removeEventListener('visibilitychange', synchronizeWhenUseful);
      navigator.serviceWorker?.removeEventListener('controllerchange', activateLatestVersion);
    };
  }

  async function loadDemo(): Promise<DesktopLibrarySnapshot> {
    demoMode = true;
    projection = demoProjection;
    return snapshot();
  }

  return { api, loadDemo, start };
}
