import assert from 'node:assert/strict';
import test from 'node:test';
import { speechChunks } from './narration.js';

test('narration starts with short playable segments and preserves the text', () => {
  const text =
    'First sentence is short. ' +
    `${'A longer passage with several words '.repeat(30)}ends here. ` +
    'Last sentence.';
  const chunks = speechChunks(text);
  assert.ok(chunks.length > 2);
  assert.ok(chunks.every((chunk) => chunk.length <= 360));
  assert.equal(
    chunks.join(' ').replace(/\s+/g, ' ').trim(),
    text.replace(/\s+/g, ' ').trim()
  );
});
