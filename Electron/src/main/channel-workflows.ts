import { BrowserWindow, net } from 'electron';
import {
  redditChannelFromAtom,
  redditCommunityFeedURL,
  xChannelItems,
  xProfileURL
} from '../shared/browser-workflow.js';
import type {
  DiscoveredSource,
  ExtractionService
} from './extraction.js';

export class ChannelWorkflowService {
  private readonly loginWindows = new Set<BrowserWindow>();

  constructor(
    private readonly extractor: Pick<ExtractionService, 'discoverSource'>
  ) {}

  async login(parent: BrowserWindow | null, value: string): Promise<void> {
    const url = httpURL(value);
    if (!url) throw new Error('Enter an HTTP(S) website to sign in to.');
    const window = new BrowserWindow({
      parent: parent ?? undefined,
      title: 'Sign in — Briefly',
      width: 1180,
      height: 820,
      minWidth: 800,
      minHeight: 560,
      webPreferences: {
        contextIsolation: true,
        nodeIntegration: false,
        sandbox: true
      }
    });
    this.loginWindows.add(window);
    window.on('closed', () => this.loginWindows.delete(window));
    window.webContents.setWindowOpenHandler(({ url: popupURL }) =>
      httpURL(popupURL)
        ? {
            action: 'allow',
            overrideBrowserWindowOptions: {
              webPreferences: {
                contextIsolation: true,
                nodeIntegration: false,
                sandbox: true
              }
            }
          }
        : { action: 'deny' }
    );
    await window.loadURL(url);
  }

  async enumerate(value: string, maximumItems = 5): Promise<DiscoveredSource> {
    maximumItems = Math.max(1, Math.min(maximumItems, 100));
    const profileURL = xProfileURL(value);
    if (profileURL) return this.enumerateXProfile(profileURL, maximumItems);
    const redditFeedURL = redditCommunityFeedURL(value, maximumItems);
    if (redditFeedURL) {
      const response = await net.fetch(redditFeedURL, {
        headers: { Accept: 'application/atom+xml' }
      });
      if (!response.ok) {
        throw new Error(`Reddit returned ${response.status} ${response.statusText}.`);
      }
      return redditChannelFromAtom(
        await response.text(),
        value,
        response.url || redditFeedURL,
        maximumItems
      );
    }
    return this.extractor.discoverSource(value, maximumItems);
  }

  private async enumerateXProfile(
    url: string,
    maximumItems: number
  ): Promise<DiscoveredSource> {
    const window = headlessWindow();
    try {
      await window.loadURL(url);
      const posts = await window.webContents.executeJavaScript(`
        new Promise(async (resolve) => {
          let previous = -1;
          let unchanged = 0;
          for (let attempt = 0; attempt < 12; attempt += 1) {
            const posts = [...document.querySelectorAll('article[data-testid="tweet"], [data-testid="tweet"]')]
              .filter(post => !/\\bPinned\\b/iu.test(post.querySelector('[data-testid="socialContext"]')?.textContent || ''));
            const urls = new Set(posts.map(post =>
              post.querySelector('time')?.closest('a')?.href ||
              [...post.querySelectorAll('a[href*="/status/"]')]
                .map(link => link.href)
                .find(href => /\\/status\\/\\d+/u.test(href))
            ).filter(Boolean));
            if (urls.size >= ${maximumItems} || unchanged >= 3) break;
            unchanged = urls.size === previous ? unchanged + 1 : 0;
            previous = urls.size;
            posts.at(-1)?.scrollIntoView({ block: 'end' });
            window.scrollBy(0, Math.max(400, window.innerHeight * 0.8));
            await new Promise(done => setTimeout(done, 700));
          }
          resolve([...document.querySelectorAll('article[data-testid="tweet"], [data-testid="tweet"]')]
            .flatMap(post => {
              const href = post.querySelector('time')?.closest('a')?.href ||
                [...post.querySelectorAll('a[href*="/status/"]')]
                  .map(link => link.href)
                  .find(value => /\\/status\\/\\d+/u.test(value));
              const match = href && /^(https:\\/\\/[^/]+\\/[^/]+\\/status\\/(\\d+))/u.exec(href);
              if (!match) return [];
              return [{
                id: match[2],
                url: match[1],
                text: (post.innerText || '').replace(/\\n{3,}/g, '\\n\\n').trim(),
                publishedAt: post.querySelector('time')?.dateTime || null,
                pinned: /\\bPinned\\b/iu.test(post.querySelector('[data-testid="socialContext"]')?.textContent || '')
              }];
            }));
        })
      `) as Array<{
        id: string;
        url: string;
        text: string;
        publishedAt: string | null;
        pinned: boolean;
      }>;
      const handle = new URL(url).pathname.slice(1);
      const items = xChannelItems(posts, handle, maximumItems);
      if (!items.length) {
        throw new Error(
          'X returned no posts. Use “Sign in to a channel”, sign in to X, then try again.'
        );
      }
      return {
        source: url,
        sourceURL: url,
        title: `@${handle} on X`,
        kind: 'page',
        items
      };
    } finally {
      window.destroy();
    }
  }
}

function headlessWindow(): BrowserWindow {
  return new BrowserWindow({
    show: false,
    webPreferences: {
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: true
    }
  });
}

function httpURL(value: string): string | null {
  try {
    const url = new URL(value.trim());
    return ['http:', 'https:'].includes(url.protocol) ? url.toString() : null;
  } catch {
    return null;
  }
}
