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
      const audio = page.locator('audio');
      await expect(audio).toHaveCount(1);
      await expect(page.locator('.native-reader-audio')).toBeVisible();
      await page.getByRole('slider', { name: 'Volume' }).fill('0.4');
      expect(await audio.evaluate((element: HTMLAudioElement) => element.volume)).toBe(0.4);

      const snapshot = await page.evaluate(() =>
        (window as ElectronWindow).sharedLibrary.getSnapshot()
      );
      expect(snapshot.workspacePath).toBe(workspacePath);
      expect(snapshot.entries).toHaveLength(2);
      expect(snapshot.entries[0].title).toBe('Electron smoke fixture');

      await page.getByRole('button', { name: 'Second smoke fixture' }).click({
        modifiers: ['Meta']
      });
      await expect(page.locator('.native-entry-row.selected')).toHaveCount(2);
      // ponytail: macOS Actions cannot dismiss native menus through CDP; the
      // Windows and Linux runners cover right-click selection until Playwright can.
      if (snapshot.platform !== 'darwin') {
        await page.getByRole('button', { name: 'Electron smoke fixture' }).click({
          button: 'right'
        });
        await page.keyboard.press('Escape');
        await expect(page.locator('.native-entry-row.selected')).toHaveCount(2);
      }
      await page.getByRole('button', { name: 'Electron smoke fixture' }).click();
      await expect(page.locator('.native-entry-row.selected')).toHaveCount(1);

      const firstBox = await page
        .getByRole('button', { name: 'Electron smoke fixture' })
        .boundingBox();
      const secondBox = await page
        .getByRole('button', { name: 'Second smoke fixture' })
        .boundingBox();
      expect(firstBox).not.toBeNull();
      expect(secondBox).not.toBeNull();
      await page.mouse.move(firstBox!.x + firstBox!.width / 2, firstBox!.y + firstBox!.height / 2);
      await page.mouse.down();
      await page.mouse.move(
        secondBox!.x + secondBox!.width / 2,
        secondBox!.y + secondBox!.height / 2
      );
      await page.mouse.up();
      await expect(page.locator('.native-entry-row.selected')).toHaveCount(2);
      await page.getByRole('button', { name: 'Electron smoke fixture' }).click();

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
      await expect(actionBar).toHaveCSS('height', '50px');
      await expect(actionBar).toHaveCSS('column-gap', '8px');
      await expect(actionBar.locator('.native-footer-actions')).toHaveCSS('column-gap', '2px');
      await expect(actionBar.getByRole('button', { name: 'Settings' })).toHaveCount(0);
      const viewTabs = page.getByRole('tablist', { name: 'Library view' });
      await expect(viewTabs.getByRole('tab', { name: 'Main' })).toHaveAttribute(
        'aria-selected',
        'true'
      );
      await expect(viewTabs.getByRole('tab', { name: 'Pod' })).toBeVisible();
      const sidebarActions = page.locator('.native-sidebar-footer');
      await expect(sidebarActions.getByRole('button', { name: 'AI' })).toBeVisible();
      await expect(sidebarActions.getByRole('button', { name: 'Settings' })).toBeVisible();
      await expect(sidebarActions).toHaveCSS('column-gap', '0px');
      await expect(sidebarActions).toHaveCSS('padding', '0px');
      const sidebarButtonWidths = await sidebarActions.locator('button').evaluateAll(
        (buttons) => buttons.map((button) => button.getBoundingClientRect().width)
      );
      expect(sidebarButtonWidths[0]).toBe(sidebarButtonWidths[1]);

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
      await audio.evaluate((element) => element.setAttribute('data-smoke-player', 'persistent'));
      await page.getByRole('radio', { name: 'Original' }).click();
      await expect(page.locator('.native-document-body')).toContainText(editedText);
      await expect(audio).toHaveCount(1);
      await expect(audio).toHaveAttribute('data-smoke-player', 'persistent');
      await audio.evaluate((element: HTMLAudioElement) => element.play());
      await expect
        .poll(() =>
          audio.evaluate((element: HTMLAudioElement) => element.currentTime)
        )
        .toBeGreaterThan(0);
      await audio.evaluate((element: HTMLAudioElement) => {
        element.pause();
        element.currentTime = 0.5;
        element.dispatchEvent(new Event('timeupdate'));
      });
      await page.getByRole('button', { name: 'Second smoke fixture' }).click();
      await expect(page.locator('audio')).toHaveCount(0);
      await page.getByRole('button', { name: 'Electron smoke fixture' }).click();
      await page.getByRole('radio', { name: 'Original' }).click();
      await expect
        .poll(() =>
          page!.locator('audio').evaluate((element: HTMLAudioElement) => element.currentTime)
        )
        .toBeGreaterThanOrEqual(0.49);

      await viewTabs.getByRole('tab', { name: 'Pod' }).click();
      await expect(viewTabs.getByRole('tab', { name: 'Pod' })).toHaveAttribute(
        'aria-selected',
        'true'
      );
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
      const saveAudio = page.getByRole('checkbox', {
        name: 'Save audio from manually captured YouTube videos'
      });
      await expect(saveAudio).toBeChecked();
      await saveAudio.uncheck();
      await expect
        .poll(() =>
          page!.evaluate(() =>
            (window as ElectronWindow).sharedLibrary.getAudioPreferences()
          )
        )
        .toEqual({ saveCapturedAudio: false });
      await expect(page.getByRole('button', { name: 'Feedback' })).toBeVisible();
      await page.getByRole('button', { name: 'Podcasts', exact: true }).click();
      const podcastSettings = page.locator('.podcast-document-workspace');
      await expect(
        podcastSettings.getByRole('button', { name: 'Smoke podcast' })
      ).toBeVisible();
      await expect(podcastSettings.getByLabel('Podcast title')).toHaveValue(
        'Smoke podcast'
      );
      const podcastPrompt = podcastSettings.getByLabel('Podcast prompt');
      await expect(podcastPrompt).toHaveValue('Keep the episode practical.');
      await expect(podcastSettings.getByLabel('Podcast sources')).toHaveValue(
        'https://example.invalid/feed.xml'
      );
      await expect(podcastSettings.getByText('weekly MON 08:00')).toHaveCount(0);
      await expect(podcastSettings.getByText('15 minutes')).toHaveCount(0);
      await podcastPrompt.fill('Explain why each update matters.');
      await expect
        .poll(() =>
          page!.evaluate(async () =>
            (await (window as ElectronWindow).sharedLibrary.getPodcasts()).podcasts[0]
              ?.prompt
          )
        )
        .toBe('Explain why each update matters.');
      await podcastSettings.getByRole('button', { name: 'Show episodes' }).click();
      await expect(page.locator('.settings-screen')).toHaveCount(0);
      await expect(viewTabs.getByRole('tab', { name: 'Pod' })).toHaveAttribute(
        'aria-selected',
        'true'
      );
      await expect(
        page.locator('.topic-strip').getByRole('button', { name: 'Smoke podcast' })
      ).toHaveClass(/active/);
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
  await mkdir(join(workspacePath, 'library', 'audio'), { recursive: true });
  await mkdir(join(workspacePath, 'podcasts'), { recursive: true });
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
audio_path: "audio/electron-smoke.wav"
tags: ["ci"]
topics:
  - "testing"
---

Original smoke body.
`,
      'utf8'
    ),
    writeFile(
      join(workspacePath, 'library', 'second.md'),
      `---
id: "electron-smoke-second"
title: "Second smoke fixture"
created_at: "2026-07-23T08:00:00.000Z"
tags: ["ci"]
topics:
  - "testing"
---

Second smoke body.
`,
      'utf8'
    ),
    writeFile(
      join(workspacePath, 'library', 'audio', 'electron-smoke.wav'),
      toneWav()
    ),
    writeFile(
      join(workspacePath, 'library', 'summaries', 'brief', 'fixture.md'),
      'Brief smoke summary.\n',
      'utf8'
    ),
    writeFile(
      join(workspacePath, 'podcasts', 'smoke-podcast.md'),
      `---
name: "Smoke podcast"
schedule: "weekly MON 08:00"
sources:
  - "https://example.invalid/feed.xml"
length: "15 minutes"
---

Keep the episode practical.
`,
      'utf8'
    )
  ]);
}

function toneWav(): Buffer {
  const sampleRate = 8_000;
  const samples = Buffer.alloc(sampleRate * 2);
  for (let index = 0; index < sampleRate; index += 1) {
    samples.writeInt16LE(
      Math.round(Math.sin((2 * Math.PI * 440 * index) / sampleRate) * 8_000),
      index * 2
    );
  }
  const wav = Buffer.alloc(44 + samples.length);
  wav.write('RIFF', 0);
  wav.writeUInt32LE(wav.length - 8, 4);
  wav.write('WAVEfmt ', 8);
  wav.writeUInt32LE(16, 16);
  wav.writeUInt16LE(1, 20);
  wav.writeUInt16LE(1, 22);
  wav.writeUInt32LE(sampleRate, 24);
  wav.writeUInt32LE(sampleRate * 2, 28);
  wav.writeUInt16LE(2, 32);
  wav.writeUInt16LE(16, 34);
  wav.write('data', 36);
  wav.writeUInt32LE(samples.length, 40);
  samples.copy(wav, 44);
  return wav;
}
