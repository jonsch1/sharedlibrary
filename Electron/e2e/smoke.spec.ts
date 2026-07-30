import { expect, test } from '@playwright/test';
import { _electron as electron, type ElectronApplication, type Page } from 'playwright';
import { mkdtemp, mkdir, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import type { SharedLibraryDesktopAPI } from '../src/shared/contracts.js';

const electronRoot = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const launchScript = join(electronRoot, 'playwright.launch.mjs');
type ElectronWindow = Window & typeof globalThis & {
  sharedLibrary: SharedLibraryDesktopAPI;
};

test('the production app reads, edits, plays, and configures a library', async ({}, testInfo) => {
  const temporaryRoot = await mkdtemp(join(tmpdir(), 'briefly-e2e-'));
  const userDataPath = join(temporaryRoot, 'user-data');
  const workspacePath = join(temporaryRoot, 'workspace');
  let app: ElectronApplication | undefined;
  let page: Page | undefined;
  try {
    await createFixture(userDataPath, workspacePath);
    app = await electron.launch({
      args: [launchScript],
      cwd: electronRoot,
      env: { ...process.env, BRIEFLY_E2E_USER_DATA: userDataPath }
    });
    page = await app.firstWindow();
    const rendererErrors: string[] = [];
    page.on('pageerror', (error) => rendererErrors.push(error.message));
    page.on('console', (message) => {
      if (message.type() === 'error') rendererErrors.push(message.text());
    });

    await expect(page).toHaveTitle('Briefly');
    await expect(page.getByRole('button', { name: 'Electron smoke fixture' })).toBeVisible();
    await expect(page.getByRole('button', { name: 'Second smoke fixture' })).toHaveCount(0);
    await expect(page.locator('.native-document-body')).toContainText('Brief smoke summary.');

    const snapshot = await page.evaluate(() =>
      (window as ElectronWindow).sharedLibrary.getSnapshot()
    );
    expect(snapshot.workspacePath).toBe(workspacePath);
    expect(snapshot.entries).toHaveLength(2);
    const entryID = snapshot.entries[0].id;
    expect(
      await page.evaluate(
        (id) => (window as ElectronWindow).sharedLibrary.readText(id, 'source'),
        entryID
      )
    ).toBe('Original smoke body.');

    await page.evaluate(
      ({ id, text }) => (window as ElectronWindow).sharedLibrary.writeText(id, 'source', text),
      { id: entryID, text: 'Edited through the Electron preload bridge.' }
    );
    await page.getByRole('radio', { name: 'Original' }).click();
    await expect(page.locator('.native-document-body')).toContainText(
      'Edited through the Electron preload bridge.'
    );

    const audio = page.locator('audio');
    await expect(audio).toHaveCount(1);
    await page.getByRole('button', { name: 'Expand audio player' }).click();
    await expect(page.locator('.native-reader-audio')).toBeVisible();
    await audio.evaluate((element: HTMLAudioElement) => element.play());
    await expect.poll(() => audio.evaluate((element: HTMLAudioElement) => element.currentTime))
      .toBeGreaterThan(0);
    await audio.evaluate((element: HTMLAudioElement) => element.pause());

    const audioPanel = page.locator('.native-reader-audio');
    const dragHandle = page.getByRole('button', {
      name: 'Move audio controls with drag or arrow keys'
    });
    const handleBounds = await dragHandle.boundingBox();
    expect(handleBounds).not.toBeNull();
    await page.mouse.move(
      handleBounds!.x + handleBounds!.width / 2,
      handleBounds!.y + handleBounds!.height / 2
    );
    await page.mouse.down();
    await page.mouse.move(handleBounds!.x - 80, handleBounds!.y - 60);
    await page.mouse.up();
    const savedAudioPosition = await page.evaluate(() =>
      window.localStorage.getItem('briefly:reader-audio-position')
    );
    expect(savedAudioPosition).toBeTruthy();
    const movedPosition = await audioPanel.evaluate((element) => ({
      left: element.style.left,
      top: element.style.top
    }));
    await page.reload();
    await expect(page.getByRole('button', { name: 'Electron smoke fixture' })).toBeVisible();
    await page.getByRole('button', { name: 'Expand audio player' }).click();
    await expect(page.locator('.native-reader-audio')).toBeVisible();
    await expect.poll(() =>
      page!.locator('.native-reader-audio').evaluate((element) => ({
        left: element.style.left,
        top: element.style.top
      }))
    ).toEqual(movedPosition);

    const tabs = page.getByRole('tablist', { name: 'Library view' });
    await tabs.getByRole('tab', { name: 'Voice brief' }).click();
    await expect(page.getByLabel('Voice brief title')).toHaveValue('Smoke voice brief');
    await page.getByLabel('Voice brief instructions').fill('Explain why each update matters.');
    await expect.poll(() =>
      page!.evaluate(async () =>
        (await (window as ElectronWindow).sharedLibrary.getVoiceBriefs()).voiceBriefs[0]?.prompt
      )
    ).toBe('Explain why each update matters.');

    await page.locator('.native-sidebar-footer').getByRole('button', { name: 'Settings' }).click();
    await page.getByRole('button', { name: 'General' }).click();
    const saveAudio = page.getByRole('checkbox', {
      name: 'Save audio from manually captured YouTube videos'
    });
    await saveAudio.uncheck();
    await expect.poll(() =>
      page!.evaluate(() => (window as ElectronWindow).sharedLibrary.getAudioPreferences())
    ).toEqual({ saveCapturedAudio: false });
    expect(rendererErrors).toEqual([]);
  } catch (error) {
    await page?.screenshot({ path: testInfo.outputPath('failure.png'), fullPage: true }).catch(() => {});
    throw error;
  } finally {
    await app?.close().catch(() => {});
    await rm(temporaryRoot, { recursive: true, force: true });
  }
});

async function createFixture(userDataPath: string, workspacePath: string): Promise<void> {
  await Promise.all([
    mkdir(join(workspacePath, 'library', 'summaries', 'brief'), { recursive: true }),
    mkdir(join(workspacePath, 'library', 'audio'), { recursive: true }),
    mkdir(join(workspacePath, '.shared-library'), { recursive: true }),
    mkdir(join(workspacePath, 'voice-briefs'), { recursive: true }),
    mkdir(userDataPath, { recursive: true })
  ]);
  await Promise.all([
    writeFile(
      join(userDataPath, 'settings.json'),
      `${JSON.stringify({ workspacePath }, null, 2)}\n`
    ),
    writeFile(
      join(workspacePath, 'topics.md'),
      'topics:\n  - id: "testing"\n    title: "Testing"\n'
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
`
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
`
    ),
    writeFile(join(workspacePath, 'library', 'audio', 'electron-smoke.wav'), toneWav()),
    writeFile(
      join(workspacePath, 'library', 'summaries', 'brief', 'fixture.md'),
      'Brief smoke summary.\n'
    ),
    writeFile(
      join(workspacePath, '.shared-library', 'voice-brief-state.json'),
      `${JSON.stringify({
        schemaVersion: 1,
        sources: {
          'https://example.invalid/feed.xml': {
            title: 'Smoke channel',
            seen: ['second'],
            items: [{
              id: 'second',
              title: 'Second smoke fixture',
              url: 'https://example.invalid/second',
              publishedAt: null,
              entryID: 'personal:electron-smoke-second',
              ingestedAt: '2026-07-23T08:00:00.000Z'
            }]
          }
        },
        voiceBriefs: {}
      }, null, 2)}\n`
    ),
    writeFile(
      join(workspacePath, 'voice-briefs', 'smoke-voice-brief.md'),
      `---
name: "Smoke voice brief"
schedule: "weekly MON 08:00"
sources:
  - "https://example.invalid/feed.xml"
length: "15 minutes"
---

Keep the episode practical.
`
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
