import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';

test('web and Electron use the shared application shell', async () => {
  const [electron, web] = await Promise.all([
    readFile(new URL('../Electron/src/renderer/App.svelte', import.meta.url), 'utf8'),
    readFile(new URL('../Web/src/routes/+page.svelte', import.meta.url), 'utf8')
  ]);

  assert.match(electron, /Shared\/App\.svelte/);
  assert.match(web, /Shared\/App\.svelte/);
});
