import assert from 'node:assert/strict';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';

import { isMainLibraryEntry } from '../../../Shared/library.js';
import { ItemService } from './items.js';
import { LibraryService } from './library.js';

test('manual and channel saves reuse one normal library item', async () => {
  const root = await mkdtemp(join(tmpdir(), 'briefly-items-'));
  try {
    const library = new LibraryService(root, 'linux', async () => {});
    let extractions = 0;
    const items = new ItemService(
      library,
      {
        extractURL: async () => {
          extractions += 1;
          return {
            title: 'One Reddit post',
            content: 'Readable post content.',
            sourceURL: 'https://www.reddit.com/r/example/comments/abc/post/'
          };
        }
      },
      { process: async (entryID) => entryID },
      () => library.snapshot(),
      () => {}
    );

    const manual = await items.save('https://redd.it/AbC');
    const channel = await items.save(
      'https://www.reddit.com/r/example/comments/abc/post/',
      {
        discovered: {
          id: 't3_abc',
          title: 'One Reddit post',
          url: 'https://www.reddit.com/r/example/comments/abc/post/',
          publishedAt: null
        }
      }
    );
    const [entry] = (await library.snapshot()).entries;

    assert.equal(extractions, 1);
    assert.equal(channel.entryID, manual.entryID);
    assert.equal(channel.created, false);
    assert.equal(entry.entryType, 'link');
    assert.equal(isMainLibraryEntry(entry), true);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});
