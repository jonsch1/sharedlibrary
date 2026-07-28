import { expect, test } from '@playwright/test';
import { _electron as electron } from 'playwright';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import type { SharedLibraryDesktopAPI } from '../src/shared/contracts.js';

const electronRoot = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const enabled = process.env.BRIEFLY_LIVE_PODCAST === '1';

test.skip(!enabled, 'Set BRIEFLY_LIVE_PODCAST=1 to generate real audio.');

test('generates and serves a real podcast WAV', async () => {
  test.setTimeout(30 * 60_000);
  const reuseAudio = process.env.BRIEFLY_REUSE_PODCAST_AUDIO === '1';
  const app = await electron.launch({
    args: [join(electronRoot, 'playwright.launch.mjs')],
    cwd: electronRoot,
    env: Object.fromEntries(
      Object.entries(process.env).filter(
        (entry): entry is [string, string] => typeof entry[1] === 'string'
      )
    )
  });
  try {
    const page = await app.firstWindow();
    const result = await page.evaluate(async (reuseAudio) => {
      const api = (
        window as unknown as Window & { sharedLibrary: SharedLibraryDesktopAPI }
      ).sharedLibrary;
      const before = await api.getPodcasts();
      const podcast =
        before.podcasts.find(({ id }) => id === 'file:ai-research-weekly-2.md') ??
        before.podcasts.find(({ title }) => title === 'AI Research Weekly');
      if (!podcast) throw new Error('AI Research Weekly is missing.');
      if (reuseAudio) {
        return {
          status: podcast.status,
          message: podcast.message,
          episode: podcast.episodes.find(({ hasAudio }) => hasAudio)
        };
      }
      const prior = new Set(podcast.episodes.map(({ id }) => id));
      const after = await api.runPodcast(podcast.id);
      const updated = after.podcasts.find(({ id }) => id === podcast.id);
      const episode = updated?.episodes.find(({ id }) => !prior.has(id));
      return {
        status: updated?.status,
        message: updated?.message,
        episode
      };
    }, reuseAudio);
    expect(reuseAudio ? ['idle', 'ready'] : ['ready'], result.message).toContain(
      result.status
    );
    expect(result.episode?.hasAudio).toBe(true);
    const playback = await page.evaluate(async (entryID) => {
      const url = `briefly-podcast-audio://episode/${encodeURIComponent(entryID!)}.wav`;
      const response = await fetch(url, { headers: { Range: 'bytes=0-11' } });
      const header = [...new Uint8Array(await response.arrayBuffer())];
      const audio = new Audio(url);
      audio.preload = 'metadata';
      const timing = await new Promise<{ duration: number; currentTime: number }>(
        (resolve, reject) => {
          audio.onerror = () => reject(new Error('Podcast audio could not be loaded.'));
          audio.onloadedmetadata = () => {
            const duration = audio.duration;
            audio.onseeked = () => resolve({ duration, currentTime: audio.currentTime });
            audio.currentTime = duration / 2;
          };
        }
      );
      return {
        header,
        status: response.status,
        contentRange: response.headers.get('content-range'),
        ...timing
      };
    }, result.episode?.id);
    expect(playback.status).toBe(206);
    expect(playback.contentRange).toMatch(/^bytes 0-11\/\d+$/);
    expect(Buffer.from(playback.header).toString('ascii', 0, 4)).toBe('RIFF');
    expect(Buffer.from(playback.header).toString('ascii', 8, 12)).toBe('WAVE');
    expect(playback.duration).toBeGreaterThan(0);
    expect(playback.currentTime).toBeCloseTo(playback.duration / 2, 1);
  } finally {
    await app.close();
  }
});
