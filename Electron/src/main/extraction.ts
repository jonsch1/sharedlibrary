import { app, BrowserWindow, session } from 'electron';
import { existsSync, readFileSync } from 'node:fs';
import { mkdtemp, readFile, readdir, rm, stat } from 'node:fs/promises';
import { homedir, tmpdir } from 'node:os';
import { delimiter, dirname, join } from 'node:path';
import { spawn } from 'node:child_process';
import { cleanRepeatedItems } from '../shared/browser-workflow.js';
import { faviconExtension } from './favicon.js';

export interface ExtractedContent {
  title?: string;
  content: string;
  sourceURL: string;
  mediaURL?: string;
  audio?: {
    bytes: Uint8Array;
    extension: 'aac' | 'flac' | 'm4a' | 'mp3' | 'ogg' | 'opus' | 'wav' | 'webm';
  };
  favicon?: {
    bytes: Uint8Array;
    extension: 'gif' | 'ico' | 'jpg' | 'png' | 'webp';
  };
}

export interface DiscoveredSourceItem {
  id: string;
  title: string;
  url: string;
  publishedAt: string | null;
  content?: string;
  linkedURL?: string;
}

export interface DiscoveredSource {
  source: string;
  sourceURL: string;
  feedURL?: string;
  title: string;
  kind: 'feed' | 'podcast' | 'page';
  items: DiscoveredSourceItem[];
}

interface ExtractorOutput {
  url?: string;
  title?: string;
  content?: string;
  mediaURL?: string;
  faviconURL?: string;
  transcriptError?: string | null;
}

const extractionTimeoutMilliseconds = 1_850_000;

export class ExtractionService {
  constructor(
    private readonly workspacePath: () => string,
    private readonly transcriptCredentials: () => Promise<
      { endpoint: string; token: string } | undefined
    > = async () => undefined,
    private readonly firecrawlCredentials: () => Promise<
      { endpoint: string; token: string } | undefined
    > = async () => undefined
  ) {}

  async extractURL(
    value: string,
    saveAudio = false,
    discovered?: DiscoveredSourceItem
  ): Promise<ExtractedContent> {
    const sourceURL = webURL(value);
    if (!sourceURL) throw new Error('Only HTTP(S) links can be extracted.');
    const saveYouTubeAudio = saveAudio && isYouTubeURL(sourceURL);
    try {
      const social = await extractSocialPost(sourceURL, discovered);
      if (social) {
        return {
          ...social,
          favicon: await downloadFavicon(social.sourceURL)
        };
      }
    } catch {
      // Public extractors remain available when a signed-in page cannot render.
    }
    const helper = this.helperPath('extract.mjs');
    if (!helper) {
      throw new Error(
        'The web extractor is missing from Briefly. Reinstall the application.'
      );
    }

    const [credentials, firecrawl] = await Promise.all([
      this.transcriptCredentials(),
      this.firecrawlCredentials()
    ]);
    const mediaDirectory = credentials || saveYouTubeAudio
      ? await mkdtemp(join(tmpdir(), 'briefly-media-'))
      : undefined;
    try {
      const extracted = await runHelper<ExtractorOutput>(
        helper,
        ['--extensions', join(this.workspacePath(), '.briefly', 'inputs'), sourceURL.toString()],
        'Web extraction failed.',
        {
          ...(mediaDirectory
            ? {
                BRIEFLY_MEDIA_OUTPUT_DIRECTORY: mediaDirectory,
                BRIEFLY_SAVE_CAPTURED_AUDIO: saveYouTubeAudio ? '1' : '0'
              }
            : {}),
          ...(credentials
            ? {
                BRIEFLY_TRANSCRIPT_ENDPOINT: credentials.endpoint,
                BRIEFLY_TRANSCRIPT_TOKEN: credentials.token
              }
            : {}),
          ...(firecrawl
            ? {
                BRIEFLY_FIRECRAWL_ENDPOINT: firecrawl.endpoint,
                BRIEFLY_FIRECRAWL_TOKEN: firecrawl.token
              }
            : {})
        }
      );
      const content = extracted.content?.trim();
      if (extracted.transcriptError) {
        console.warn(`Transcript fallback failed: ${extracted.transcriptError}`);
      }
      if (!content) throw new Error('The page did not contain extractable text.');

      const resolvedSourceURL =
        webURL(extracted.url ?? '')?.toString() ?? sourceURL.toString();
      return {
        title: extracted.title?.trim() || undefined,
        content,
        sourceURL: resolvedSourceURL,
        mediaURL: webURL(extracted.mediaURL ?? '')?.toString() ?? undefined,
        audio:
          saveYouTubeAudio && mediaDirectory
            ? await downloadedAudio(mediaDirectory)
            : undefined,
        favicon: await downloadFavicon(resolvedSourceURL, extracted.faviconURL)
      };
    } finally {
      if (mediaDirectory) {
        await rm(mediaDirectory, { force: true, recursive: true });
      }
    }
  }

  async extractPDFFile(value: unknown): Promise<ExtractedContent> {
    if (typeof value !== 'string' || !value.trim()) {
      throw new Error('The dropped PDF does not have a readable file path.');
    }
    const helper = this.helperPath('extract.mjs');
    if (!helper) {
      throw new Error(
        'The PDF extractor is missing from Briefly. Reinstall the application.'
      );
    }
    const extracted = await runHelper<ExtractorOutput>(
      helper,
      ['--file', value],
      'PDF extraction failed.'
    );
    const content = extracted.content?.trim();
    if (!content) throw new Error('The PDF did not contain extractable text.');
    return {
      title: extracted.title?.trim() || undefined,
      content,
      sourceURL: ''
    };
  }

  async discoverSource(value: string, maximumItems?: number): Promise<DiscoveredSource> {
    const helper = this.helperPath('watch.mjs');
    if (!helper) {
      throw new Error(
        'The source watcher is missing from Briefly. Reinstall the application.'
      );
    }
    const discovered = await runHelper<DiscoveredSource>(
      helper,
      maximumItems ? [value, '--limit', String(maximumItems)] : [value],
      'The source could not be checked.'
    );
    if (
      !discovered ||
      typeof discovered !== 'object' ||
      !Array.isArray(discovered.items)
    ) {
      throw new Error('The source watcher returned invalid content.');
    }
    return discovered;
  }

  private helperPath(filename: string): string | null {
    const candidates = [
      join(process.resourcesPath, 'Tools', 'extractor', filename),
      join(app.getAppPath(), '..', 'Tools', 'extractor', filename),
      join(process.cwd(), 'Tools', 'extractor', filename)
    ];
    return candidates.find((path) => existsSync(path)) ?? null;
  }
}

async function downloadedAudio(
  directory: string
): Promise<
  | {
      bytes: Uint8Array;
      extension: 'aac' | 'flac' | 'm4a' | 'mp3' | 'ogg' | 'opus' | 'wav' | 'webm';
    }
  | undefined
> {
  const filename = (await readdir(directory)).find((candidate) =>
    /\.(?:aac|flac|m4a|mp3|ogg|opus|wav|webm)$/iu.test(candidate)
  );
  if (!filename) return undefined;
  const path = join(directory, filename);
  if ((await stat(path)).size > 500_000_000) {
    throw new Error('The downloaded audio is too large to save.');
  }
  return {
    bytes: new Uint8Array(await readFile(path)),
    extension: filename.split('.').at(-1)?.toLowerCase() as
      | 'aac'
      | 'flac'
      | 'm4a'
      | 'mp3'
      | 'ogg'
      | 'opus'
      | 'wav'
      | 'webm'
  };
}

async function downloadFavicon(
  sourceURL: string,
  preferredURL?: string
): Promise<
  | {
      bytes: Uint8Array;
      extension: 'gif' | 'ico' | 'jpg' | 'png' | 'webp';
    }
  | undefined
> {
  const fallbackURL = new URL('/favicon.ico', sourceURL).toString();
  for (const url of [...new Set([webURL(preferredURL ?? '')?.toString(), fallbackURL])]) {
    if (!url) continue;
    try {
      const response = await session.defaultSession.fetch(url, {
        headers: { Accept: 'image/*' },
        signal: AbortSignal.timeout(5_000)
      });
      const declaredLength = Number(response.headers.get('content-length') ?? 0);
      if (!response.ok || declaredLength > 1_000_000) continue;
      const bytes = new Uint8Array(await response.arrayBuffer());
      if (!bytes.length || bytes.length > 1_000_000) continue;
      const extension = faviconExtension(bytes);
      if (extension) return { bytes, extension };
    } catch {
      // Missing favicons should not prevent capture.
    }
  }
  return undefined;
}

function webURL(value: string): URL | null {
  const trimmed = value.trim();
  if (!trimmed || /\s/.test(trimmed)) return null;
  try {
    const url = new URL(trimmed);
    return url.protocol === 'http:' || url.protocol === 'https:' ? url : null;
  } catch {
    return null;
  }
}

function isYouTubeURL(url: URL): boolean {
  const hostname = url.hostname.toLowerCase();
  return (
    hostname === 'youtu.be' ||
    hostname === 'youtube.com' ||
    hostname.endsWith('.youtube.com') ||
    hostname === 'youtube-nocookie.com' ||
    hostname.endsWith('.youtube-nocookie.com')
  );
}

async function extractSocialPost(
  sourceURL: URL,
  discovered?: DiscoveredSourceItem
): Promise<ExtractedContent | null> {
  const url = sourceURL.toString();
  const item = discovered ?? {
    id: url,
    title: url,
    url,
    publishedAt: null
  };
  if (redditPostID(sourceURL)) {
    const window = headlessWindow();
    try {
      const expanded = await expandRedditPost(window, item, url);
      return {
        title: discovered?.title || expanded.title,
        content: expanded.content,
        sourceURL: url
      };
    } finally {
      window.destroy();
    }
  }
  const status = /^https:\/\/(?:www\.)?(?:x|twitter)\.com\/([^/]+)\/status\/(\d+)/iu.exec(
    url
  );
  if (!status) return null;
  const window = headlessWindow();
  try {
    const content = await expandXPost(
      window,
      { id: status[2], url, text: '' },
      status[1],
      discovered?.content?.trim() ?? ''
    );
    return content
      ? {
          title:
            discovered?.title ||
            content.split('\n').find(Boolean)?.slice(0, 160),
          content,
          sourceURL: url
        }
      : null;
  } finally {
    window.destroy();
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

function redditPostID(url: URL): string | null {
  return isRedditHost(url.hostname)
    ? /\/comments\/([a-z0-9]+)(?:\/|$)/iu.exec(url.pathname)?.[1] ?? null
    : null;
}

function isRedditHost(value: string): boolean {
  return ['reddit.com', 'www.reddit.com', 'old.reddit.com'].includes(
    value.toLowerCase()
  );
}

async function expandRedditPost(
  window: BrowserWindow,
  item: DiscoveredSourceItem,
  discussionURL: string
): Promise<{ title?: string; content: string }> {
  let discussion = {
    title: '',
    post: '',
    comments: [] as string[],
    linkedURL: ''
  };
  const oldRedditURL = new URL(discussionURL);
  oldRedditURL.hostname = 'old.reddit.com';
  await window.loadURL(oldRedditURL.toString());
  discussion = await window.webContents.executeJavaScript(`
    (() => {
      const title =
        document.querySelector('.thing.link a.title')?.textContent?.trim() || '';
      const post =
        document.querySelector('.thing.link .usertext-body .md')?.innerText?.trim() || '';
      const linkedURL =
        document.querySelector('.thing.link a.title')?.href || '';
      const comments = [...document.querySelectorAll('.commentarea .thing.comment')]
        .slice(0, 10)
        .flatMap(comment => {
          const entry = comment.querySelector(':scope > .entry');
          const author = entry?.querySelector('.author')?.textContent?.trim() || '';
          const body = entry?.querySelector('.usertext-body .md')?.innerText?.trim() || '';
          return author && body ? ['u/' + author + '\\n' + body] : [];
        });
      return { title, post, comments, linkedURL };
    })()
  `) as {
    title: string;
    post: string;
    comments: string[];
    linkedURL: string;
  };
  const linkedURL = [item.linkedURL, discussion.linkedURL]
    .map((candidate) => webURL(candidate ?? ''))
    .find((candidate) => candidate && !isRedditHost(candidate.hostname))
    ?.toString();
  const article = linkedURL
    ? await readArticle(window, linkedURL).catch(() => '')
    : '';
  const comments = cleanRepeatedItems(discussion.comments);
  if (!(article || discussion.post || comments.length)) {
    throw new Error('Reddit did not expose readable post content.');
  }
  return {
    title: discussion.title || undefined,
    content: [
      item.content?.trim(),
      article ? `## Article\n\n${article}` : '',
      discussion.post ? `## Post\n\n${discussion.post}` : '',
      comments.length
        ? `## Discussion\n\n${comments
            .map((comment, index) => `### Comment ${index + 1}\n\n${comment}`)
            .join('\n\n')}`
        : ''
    ].filter(Boolean).join('\n\n')
  };
}

async function readArticle(window: BrowserWindow, url: string): Promise<string> {
  await window.loadURL(url);
  const rejectedConsent = await window.webContents.executeJavaScript(`
    (() => {
      const controls = [...document.querySelectorAll('button, input[type="submit"]')];
      const reject = controls.find(control =>
        /^(reject all|decline all|alles weigeren|alle ablehnen|tout refuser|rifiuta tutto|rechazar todo)$/iu.test(
          (control.innerText || control.value || '').trim()
        )
      );
      reject?.click();
      return Boolean(reject);
    })()
  `) as boolean;
  if (rejectedConsent) {
    await new Promise((resolve) => setTimeout(resolve, 2_500));
  }
  return window.webContents.executeJavaScript(`
    new Promise(async resolve => {
      for (let attempt = 0; attempt < 3; attempt += 1) {
        window.scrollBy(0, Math.max(500, window.innerHeight * 0.8));
        await new Promise(done => setTimeout(done, 500));
      }
      const articles = [...document.querySelectorAll('article')]
        .filter(element => (element.innerText || '').trim().length > 200);
      const candidates = articles.length ? articles :
        [...document.querySelectorAll('main, [role="main"]')]
          .filter(element => (element.innerText || '').trim().length > 200);
      const root = candidates.sort(
        (left, right) => (right.innerText || '').length - (left.innerText || '').length
      )[0] || document.body;
      const clone = root?.cloneNode(true);
      clone?.querySelectorAll(
        'script, style, noscript, nav, footer, aside, form, button, dialog, [aria-hidden="true"]'
      ).forEach(element => element.remove());
      const lines = (clone?.innerText || '').split(/\\n+/u)
        .map(line => line.trim())
        .filter(Boolean)
        .filter((line, index, values) => line !== values[index - 1]);
      resolve(lines.join('\\n\\n').slice(0, 60000));
    })
  `) as Promise<string>;
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

async function runHelper<T>(
  helper: string,
  arguments_: string[],
  fallbackError: string,
  environmentOverrides?: NodeJS.ProcessEnv
): Promise<T> {
  return new Promise((resolve, reject) => {
    const child = spawn(
      process.execPath,
      [helper, ...arguments_],
      {
        cwd: dirname(helper),
        env: { ...extractorEnvironment(helper), ...environmentOverrides },
        stdio: ['ignore', 'pipe', 'pipe']
      }
    );
    let output = '';
    let error = '';
    let outputTooLarge = false;
    const timeout = setTimeout(() => {
      child.kill();
      reject(new Error('Extraction timed out after 31 minutes.'));
    }, extractionTimeoutMilliseconds);

    child.stdout.on('data', (chunk) => {
      output += String(chunk);
      if (output.length <= 40_000_000) return;
      outputTooLarge = true;
      child.kill();
    });
    child.stderr.on('data', (chunk) => {
      error += String(chunk);
      if (error.length > 1_000_000) error = error.slice(-1_000_000);
    });
    child.on('error', reject);
    child.on('close', (code) => {
      clearTimeout(timeout);
      if (outputTooLarge) {
        reject(new Error('The extracted page was too large to import.'));
        return;
      }
      if (code !== 0) {
        reject(new Error(lastExtractorError(error) || fallbackError));
        return;
      }
      try {
        resolve(JSON.parse(output) as T);
      } catch {
        reject(new Error('The web extractor returned invalid content.'));
      }
    });
  });
}

function extractorEnvironment(helper: string): NodeJS.ProcessEnv {
  const environment: NodeJS.ProcessEnv = { ...process.env };
  const candidates = [
    join(process.cwd(), '.env'),
    join(dirname(helper), '.env'),
    join(app.getAppPath(), '..', '.env'),
    join(app.getPath('userData'), '.env')
  ];
  for (const candidate of [...new Set(candidates)]) {
    mergeEnvironmentFile(candidate, environment);
  }
  delete environment.FIRECRAWL_API_KEY;
  environment.ELECTRON_RUN_AS_NODE = '1';
  environment.PATH = mergedExecutablePath(environment.PATH ?? environment.Path);
  return environment;
}

function mergeEnvironmentFile(path: string, environment: NodeJS.ProcessEnv): void {
  let contents = '';
  try {
    contents = readFileSync(path, 'utf8');
  } catch {
    return;
  }

  for (const rawLine of contents.split(/\r?\n/)) {
    const line = rawLine.trim().replace(/^export\s+/, '');
    if (!line || line.startsWith('#')) continue;
    const separator = line.indexOf('=');
    if (separator <= 0) continue;
    const key = line.slice(0, separator).trim();
    if (!/^[A-Za-z_][A-Za-z0-9_]*$/.test(key) || environment[key]) continue;
    environment[key] = line
      .slice(separator + 1)
      .trim()
      .replace(/^(["'])([\s\S]*)\1$/, '$2');
  }
}

function mergedExecutablePath(existingPath: string | undefined): string {
  const defaults =
    process.platform === 'win32'
      ? []
      : [
          '/opt/homebrew/bin',
          '/usr/local/bin',
          '/usr/bin',
          '/bin',
          '/opt/local/bin',
          join(homedir(), '.local', 'bin')
        ];
  const entries = [
    ...(existingPath?.split(delimiter) ?? []),
    dirname(process.execPath),
    ...defaults
  ].filter(Boolean);
  return [...new Set(entries)].join(delimiter);
}

function lastExtractorError(value: string): string {
  return (
    value
      .trim()
      .split(/\r?\n/)
      .filter(Boolean)
      .at(-1) ?? ''
  );
}
