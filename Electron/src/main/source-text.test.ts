import assert from 'node:assert/strict';
import test from 'node:test';
import { sourceTextParagraphs } from '../shared/source-text.js';

test('renders wrapped transcript text as flat speaker paragraphs', () => {
  assert.deepEqual(
    sourceTextParagraphs(`Transcript:
When I heard about this app idea,
I could not believe my eyes.
>> I launched at the end of 2025
and went from zero to $50,000.
>> This is Jake.
He is 24.`),
    [
      'Transcript: When I heard about this app idea, I could not believe my eyes.',
      'I launched at the end of 2025 and went from zero to $50,000.',
      'This is Jake. He is 24.'
    ]
  );
});

test('keeps ordinary plain-text quote and markdown characters literal', () => {
  assert.deepEqual(
    sourceTextParagraphs(`> 5 is still plain text.
# Not a heading

**Not bold.**`),
    ['> 5 is still plain text. # Not a heading', '**Not bold.**']
  );
});
