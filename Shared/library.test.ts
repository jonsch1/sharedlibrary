import assert from 'node:assert/strict';
import test from 'node:test';
import {
  hasSameLibraryContent,
  isMainLibraryEntry,
  matchesLibraryEntry,
  parseLibraryProjection,
  preferredVariant,
  retainLoadedLibraryText,
  shouldRenderSourceAsPlainText
} from './library.ts';

const hash = 'a'.repeat(64);
const audioHash = 'b'.repeat(64);
const faviconHash = 'c'.repeat(64);
const projection = {
  schemaVersion: 3,
  generatedAt: '2026-07-28T12:00:00.000Z',
  files: [{ path: 'library/article.md', contentHash: hash, byteCount: 12 }],
  entries: [
    {
      id: 'personal:article',
      captureID: 'article',
      title: 'Shared reader contract',
      excerpt: 'One fixture for both clients.',
      topicIDs: ['engineering'],
      topicNames: ['Engineering'],
      tags: ['parity'],
      sourceURL: 'https://example.com/article',
      favicon: {
        kind: 'favicon',
        path: 'library/favicons/article.ico',
        contentHash: faviconHash,
        byteCount: 4,
        contentType: 'image/x-icon'
      },
      origin: 'personal',
      texts: [
        {
          variant: 'source',
          path: 'library/article.md',
          contentHash: hash,
          wordCount: 2
        }
      ]
    },
    {
      id: 'personal:source',
      title: 'Podcast source',
      excerpt: '',
      entryType: 'podcast_source',
      topicIDs: [],
      topicNames: [],
      tags: [],
      origin: 'personal',
      texts: [{ variant: 'source', text: 'Source' }]
    },
    {
      id: 'personal:episode',
      title: 'Podcast episode',
      excerpt: '',
      entryType: 'podcast_episode',
      podcastID: 'weekly',
      audio: {
        kind: 'audio',
        path: 'library/audio/episode.wav',
        contentHash: audioHash,
        byteCount: 44,
        contentType: 'audio/wav'
      },
      sourceIDs: ['personal:source'],
      topicIDs: [],
      topicNames: [],
      tags: ['podcast'],
      origin: 'personal',
      texts: [{ variant: 'source', text: 'Episode' }]
    }
  ],
  podcasts: [
    {
      id: 'weekly',
      filename: 'weekly.md',
      title: 'Weekly',
      schedule: 'weekly',
      length: 'short',
      sources: ['https://example.com/feed']
    }
  ]
};

test('desktop projections produce the same main library behavior for both clients', () => {
  const parsed = parseLibraryProjection(projection);
  assert.deepEqual(parsed.entries.filter(isMainLibraryEntry).map(({ id }) => id), [
    'personal:article',
    'personal:source'
  ]);
  assert.equal(matchesLibraryEntry(parsed.entries[0], 'ENGINEERING'), true);
  assert.equal(preferredVariant(parsed.entries[0]), 'source');
  assert.equal(
    shouldRenderSourceAsPlainText('source', parsed.entries[0].sourceURL),
    false
  );
  assert.equal(parsed.entries[0].favicon?.contentHash, faviconHash);
  assert.equal(parsed.entries[2].audio?.contentHash, audioHash);
  assert.equal(parsed.podcasts?.[0].title, 'Weekly');
});

test('background sync ignores local text caches and retains them across unrelated changes', () => {
  const left = parseLibraryProjection(projection);
  const right = structuredClone(left);
  left.entries[0].texts[0].text = 'Cached source';
  right.generatedAt = '2026-07-28T13:00:00.000Z';
  assert.equal(hasSameLibraryContent(left, right), true);
  right.entries[0].title = 'Updated title';
  const retained = retainLoadedLibraryText(left, right);
  assert.equal(retained.entries[0].texts[0].text, 'Cached source');
  assert.equal(right.entries[0].texts[0].text, undefined);
  assert.equal(hasSameLibraryContent(left, retained), false);
  retained.entries[0].title = left.entries[0].title;
  retained.entries[2].audio!.byteCount += 1;
  assert.equal(hasSameLibraryContent(left, retained), false);
  const changedText = structuredClone(right);
  changedText.entries[0].texts[0].contentHash = 'd'.repeat(64);
  delete changedText.entries[0].texts[0].text;
  assert.equal(retainLoadedLibraryText(left, changedText).entries[0].texts[0].text, undefined);
});

test('only YouTube originals use transcript presentation', () => {
  assert.equal(
    shouldRenderSourceAsPlainText('source', 'https://www.youtube.com/watch?v=abc123'),
    true
  );
  assert.equal(
    shouldRenderSourceAsPlainText('concise', 'https://www.youtube.com/watch?v=abc123'),
    false
  );
});
