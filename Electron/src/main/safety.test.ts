import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { mkdir, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';

import { LibraryService } from './library.js';
import { voiceBriefAudioRange } from './voice-briefs.js';
import { isTrustedRendererURL, isWebURL } from './security.js';

test('sync preserves both sides of a concurrent edit', async () => {
  const root = await mkdtemp(join(tmpdir(), 'briefly-sync-safety-'));
  const sourcePath = join(root, 'library', 'example.md');
  const original = `---\nid: "example"\ntitle: "Example"\n---\n\nOriginal.\n`;
  const local = original.replace('Original.', 'Changed locally.');
  const remote = original.replace('Original.', 'Changed remotely.');
  try {
    await mkdir(join(root, 'library'), { recursive: true });
    await writeFile(sourcePath, original);
    const library = new LibraryService(root, 'linux', async () => {});
    await library.saveSyncBaseline((await library.buildDriveMirror()).index.files);
    await writeFile(sourcePath, local);

    const result = await library.mergeRemoteMirror(
      {
        schemaVersion: 4,
        generatedAt: new Date().toISOString(),
        files: [{
          path: 'library/example.md',
          contentHash: createHash('sha256').update(remote).digest('hex'),
          byteCount: Buffer.byteLength(remote)
        }],
        entries: []
      },
      async () => remote
    );

    assert.deepEqual(result, { changed: 1, conflicts: 1 });
    assert.equal(await readFile(sourcePath, 'utf8'), remote);
    assert.match(await readFile(join(root, 'library', 'example-conflict.md'), 'utf8'), /Changed locally/);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test('desktop trust boundaries reject unsafe navigation and media ranges', () => {
  const entry = 'file:///Applications/Briefly.app/Contents/Resources/app.asar/out/renderer/index.html';
  assert.equal(isTrustedRendererURL(`${entry}#/library`, entry), true);
  assert.equal(isTrustedRendererURL('file:///etc/passwd', entry), false);
  assert.equal(isWebURL('https://readbriefly.fyi/'), true);
  assert.equal(isWebURL('javascript:alert(1)'), false);
  assert.deepEqual(voiceBriefAudioRange('bytes=20-29', 100), { start: 20, end: 29 });
  assert.equal(voiceBriefAudioRange('bytes=0-1,4-5', 100), null);
});
