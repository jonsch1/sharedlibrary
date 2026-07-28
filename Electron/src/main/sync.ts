import type { DesktopSyncStatus } from '../shared/contracts.js';
import { BackendClient } from './backend.js';
import { LibraryService } from './library.js';

type StatusListener = (status: DesktopSyncStatus) => void;

export class SyncCoordinator {
  private running: Promise<DesktopSyncStatus> | null = null;
  private pending = false;
  private timer: NodeJS.Timeout | null = null;
  private status: DesktopSyncStatus = {
    phase: 'idle',
    message: 'Sign in and choose a sync service.'
  };

  constructor(
    private readonly backend: BackendClient,
    private readonly library: LibraryService,
    private readonly onStatus: StatusListener,
    private readonly onLibraryChanged: () => Promise<void>
  ) {}

  currentStatus(): DesktopSyncStatus {
    return this.status;
  }

  request(reason: string, delayMilliseconds = 900): void {
    if (this.timer) clearTimeout(this.timer);
    this.timer = setTimeout(() => {
      this.timer = null;
      void this.synchronize(reason).catch(() => {
        // The visible status already contains the failure.
      });
    }, delayMilliseconds);
  }

  async synchronize(reason = 'library'): Promise<DesktopSyncStatus> {
    if (this.running) {
      this.pending = true;
      return this.running;
    }
    this.running = this.perform(reason);
    try {
      return await this.running;
    } finally {
      this.running = null;
      if (this.pending) {
        this.pending = false;
        this.request('recent changes', 100);
      }
    }
  }

  private async perform(reason: string): Promise<DesktopSyncStatus> {
    try {
      this.update('checking', `Checking ${reason}…`);
      const account = await this.backend.accountStatus();
      if (!account.authenticated) {
        return this.update('idle', 'Sign in to synchronize this library.');
      }
      const provider = account.syncProvider;
      if (!provider) return this.update('idle', 'Choose iCloud or Google Drive for sync.');
      const connection = await this.backend.providerStatus(provider);
      if (connection.connected !== true) {
        return this.update(
          'idle',
          `Connect ${provider === 'icloud' ? 'iCloud' : 'Google Drive'} to synchronize this library.`
        );
      }

      const remote = await this.backend.fetchLibraryIndex(provider);
      let downloaded = 0;
      let conflicts = 0;
      if (remote) {
        this.update('downloading', 'Downloading newer library files…');
        const merge = await this.library.mergeRemoteMirror(
          remote,
          (file) => this.backend.fetchLibraryFile(file, provider)
        );
        downloaded = merge.changed;
        conflicts = merge.conflicts;
        downloaded += await this.library.mergeRemoteMedia(
          remote,
          (media) => this.backend.fetchLibraryMedia(media, provider)
        );
        if (downloaded > 0) await this.onLibraryChanged();
      }

      this.update('uploading', 'Uploading local changes…');
      const mirror = await this.library.buildDriveMirror();
      const result = await this.backend.uploadLibrary(mirror, provider);
      await this.library.saveSyncBaseline(mirror.index.files);
      const changed = downloaded + Number(result.changed || 0);
      const updatedAt = result.syncedAt || new Date().toISOString();
      return this.update(
        'up-to-date',
        conflicts > 0
          ? `Synchronized with ${conflicts} ${conflicts === 1 ? 'conflict copy' : 'conflict copies'} kept in the library.`
          : changed > 0
          ? `Synchronized ${changed} ${changed === 1 ? 'change' : 'changes'}.`
          : 'Everything is up to date.',
        updatedAt
      );
    } catch (error) {
      return this.update(
        'error',
        error instanceof Error ? error.message : 'Library synchronization failed.'
      );
    }
  }

  private update(
    phase: DesktopSyncStatus['phase'],
    message: string,
    updatedAt?: string
  ): DesktopSyncStatus {
    this.status = { phase, message, updatedAt };
    this.onStatus(this.status);
    return this.status;
  }
}
