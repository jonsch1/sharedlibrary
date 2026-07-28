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
          BRIEFLY_E2E_USER_DATA: userDataPath
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

      await expect(page).toHaveTitle('Briefly');
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

      const actionBar = page.getByLabel('Document actions');
      await expect(actionBar.getByRole('radio')).toHaveCount(
        snapshot.entries[0].availableVariants.length
      );
      await expect(actionBar.locator('.native-footer-actions')).toHaveCSS('opacity', '1');
      const actionBarWidth = await actionBar.evaluate(
        (element) => element.getBoundingClientRect().width
      );
      await actionBar.hover();
      expect(
        await actionBar.evaluate((element) => element.getBoundingClientRect().width)
      ).toBe(actionBarWidth);
      expect(actionBarWidth).toBe(500);
      await expect(actionBar).toHaveCSS('column-gap', '16px');
      await expect(actionBar.locator('.native-footer-actions')).toHaveCSS('column-gap', '8px');
      await expect(actionBar.getByRole('button', { name: 'Settings' })).toHaveCount(0);
      const sidebarActions = page.locator('.native-sidebar-footer');
      await expect(sidebarActions.getByRole('button', { name: 'Pod' })).toBeVisible();
      await expect(sidebarActions.getByRole('button', { name: 'AI' })).toBeVisible();
      await expect(sidebarActions.getByRole('button', { name: 'Settings' })).toBeVisible();
      const sidebarButtonGaps = await sidebarActions.locator('button').evaluateAll(
        (buttons) =>
          buttons.slice(1).map((button, index) => {
            const previous = buttons[index].getBoundingClientRect();
            return button.getBoundingClientRect().left - previous.right;
          })
      );
      expect(Math.min(...sidebarButtonGaps)).toBeGreaterThanOrEqual(7);

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

      await page.getByRole('button', { name: 'Pod', exact: true }).click();
      await expect(page.getByText('No podcast episodes')).toBeVisible();
      await page.getByRole('button', { name: 'Manage podcasts' }).click();
      await expect(page.locator('.settings-screen')).toBeVisible();
      await expect(page.getByRole('button', { name: 'Topics' })).toBeVisible();
      await expect(page.getByRole('button', { name: 'Prompts' })).toBeVisible();
      await expect(page.getByRole('button', { name: 'Summarization' })).toBeVisible();
      await expect(page.getByRole('button', { name: 'Podcast', exact: true })).toBeVisible();
      await expect(page.getByRole('button', { name: 'Research', exact: true })).toHaveCount(0);
      await expect(page.getByRole('button', { name: 'Input extensions' })).toHaveCount(0);
      await page.getByRole('button', { name: 'General' }).click();
      await expect(page.getByRole('heading', { name: 'Current document' })).toHaveCount(0);
      await page.getByRole('button', { name: 'Podcasts', exact: true }).click();
      await expect(page.getByRole('heading', { name: 'Create with an agent' })).toBeVisible();
      await page.getByRole('button', { name: 'Examples' }).click();
      await expect(page.getByRole('heading', { name: 'AI Research Weekly' })).toBeVisible();
      await page.getByRole('button', { name: 'Next' }).click();
      await expect(page.getByRole('heading', { name: 'Startup Signals' })).toBeVisible();
      await page.getByRole('button', { name: 'Use' }).click();
      await expect(page.getByRole('heading', { name: 'Name' })).toBeVisible();
      await expect(page.locator('.podcast-form-card input')).toHaveCount(1);
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
