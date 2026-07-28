import assert from 'node:assert/strict';
import test from 'node:test';
import { isTrustedRendererURL, isWebURL } from './security.js';

test('renderer navigation stays on the packaged entry document', () => {
  const entry = 'file:///Applications/Briefly.app/Contents/Resources/app.asar/out/renderer/index.html';
  assert.equal(isTrustedRendererURL(`${entry}#/library`, entry), true);
  assert.equal(isTrustedRendererURL('https://example.com/', entry), false);
  assert.equal(
    isTrustedRendererURL(
      'file:///Applications/Briefly.app/Contents/Resources/app.asar/out/renderer/other.html',
      entry
    ),
    false
  );
});

test('only HTTP web links may leave the desktop app', () => {
  assert.equal(isWebURL('https://readbriefly.fyi/'), true);
  assert.equal(isWebURL('http://localhost:5173/'), true);
  assert.equal(isWebURL('file:///etc/passwd'), false);
  assert.equal(isWebURL('javascript:alert(1)'), false);
  assert.equal(isWebURL('not a URL'), false);
});
