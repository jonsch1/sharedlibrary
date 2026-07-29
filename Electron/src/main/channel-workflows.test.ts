import assert from 'node:assert/strict';
import test from 'node:test';

import {
  redditChannelFromAtom,
  redditCommunityFeedURL,
  xChannelItems
} from '../shared/browser-workflow.js';

test('an X profile channel returns its latest five unique non-pinned posts', () => {
  const post = (id: number, pinned = false) => ({
    id: String(id),
    url: `https://x.com/example/status/${id}`,
    text: `Example\n@example\nPost ${id}\nReply\nShare`,
    publishedAt: `2026-07-${String(id).padStart(2, '0')}T10:00:00.000Z`,
    pinned
  });
  const items = xChannelItems([
    post(2),
    post(8, true),
    post(7),
    post(4),
    post(7),
    post(1),
    post(6),
    post(3),
    post(5)
  ], 'example');

  assert.deepEqual(items.map(({ id }) => id), ['7', '6', '5', '4', '3']);
  assert.deepEqual(items.map(({ title }) => title), [
    'Post 7',
    'Post 6',
    'Post 5',
    'Post 4',
    'Post 3'
  ]);
});

test('a Reddit community channel returns five hot posts without scraping HTML', () => {
  const source = 'https://www.reddit.com/r/technology/';
  assert.equal(
    redditCommunityFeedURL(source),
    'https://www.reddit.com/r/technology/hot/.rss?limit=5'
  );
  const entry = (index: number) => `<entry>
    <author><name>/u/person${index}</name></author>
    <content type="html">&lt;a href=&quot;https://example.com/article-${index}&quot;&gt;[link]&lt;/a&gt;</content>
    <id>t3_post${index}</id>
    <link href="https://www.reddit.com/r/technology/comments/post${index}/title/" />
    <published>2026-07-${String(index).padStart(2, '0')}T10:00:00+00:00</published>
    <title>Post ${index}</title>
  </entry>`;
  const channel = redditChannelFromAtom(
    `<feed>${Array.from({ length: 7 }, (_, index) => entry(index + 1)).join('')}</feed>`,
    source,
    'https://www.reddit.com/r/technology/hot/.rss?limit=5'
  );

  assert.equal(channel.title, 'r/technology');
  assert.equal(channel.items.length, 5);
  assert.equal(channel.items[0].id, 't3_post1:headless-2');
  assert.equal(channel.items[0].linkedURL, 'https://example.com/article-1');
  assert.match(channel.items[0].content, /Linked article: https:\/\/example.com\/article-1/);
  assert.match(channel.items[0].content, /Discussion: https:\/\/www.reddit.com/);
});
