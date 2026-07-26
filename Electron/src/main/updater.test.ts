import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { join } from 'node:path';
import test from 'node:test';

const electronRoot = fileURLToPath(new URL('../../', import.meta.url));

test('packaged releases include the differential update feed', async () => {
  const [mainProcess, packageFile, releaseWorkflow] = await Promise.all([
    readFile(join(electronRoot, 'src', 'main', 'index.ts'), 'utf8'),
    readFile(join(electronRoot, 'package.json'), 'utf8'),
    readFile(join(electronRoot, '..', '.github', 'workflows', 'desktop-release-assets.yml'), 'utf8')
  ]);
  const build = JSON.parse(packageFile).build;

  assert.match(mainProcess, /app\.isPackaged[\s\S]+checkForUpdatesAndNotify/);
  assert.deepEqual(build.publish, {
    provider: 'github',
    owner: 'jonsch1',
    repo: 'briefly-downloads'
  });
  assert.deepEqual(build.mac.target, ['dmg', 'zip']);
  for (const file of ['latest-mac.yml', 'latest.yml', 'latest-linux.yml', '.blockmap']) {
    assert.match(releaseWorkflow, new RegExp(file.replace('.', '\\.')));
  }
});
