import assert from 'node:assert/strict';
import test from 'node:test';

import {
  defaultPodcastPrompt,
  nextPodcastRun,
  parsePodcast,
  podcastAudioRange,
  renderPodcastPrompt
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
