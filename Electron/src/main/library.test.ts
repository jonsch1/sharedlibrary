import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { mkdtemp, mkdir, readFile, readdir, rename, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, relative } from 'node:path';
import test from 'node:test';
import { LibraryService, parseMarkdown } from './library.js';

test('parses Briefly frontmatter lists and keeps the body separate', () => {
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

test('stores and indexes podcast WAV audio with its episode', async () => {
  const root = await mkdtemp(join(tmpdir(), 'briefly-podcast-audio-'));
  const trashed: string[] = [];
  try {
    await mkdir(join(root, 'podcasts'), { recursive: true });
    await writeFile(
      join(root, 'podcasts', 'daily-ai.md'),
      `---\nid: "daily-ai"\nname: "Daily AI"\nschedule: "daily"\nlength: "short"\nsources:\n  - "https://example.com/feed"\n---\n`
    );
    const service = new LibraryService(root, 'linux', async (path) => {
      trashed.push(path);
    });
    const wav = new Uint8Array(44);
    wav.set(Buffer.from('RIFF'), 0);
    wav.set(Buffer.from('WAVE'), 8);
    const entryID = await service.capturePodcastEpisode({
      podcastID: 'daily-ai',
      podcastTitle: 'Daily AI',
      title: 'Daily AI — today',
      body: 'Episode script.',
      sources: ['https://example.com/feed'],
      sourceIDs: ['personal:source-1'],
      audio: wav
    });
    const entry = (await service.snapshot()).entries.find(({ id }) => id === entryID);
    assert.equal(entry?.hasAudio, true);
    assert.deepEqual(entry?.sourceIDs, ['personal:source-1']);
    assert.deepEqual(entry?.sourceURLs, ['https://example.com/feed']);
    const audioPath = await service.podcastAudioPath(entryID);
    assert.deepEqual(await readFile(audioPath), Buffer.from(wav));
    const mirror = await service.buildDriveMirror();
    const projected = mirror.index.entries.find(({ id }) => id === entryID);
    assert.equal(projected?.audio?.contentHash, createHash('sha256').update(wav).digest('hex'));
    assert.equal(mirror.media[0]?.content, Buffer.from(wav).toString('base64'));
    assert.deepEqual(mirror.index.podcasts, [
      {
        id: 'daily-ai',
        filename: 'daily-ai.md',
        title: 'Daily AI',
        schedule: 'daily',
        length: 'short',
        sources: ['https://example.com/feed']
      }
    ]);
    await service.trashCapture(entryID);
    assert.deepEqual(
      trashed.map((path) => relative(root, path)).sort(),
      [join('library', 'audio', `${entry?.captureID}.wav`), join('library', entry!.filename)]
    );
  } finally {
    await rm(root, { recursive: true, force: true });
  }
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
    assert.equal(
      await service.filePath(initial.entries[0].id, 'brief'),
      join(root, 'library', 'summaries', 'brief', 'example.md')
    );

    assert.deepEqual(await service.topicDefinitions(), [
      { id: 'research', title: 'Research' }
    ]);
    const topics = await service.replaceTopicDefinitions([
      { id: 'research', title: 'Research Practice' },
      { id: '', title: 'New Methods' }
    ]);
    assert.deepEqual(topics, [
      { id: 'research', title: 'Research Practice' },
      { id: 'new-methods', title: 'New Methods' }
    ]);
    assert.deepEqual(
      (await service.processingInput(initial.entries[0].id)).topics,
      ['Research Practice', 'New Methods']
    );
    await assert.rejects(
      service.replaceTopicDefinitions([{ id: 'new-methods', title: 'New Methods' }]),
      /still used/
    );

    await service.writeText(initial.entries[0].id, 'source', 'Edited body.');
    const stored = await readFile(join(root, 'library', 'example.md'), 'utf8');
    assert.match(stored, /id: "capture-1"/);
    assert.match(stored, /Edited body\./);

    const capturedID = await service.captureText('A new clipboard thought');
    const podcastSourceID = await service.captureText(
      'https://example.com/podcast-source',
      {
        content: 'Podcast source body.',
        sourceURL: 'https://example.com/podcast-source',
        entryType: 'podcast_source'
      }
    );
    const afterCapture = await service.snapshot();
    assert.ok(afterCapture.entries.some((entry) => entry.captureID === capturedID));
    assert.equal(
      afterCapture.entries.find((entry) => entry.captureID === podcastSourceID)?.entryType,
      'podcast_source'
    );
    const migrated = await service.markPodcastSources([`personal:${capturedID}`]);
    assert.equal(
      migrated.entries.find((entry) => entry.captureID === capturedID)?.entryType,
      'podcast_source'
    );

    const researchTopic = await service.ensureTopic('Approved Research');
    const favicon = {
      bytes: new Uint8Array([0, 0, 1, 0]),
      extension: 'ico' as const
    };
    const researchedID = await service.captureText(
      'https://example.com/research',
      {
        title: 'Approved source',
        content: 'Approved source body.',
        sourceURL: 'https://example.com/research',
        mediaURL: 'https://cdn.example.com/research.mp3',
        audio: {
          bytes: new Uint8Array([26, 69, 223, 163]),
          extension: 'webm'
        },
        favicon
      },
      [researchTopic.id]
    );
    await service.captureText('https://example.com/other', {
      title: 'Same favicon',
      content: 'Another source.',
      sourceURL: 'https://example.com/other',
      favicon
    });
    await service.applyProcessingSuggestion(
      `personal:${researchedID}`,
      {
        shortFilename: 'approved-source',
        topicName: 'Wrong automatic topic',
        summaries: {
          brief: 'Brief.',
          concise: 'Concise.',
          detailed: 'Detailed.',
          comprehensive: 'Comprehensive.'
        }
      },
      researchTopic.id
    );
    const researched = (await service.snapshot()).entries.find(
      (entry) => entry.captureID === researchedID
    );
    assert.deepEqual(researched?.topicIDs, [researchTopic.id]);
    assert.equal(researched?.mediaURL, 'https://cdn.example.com/research.mp3');
    assert.equal(researched?.hasAudio, true);
    assert.deepEqual(
      await readFile(await service.podcastAudioPath(`personal:${researchedID}`)),
      Buffer.from([26, 69, 223, 163])
    );
    const faviconID = createHash('sha256').update(favicon.bytes).digest('hex');
    assert.equal(researched?.faviconFile, `${faviconID}.ico`);
    assert.deepEqual(await readdir(join(root, 'library', 'favicons')), [
      `${faviconID}.ico`
    ]);
    assert.equal(
      await service.faviconPath(`${faviconID}.ico`),
      join(root, 'library', 'favicons', `${faviconID}.ico`)
    );
    assert.deepEqual(researched?.availableVariants, [
      'brief',
      'concise',
      'detailed',
      'comprehensive',
      'source'
    ]);

    await service.trashCapture(initial.entries[0].id);
    assert.deepEqual(
      trashed.map((path) => relative(root, path)).sort(),
      [
        join('library', 'example.md'),
        join('library', 'summaries', 'brief', 'example.md')
      ]
    );
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test('builds a folder-preserving Drive mirror and keeps local files on the first merge', async () => {
  const root = await mkdtemp(join(tmpdir(), 'shared-library-electron-sync-'));
  try {
    await mkdir(join(root, 'library'), { recursive: true });
    await writeFile(
      join(root, 'library', 'local.md'),
      `---\nid: "local-1"\ntitle: "Local"\ntopics: []\ntags: []\n---\n\nLocal text.\n`
    );
    const service = new LibraryService(root, 'linux', async () => {});
    const local = await service.buildDriveMirror();
    assert.deepEqual(local.files.map((file) => file.path), ['library/local.md']);
    assert.equal(local.index.schemaVersion, 3);
    assert.equal(local.index.entries[0].texts[0].path, 'library/local.md');

    const remoteText = `---\nid: "local-1"\ntitle: "Remote"\ntopics: []\ntags: []\n---\n\nRemote text.\n`;
    const remoteOnly = `---\nid: "remote-2"\ntitle: "Remote only"\ntopics: []\ntags: []\n---\n\nNew remote text.\n`;
    const remoteFiles = [
      {
        path: 'library/local.md',
        contentHash: createHash('sha256').update(remoteText).digest('hex'),
        byteCount: Buffer.byteLength(remoteText)
      },
      {
        path: 'library/remote-only.md',
        contentHash: createHash('sha256').update(remoteOnly).digest('hex'),
        byteCount: Buffer.byteLength(remoteOnly)
      }
    ];
    const merge = await service.mergeRemoteMirror(
      {
        schemaVersion: 3,
        generatedAt: new Date().toISOString(),
        files: remoteFiles,
        entries: []
      },
      async (file) => (file.path.endsWith('remote-only.md') ? remoteOnly : remoteText)
    );
    assert.deepEqual(merge, { changed: 1, conflicts: 0 });
    assert.match(await readFile(join(root, 'library', 'local.md'), 'utf8'), /Local text/);
    assert.match(
      await readFile(join(root, 'library', 'remote-only.md'), 'utf8'),
      /New remote text/
    );
    const remoteAudio = new Uint8Array([1, 2, 3, 4]);
    const remoteAudioHash = createHash('sha256').update(remoteAudio).digest('hex');
    const mediaDownloaded = await service.mergeRemoteMedia(
      {
        schemaVersion: 3,
        generatedAt: new Date().toISOString(),
        files: [],
        entries: [
          {
            id: 'personal:remote-audio',
            captureID: 'remote-audio',
            title: 'Remote audio',
            excerpt: '',
            topicIDs: [],
            topicNames: [],
            tags: [],
            origin: 'personal',
            texts: [],
            audio: {
              kind: 'audio',
              path: 'library/audio/remote-audio.wav',
              contentHash: remoteAudioHash,
              byteCount: remoteAudio.byteLength,
              contentType: 'audio/wav'
            }
          }
        ]
      },
      async () => remoteAudio
    );
    assert.equal(mediaDownloaded, 1);
    assert.deepEqual(
      await readFile(join(root, 'library', 'audio', 'remote-audio.wav')),
      Buffer.from(remoteAudio)
    );
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test('sync applies a remote deletion when the local file is unchanged', async () => {
  const root = await mkdtemp(join(tmpdir(), 'shared-library-electron-remote-delete-'));
  try {
    const sourcePath = join(root, 'library', 'example.md');
    await mkdir(join(root, 'library'), { recursive: true });
    await writeFile(sourcePath, 'Original text.\n');
    const service = new LibraryService(root, 'linux', async (path) => {
      await rename(path, `${path}.trashed`);
    });
    const baseline = await service.buildDriveMirror();
    await service.saveSyncBaseline(baseline.index.files);

    const merge = await service.mergeRemoteMirror(
      {
        schemaVersion: 3,
        generatedAt: new Date().toISOString(),
        files: [],
        entries: []
      },
      async () => {
        throw new Error('A deleted remote file must not be downloaded.');
      }
    );

    assert.deepEqual(merge, { changed: 1, conflicts: 0 });
    await assert.rejects(readFile(sourcePath, 'utf8'));
    assert.equal(await readFile(`${sourcePath}.trashed`, 'utf8'), 'Original text.\n');
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test('sync keeps both copies when the same file changed locally and remotely', async () => {
  const root = await mkdtemp(join(tmpdir(), 'shared-library-electron-conflict-'));
  try {
    const sourcePath = join(root, 'library', 'example.md');
    const original = `---\nid: "example"\ntitle: "Example"\n---\n\nOriginal.\n`;
    const local = original.replace('Original.', 'Changed locally.');
    const remote = original.replace('Original.', 'Changed remotely.');
    await mkdir(join(root, 'library'), { recursive: true });
    await writeFile(sourcePath, original);
    const service = new LibraryService(root, 'linux', async (path) => {
      await rename(path, `${path}.trashed`);
    });
    const baseline = await service.buildDriveMirror();
    await service.saveSyncBaseline(baseline.index.files);
    await writeFile(sourcePath, local);

    const merge = await service.mergeRemoteMirror(
      {
        schemaVersion: 3,
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

    assert.deepEqual(merge, { changed: 1, conflicts: 1 });
    assert.equal(await readFile(sourcePath, 'utf8'), remote);
    const conflict = await readFile(join(root, 'library', 'example-conflict.md'), 'utf8');
    assert.match(conflict, /Changed locally/);
    assert.doesNotMatch(conflict, /id: "example"/);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});
