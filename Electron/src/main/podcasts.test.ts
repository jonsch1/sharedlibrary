import assert from 'node:assert/strict';
import { mkdtemp, mkdir, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';

import type { ExtractionService } from './extraction.js';
import { LibraryService } from './library.js';
import {
  defaultPodcastPrompt,
  nextPodcastRun,
  parsePodcast,
  PodcastService,
  podcastAudioRange,
  renderPodcastPrompt,
  sourceIdentity
} from './podcasts.js';

test('podcasts are editable Markdown files with a plain source list', () => {
  const podcast = parsePodcast(
    `---
name: "AI Daily"
schedule: "weekly mon 07:30"
sources:
  - "https://example.com/feed.xml"
  - "arxiv:agent alignment"
---

Connect the updates into one practical story.
`,
    'ai-daily.md'
  );
  assert.equal(podcast.id, 'file:ai-daily.md');
  assert.equal(podcast.title, 'AI Daily');
  assert.equal(podcast.length, '');
  assert.equal(podcast.prompt, 'Connect the updates into one practical story.');
  assert.deepEqual(podcast.sources, [
    'https://example.com/feed.xml',
    'arxiv:agent alignment'
  ]);
});

test('calculates daily and weekly runs in the podcast timezone', () => {
  assert.equal(
    nextPodcastRun(
      'daily 07:30',
      'Europe/Amsterdam',
      new Date('2026-07-27T05:00:00.000Z')
    )?.toISOString(),
    '2026-07-27T05:30:00.000Z'
  );
  assert.equal(
    nextPodcastRun(
      'weekly tue 09:00',
      'Europe/Amsterdam',
      new Date('2026-07-27T10:00:00.000Z')
    )?.toISOString(),
    '2026-07-28T07:00:00.000Z'
  );
  assert.equal(nextPodcastRun('manual', 'UTC', new Date()), null);
});

test('renders the editable podcast prompt', () => {
  const prompt = renderPodcastPrompt(
    defaultPodcastPrompt,
    {
      title: 'AI Daily',
      length: '12 minutes',
      prompt: 'Focus on practical consequences.'
    },
    ['SOURCE_ID: 1\nCONTENT:\nNews']
  );
  assert.match(prompt, /Podcast: "AI Daily"/);
  assert.match(prompt, /Podcast-specific instructions:\nFocus on practical consequences\./);
  assert.match(prompt, /Requested length: "12 minutes"/);
  assert.match(prompt, /<source>[\s\S]*News[\s\S]*<\/source>/);
  assert.doesNotMatch(prompt, /\{\{(?:podcast_title|requested_length|source_packets)\}\}/);
});

test('uses a complete per-podcast prompt as the template', () => {
  const prompt = renderPodcastPrompt(
    defaultPodcastPrompt,
    {
      title: 'AI Daily',
      length: '',
      prompt: defaultPodcastPrompt.replace(
        'Be direct, conversational, and useful',
        'Be skeptical, concise, and useful'
      )
    },
    ['SOURCE_ID: 1\nCONTENT:\nNews']
  );
  assert.match(prompt, /Be skeptical, concise, and useful/);
  assert.doesNotMatch(prompt, /Podcast-specific instructions/);
  assert.doesNotMatch(prompt, /\{\{(?:podcast_title|requested_length|source_packets)\}\}/);
});

test('maps podcast audio byte ranges', () => {
  assert.deepEqual(podcastAudioRange(null, 100), { start: 0, end: 99 });
  assert.deepEqual(podcastAudioRange('bytes=20-', 100), { start: 20, end: 99 });
  assert.deepEqual(podcastAudioRange('bytes=20-29', 100), { start: 20, end: 29 });
  assert.deepEqual(podcastAudioRange('bytes=-10', 100), { start: 90, end: 99 });
  assert.equal(podcastAudioRange('bytes=100-', 100), null);
  assert.equal(podcastAudioRange('bytes=0-1,4-5', 100), null);
});

test('identifies social posts and canonical web URLs consistently', () => {
  assert.equal(
    sourceIdentity('https://twitter.com/openai/status/123?utm_source=test'),
    'x:status:123'
  );
  assert.equal(
    sourceIdentity('https://www.reddit.com/r/test/comments/AbC/title/?utm_medium=social'),
    'reddit:post:abc'
  );
  assert.equal(
    sourceIdentity('https://example.com/report?utm_source=test&id=4#section'),
    'https://example.com/report?id=4'
  );
  assert.equal(sourceIdentity('not a url'), 'not a url');
});

test('agent episodes reuse social posts and queue audio once', async () => {
  const root = await mkdtemp(join(tmpdir(), 'briefly-agent-podcast-'));
  try {
    await mkdir(join(root, 'podcasts'), { recursive: true });
    await writeFile(
      join(root, 'podcasts', 'social.md'),
      `---
name: "Social brief"
schedule: "manual"
sources:
  - "https://x.com/openai"
---

Explain why each update matters.
`
    );
    const library = new LibraryService(root, 'linux', async () => {});
    let audioRuns = 0;
    const service = new PodcastService(
      () => root,
      library,
      {} as ExtractionService,
      async () => {
        audioRuns += 1;
        return new Uint8Array([1, 2, 3]);
      },
      async () => {},
      () => {},
      async () => {},
      () => {},
      () => {},
      () => () => {}
    );
    const first = await service.createAgentEpisode(
      'file:social.md',
      '# Today in AI\n\nOne useful update.',
      [
        {
          url: 'https://twitter.com/openai/status/123?utm_source=timeline',
          title: 'OpenAI update',
          content: 'The update text.'
        }
      ]
    );
    await service.snapshot();
    const second = await service.createAgentEpisode(
      'file:social.md',
      '# Duplicate attempt',
      [{ url: 'https://x.com/openai/status/123', content: 'The same update.' }]
    );
    const entries = (await library.snapshot()).entries;

    assert.equal(first.duplicate, false);
    assert.equal(second.duplicate, true);
    assert.equal(audioRuns, 1);
    assert.equal(
      entries.filter(({ entryType }) => entryType === 'podcast_episode').length,
      1
    );
    assert.equal(
      entries.filter(({ entryType }) => entryType === 'podcast_source').length,
      1
    );
    assert.equal(entries.find(({ id }) => id === first.entryID)?.hasAudio, true);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test('source checks ingest every unseen item', async () => {
  const root = await mkdtemp(join(tmpdir(), 'briefly-open-podcast-'));
  try {
    await mkdir(join(root, 'podcasts'), { recursive: true });
    await writeFile(
      join(root, 'podcasts', 'open.md'),
      `---
name: "Open brief"
schedule: "manual"
sources:
  - "https://example.com/feed.xml"
---

Summarize every new item.
`
    );
    const items = Array.from({ length: 31 }, (_, index) => ({
      id: String(index),
      title: `Item ${index}`,
      url: `https://example.com/items/${index}`
    }));
    const extraction = {
      discoverSource: async () => ({ title: 'Feed', kind: 'feed', items }),
      extractURL: async (url: string) => ({
        title: url.split('/').at(-1),
        content: `Content for ${url}`,
        sourceURL: url
      })
    } as unknown as ExtractionService;
    const library = new LibraryService(root, 'linux', async () => {});
    const service = new PodcastService(
      () => root,
      library,
      extraction,
      async () => new Uint8Array(),
      async () => {},
      () => {},
      async () => {},
      () => {},
      () => {},
      () => () => {}
    );

    const snapshot = await service.check('file:open.md');
    assert.equal(snapshot.podcasts[0]?.sourceStatuses[0]?.itemCount, 31);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});
