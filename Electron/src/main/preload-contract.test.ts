import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { join } from 'node:path';
import test from 'node:test';

const electronRoot = fileURLToPath(new URL('../../', import.meta.url));

test('the sandboxed preload is emitted and loaded as CommonJS', async () => {
  const [viteConfig, mainProcess] = await Promise.all([
    readFile(join(electronRoot, 'electron.vite.config.ts'), 'utf8'),
    readFile(join(electronRoot, 'src', 'main', 'index.ts'), 'utf8')
  ]);

  assert.match(viteConfig, /format:\s*'cjs'/);
  assert.match(viteConfig, /entryFileNames:\s*'\[name\]\.cjs'/);
  assert.match(mainProcess, /\.\.\/preload\/index\.cjs/);
  assert.doesNotMatch(mainProcess, /\.\.\/preload\/index\.mjs/);
});
