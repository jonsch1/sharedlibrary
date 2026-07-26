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

  assert.match(
    mainProcess,
    /app\.isPackaged && !process\.windowsStore[\s\S]+checkForUpdatesAndNotify/
  );
  assert.deepEqual(build.publish, {
    provider: 'github',
    owner: 'jonsch1',
    repo: 'briefly-downloads'
  });
  assert.deepEqual(build.mac.target, ['dmg', 'zip']);
  assert.equal(build.mac.identity, 'Developer ID Application');
  assert.equal(build.mac.notarize, true);
  assert.equal(build.dmg.sign, true);
  assert.deepEqual(build.appx, {
    identityName: 'gutercomputer.BrieflyDesktop',
    publisher: 'CN=C904E9B2-14E0-4A8B-AFD2-BE4354B83009',
    publisherDisplayName: 'gutercomputer',
    displayName: 'Briefly',
    artifactName: 'Briefly-windows-store-${arch}.${ext}'
  });
  assert.match(releaseWorkflow, /xcrun notarytool submit/);
  assert.match(releaseWorkflow, /xcrun stapler staple/);
  assert.match(releaseWorkflow, /spctl --assess --type open/);
  assert.match(releaseWorkflow, /Get-AuthenticodeSignature/);
  assert.match(releaseWorkflow, /--win appx --x64 --config\.win\.signExecutable=false/);
  assert.match(releaseWorkflow, /artifact_name: store-windows/);
  assert.match(releaseWorkflow, /pattern: briefly-\*/);
  assert.match(releaseWorkflow, /store_only:/);
  assert.match(releaseWorkflow, /store-package:/);
  for (const file of ['latest-mac.yml', 'latest.yml', 'latest-linux.yml', '.blockmap']) {
    assert.match(releaseWorkflow, new RegExp(file.replace('.', '\\.')));
  }
});
