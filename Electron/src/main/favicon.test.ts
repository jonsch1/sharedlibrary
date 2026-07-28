import assert from 'node:assert/strict';
import test from 'node:test';
import { faviconExtension } from './favicon.js';

test('accepts common raster favicon signatures and rejects arbitrary bytes', () => {
  assert.equal(faviconExtension(new Uint8Array([0, 0, 1, 0])), 'ico');
  assert.equal(
    faviconExtension(new Uint8Array([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])),
    'png'
  );
  assert.equal(faviconExtension(new TextEncoder().encode('not an image')), undefined);
});
