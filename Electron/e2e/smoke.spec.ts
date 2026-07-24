import { expect, test } from '@playwright/test';
import { _electron as electron, type ElectronApplication, type Page } from 'playwright';
import { mkdtemp, mkdir, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import type { SharedLibraryDesktopAPI } from '../src/shared/contracts.js';

const electronRoot = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const launchScript = join(electronRoot, 'playwright.launch.mjs');
type ElectronWindow = Window &
  typeof globalThis & {
    sharedLibrary: SharedLibraryDesktopAPI;
  };

test(
  'launches the production app and reads and writes through the preload API',
  async ({}, testInfo) => {
    const temporaryRoot = await mkdtemp(join(tmpdir(), 'shared-library-e2e-'));
    const userDataPath = join(temporaryRoot, 'user-data');
    const workspacePath = join(temporaryRoot, 'workspace');
    let electronApp: ElectronApplication | undefined;
    let page: Page | undefined;
    let tracingStopped = false;
    const processOutput: string[] = [];

    try {
      await createFixture(userDataPath, workspacePath);

      electronApp = await electron.launch({
        args: [launchScript],
        cwd: electronRoot,
        env: {
          ...process.env,
          SHARED_LIBRARY_E2E_USER_DATA: userDataPath
        }
      });
      electronApp.process().stdout?.on('data', (chunk) => {
        processOutput.push(String(chunk));
      });
      electronApp.process().stderr?.on('data', (chunk) => {
        processOutput.push(String(chunk));
      });
      await electronApp.context().tracing.start({
        screenshots: true,
        snapshots: true,
        sources: true
      });

      const rendererErrors: string[] = [];
      try {
        page = await electronApp.firstWindow();
      } catch (error) {
        throw new Error(
          `Electron did not open a window.\n${processOutput.join('').trim()}`,
          { cause: error }
        );
      }
      page.on('pageerror', (error) => rendererErrors.push(error.message));
      page.on('console', (message) => {
        if (message.type() === 'error') rendererErrors.push(message.text());
      });

      await expect(page).toHaveTitle('Shared Library');
      await expect(
        page.getByRole('button', { name: 'Electron smoke fixture' })
      ).toBeVisible();
      await expect(page.locator('.native-document-body')).toContainText(
        'Brief smoke summary.'
      );

      const snapshot = await page.evaluate(() =>
        (window as ElectronWindow).sharedLibrary.getSnapshot()
      );
      expect(snapshot.workspacePath).toBe(workspacePath);
      expect(snapshot.entries).toHaveLength(1);
      expect(snapshot.entries[0].title).toBe('Electron smoke fixture');

      const entryID = snapshot.entries[0].id;
      const originalText = await page.evaluate(
        ({ id }) =>
          (window as ElectronWindow).sharedLibrary.readText(id, 'source'),
        { id: entryID }
      );
      expect(originalText).toBe('Original smoke body.');

      const editedText = 'Edited through the Electron preload bridge.';
      await page.evaluate(
        ({ id, text }) =>
          (window as ElectronWindow).sharedLibrary.writeText(id, 'source', text),
        { id: entryID, text: editedText }
      );
      await page.getByRole('radio', { name: 'Original' }).click();
      await expect(page.locator('.native-document-body')).toContainText(editedText);
      expect(rendererErrors).toEqual([]);
    } catch (error) {
      if (page) {
        await page
          .screenshot({
            path: testInfo.outputPath('failure.png'),
            fullPage: true
          })
          .catch(() => {});
      }
      if (electronApp) {
        await electronApp.context().tracing
          .stop({ path: testInfo.outputPath('trace.zip') })
          .catch(() => {});
        tracingStopped = true;
      }
      throw error;
    } finally {
      if (electronApp) {
        if (!tracingStopped) {
          await electronApp.context().tracing.stop().catch(() => {});
        }
        await electronApp.close().catch(() => {});
      }
      await rm(temporaryRoot, { recursive: true, force: true });
    }
  }
);

async function createFixture(
  userDataPath: string,
  workspacePath: string
): Promise<void> {
  await mkdir(join(workspacePath, 'library', 'summaries', 'brief'), {
    recursive: true
  });
  await mkdir(userDataPath, { recursive: true });

  await Promise.all([
    writeFile(
      join(userDataPath, 'settings.json'),
      `${JSON.stringify({ workspacePath }, null, 2)}\n`,
      'utf8'
    ),
    writeFile(
      join(workspacePath, 'topics.md'),
      'topics:\n  - id: "testing"\n    title: "Testing"\n',
      'utf8'
    ),
    writeFile(
      join(workspacePath, 'library', 'fixture.md'),
      `---
id: "electron-smoke"
title: "Electron smoke fixture"
created_at: "2026-07-24T08:00:00.000Z"
tags: ["ci"]
topics:
  - "testing"
---

Original smoke body.
`,
      'utf8'
    ),
    writeFile(
      join(workspacePath, 'library', 'summaries', 'brief', 'fixture.md'),
      'Brief smoke summary.\n',
      'utf8'
    )
  ]);
}
