import assert from 'node:assert/strict';
import test from 'node:test';
import {
  shouldRenderSourceAsPlainText
} from '../shared/source-presentation.js';

test('uses plain presentation for original YouTube transcripts', () => {
  for (const sourceURL of [
    'https://www.youtube.com/watch?v=abc123',
    'https://m.youtube.com/shorts/abc123',
    'https://www.youtube.com/live/abc123',
    'https://youtu.be/abc123',
    'https://www.youtube-nocookie.com/embed/abc123'
  ]) {
    assert.equal(shouldRenderSourceAsPlainText('source', sourceURL), true, sourceURL);
  }
});

test('keeps YouTube summaries rendered as Markdown', () => {
  assert.equal(
    shouldRenderSourceAsPlainText('concise', 'https://www.youtube.com/watch?v=abc123'),
    false
  );
});

test('keeps non-video sources rendered as Markdown', () => {
  for (const sourceURL of [
    undefined,
    'not a URL',
    'https://example.com/article',
    'https://youtube.com.evil.example/watch?v=abc123',
    'https://www.youtube.com/@creator'
  ]) {
    assert.equal(shouldRenderSourceAsPlainText('source', sourceURL), false, sourceURL);
  }
});
