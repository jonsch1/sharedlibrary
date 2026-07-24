import assert from 'node:assert/strict';
import test from 'node:test';
import {
  defaultProcessingPrompt,
  renderProcessingPrompt
} from './processing.js';

test('renders the editable processing template with topics and source content', () => {
  const prompt = renderProcessingPrompt(defaultProcessingPrompt, {
    title: 'Example',
    sourceURL: 'https://example.com',
    sourceText: 'Captured source text.',
    topics: ['Research Practice', 'New Methods']
  });

  assert.match(prompt, /"Research Practice"/);
  assert.match(prompt, /"source_text": "Captured source text\."/);
  assert.doesNotMatch(prompt, /\{\{topics\}\}|\{\{source\}\}/);
});

test('requires both processing-template placeholders', () => {
  assert.throws(
    () =>
      renderProcessingPrompt('Summarize {{source}}', {
        title: 'Example',
        sourceText: 'Text',
        topics: []
      }),
    /\{\{topics\}\}/
  );
});
