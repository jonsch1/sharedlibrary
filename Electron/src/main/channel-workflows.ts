import { BrowserWindow } from 'electron';
import {
  cleanRepeatedItems,
  xChannelItems,
  xProfileURL
} from '../shared/browser-workflow.js';
import type {
  DiscoveredSource,
  DiscoveredSourceItem,
  ExtractedContent,
  ExtractionService
} from './extraction.js';

export class ChannelWorkflowService {
  private readonly loginWindows = new Set<BrowserWindow>();

  constructor(
    private readonly extractor: Pick<ExtractionService, 'discoverSource' | 'extractURL'>
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

  async enumerate(value: string): Promise<DiscoveredSource> {
    const profileURL = xProfileURL(value);
    return profileURL
      ? this.enumerateXProfile(profileURL)
      : this.extractor.discoverSource(value);
  }

  async capture(item: DiscoveredSourceItem): Promise<ExtractedContent> {
    const url = httpURL(item.url);
    if (!url) throw new Error('Podcast items must be HTTP(S) URLs.');
    const status = /^https:\/\/(?:www\.)?(?:x|twitter)\.com\/([^/]+)\/status\/(\d+)/iu.exec(
      url
    );
    if (status) {
      const window = headlessWindow();
      try {
        const content = await expandXPost(
          window,
          { id: status[2], url, text: '' },
          status[1],
          ''
        );
        if (content) {
          return {
            title: content.split('\n').find(Boolean)?.slice(0, 160),
            content,
            sourceURL: url
          };
        }
      } finally {
        window.destroy();
      }
    }
    return this.extractor.extractURL(url);
  }

  private async enumerateXProfile(url: string): Promise<DiscoveredSource> {
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
            if (urls.size >= 5 || unchanged >= 3) break;
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
      const items = xChannelItems(posts, handle);
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

async function expandXPost(
  window: BrowserWindow,
  post: { id: string; url: string; text: string },
  handle: string,
  fallback: string
): Promise<string> {
  try {
    await window.loadURL(post.url);
    const detail = await window.webContents.executeJavaScript(`
      new Promise(async (resolve) => {
        const deadline = Date.now() + 10000;
        let previous = -1;
        let unchanged = 0;
        let result = { texts: [], articles: [] };
        while (Date.now() < deadline) {
          const tweets = [...document.querySelectorAll('article[data-testid="tweet"], [data-testid="tweet"]')];
          const parsed = tweets.flatMap(tweet => {
            const href = tweet.querySelector('time')?.closest('a')?.href ||
              [...tweet.querySelectorAll('a[href*="/status/"]')]
                .map(link => link.href)
                .find(value => /\\/status\\/\\d+/u.test(value));
            const match = href && /^https:\\/\\/[^/]+\\/([^/]+)\\/status\\/(\\d+)/u.exec(href);
            return match ? [{
              author: match[1],
              id: match[2],
              text: (tweet.innerText || '').replace(/\\n{3,}/g, '\\n\\n').trim(),
              articles: [
                ...new Set([
                  ...[...tweet.querySelectorAll('a[href]')].map(link => link.href),
                  ...((tweet.innerText || '').match(/https:\\/\\/x\\.com\\/(?:i\\/)?article\\/\\d+/gu) || [])
                ].filter(value => /\\/article\\/\\d+/u.test(value)))
              ]
            }] : [];
          });
          const root = parsed.findIndex(item => item.id === ${JSON.stringify(post.id)});
          if (root >= 0) {
            const thread = [parsed[root]];
            for (const item of parsed.slice(root + 1)) {
              if (item.author.toLowerCase() !== ${JSON.stringify(handle.toLowerCase())}) break;
              thread.push(item);
            }
            result = {
              texts: thread.map(item => item.text),
              articles: [...new Set(thread.flatMap(item => item.articles))]
            };
            if (thread.length === previous) unchanged += 1;
            else unchanged = 0;
            previous = thread.length;
            if (unchanged >= 2) return resolve(result);
          }
          tweets.at(-1)?.scrollIntoView({ block: 'end' });
          window.scrollBy(0, Math.max(400, window.innerHeight * 0.8));
          await new Promise(done => setTimeout(done, 600));
        }
        resolve(result);
      })
    `) as { texts: string[]; articles: string[] };
    const thread = cleanRepeatedItems(detail.texts);
    const articles: string[] = [];
    for (const articleURL of detail.articles) {
      try {
        await window.loadURL(articleURL);
        const article = await window.webContents.executeJavaScript(`
          new Promise((resolve) => {
            const deadline = Date.now() + 10000;
            const check = () => {
              const element = document.querySelector('[data-testid="twitterArticleReadView"]');
              const text = element && (element.innerText || '').replace(/\\n{3,}/g, '\\n\\n').trim();
              if (text || Date.now() >= deadline) return resolve(text || '');
              setTimeout(check, 250);
            };
            check();
          })
        `) as string;
        if (article) articles.push(article);
      } catch {
        // Keep the post and article URL when X cannot render the article.
      }
    }
    return [
      ...(thread.length > 1
        ? thread.map((text, index) => `${index ? `Thread ${index + 1}` : 'Post'}\n${text}`)
        : [thread[0] || fallback]),
      ...articles.map((article) => `Article\n${article}`)
    ].filter(Boolean).join('\n\n');
  } catch {
    return fallback;
  }
}
