import assert from 'node:assert/strict';
import test from 'node:test';

import {
	isReadingDepth,
	libraryVariants,
	readingDepths,
	sourceVariant
} from './reading-depth.ts';
import {
	shouldRenderSourceAsPlainText,
	sourceTextParagraphs
} from './source-text.ts';

test('Shared exposes the public reader’s depth and source-text contracts', () => {
	assert.deepEqual(readingDepths, ['concise', 'detailed']);
	assert.deepEqual(libraryVariants, ['concise', 'detailed', 'source']);
	assert.equal(sourceVariant, 'source');
	assert.equal(isReadingDepth('detailed'), true);
	assert.equal(isReadingDepth(sourceVariant), false);

	assert.equal(
		shouldRenderSourceAsPlainText(sourceVariant, 'https://youtu.be/example-video'),
		true
	);
	assert.equal(
		shouldRenderSourceAsPlainText('concise', 'https://youtu.be/example-video'),
		false
	);
	assert.equal(
		shouldRenderSourceAsPlainText(sourceVariant, 'https://example.com/article'),
		false
	);
	assert.deepEqual(
		sourceTextParagraphs(' First line\r\ncontinues.\r\n\r\n>> Speaker one\n>> Speaker two '),
		['First line continues.', 'Speaker one', 'Speaker two']
	);
});
