import assert from 'node:assert/strict';
import test from 'node:test';
import type { BackendClient } from './backend.js';
import type { DriveLibraryIndex, DriveLibraryMirror, LibraryService } from './library.js';
import { SyncCoordinator } from './sync.js';

test('sync routes every library operation through the selected provider', async () => {
  const index: DriveLibraryIndex = {
    schemaVersion: 3,
    generatedAt: '2026-07-26T00:00:00.000Z',
    files: [{ path: 'library/example.md', contentHash: 'a'.repeat(64), byteCount: 7 }],
    entries: []
  };
  const mirror: DriveLibraryMirror = {
    index,
    files: [{ ...index.files[0], content: 'example' }],
    media: []
  };
  const calls: string[] = [];
  const backend = {
    accountStatus: async () => ({ authenticated: true, syncProvider: 'icloud' }),
    providerStatus: async (provider: string) => {
      calls.push(`status:${provider}`);
      return { connected: true };
    },
    fetchLibraryIndex: async (provider: string) => {
      calls.push(`index:${provider}`);
      return index;
    },
    fetchLibraryFile: async (_file: unknown, provider: string) => {
      calls.push(`file:${provider}`);
      return 'example';
    },
    uploadLibrary: async (_mirror: unknown, provider: string) => {
      calls.push(`upload:${provider}`);
      return { changed: 1, syncedAt: '2026-07-26T00:00:00.000Z' };
    }
  } as unknown as BackendClient;
  const library = {
    mergeRemoteMirror: async (
      remote: DriveLibraryIndex,
      download: (file: DriveLibraryIndex['files'][number]) => Promise<string>
    ) => {
      await download(remote.files[0]);
      return { changed: 1, conflicts: 0 };
    },
    mergeRemoteMedia: async () => 0,
    buildDriveMirror: async () => mirror,
    saveSyncBaseline: async () => {}
  } as unknown as LibraryService;
  const coordinator = new SyncCoordinator(backend, library, () => {}, async () => {});

  const status = await coordinator.synchronize();

  assert.equal(status.phase, 'up-to-date');
  assert.deepEqual(calls, [
    'status:icloud',
    'index:icloud',
    'file:icloud',
    'upload:icloud'
  ]);
});
