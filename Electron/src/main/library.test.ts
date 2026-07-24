import assert from 'node:assert/strict';
import { mkdtemp, mkdir, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';
import { LibraryService, parseMarkdown } from './library.js';

test('parses Shared Library frontmatter lists and keeps the body separate', () => {
  const parsed = parseMarkdown(`---
id: "capture-1"
title: "Example"
tags: []
topics:
  - "research"
  - "tools-workflows"
---

Body text.
`);
  assert.equal(parsed.metadata.id, 'capture-1');
  assert.deepEqual(parsed.metadata.topics, ['research', 'tools-workflows']);
  assert.equal(parsed.body.trim(), 'Body text.');
});

test('indexes, edits, captures, and trashes a folder-structured library', async () => {
  const root = await mkdtemp(join(tmpdir(), 'shared-library-electron-'));
  const trashed: string[] = [];
  try {
    await mkdir(join(root, 'library', 'summaries', 'brief'), { recursive: true });
    await writeFile(
      join(root, 'topics.md'),
      `topics:\n  - id: "research"\n    title: "Research"\n`
    );
    await writeFile(
      join(root, 'library', 'example.md'),
      `---
id: "capture-1"
title: "Example document"
created_at: "2026-07-24T08:00:00.000Z"
tags: ["example"]
topics:
  - "research"
---

Original body.
`
    );
    await writeFile(
      join(root, 'library', 'summaries', 'brief', 'example.md'),
      'Brief summary.'
    );

    const service = new LibraryService(root, 'linux', async (path) => {
      trashed.push(path);
    });
    const initial = await service.snapshot();
    assert.equal(initial.entries.length, 1);
    assert.equal(initial.entries[0].title, 'Example document');
    assert.deepEqual(initial.entries[0].topicNames, ['Research']);
    assert.deepEqual(initial.entries[0].availableVariants, ['brief', 'source']);
    assert.equal(await service.readText(initial.entries[0].id, 'source'), 'Original body.');

    await service.writeText(initial.entries[0].id, 'source', 'Edited body.');
    const stored = await readFile(join(root, 'library', 'example.md'), 'utf8');
    assert.match(stored, /id: "capture-1"/);
    assert.match(stored, /Edited body\./);

    const capturedID = await service.captureText('A new clipboard thought');
    const afterCapture = await service.snapshot();
    assert.ok(afterCapture.entries.some((entry) => entry.captureID === capturedID));

    await service.trashCapture(initial.entries[0].id);
    assert.deepEqual(
      trashed.map((path) => path.slice(root.length + 1)).sort(),
      [
        'library/example.md',
        'library/summaries/brief/example.md'
      ]
    );
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});
