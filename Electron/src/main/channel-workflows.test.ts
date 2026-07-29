import assert from 'node:assert/strict';
import test from 'node:test';

import { xChannelItems } from '../shared/browser-workflow.js';

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
