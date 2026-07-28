import { app, session } from 'electron';
import { existsSync, readFileSync } from 'node:fs';
import { mkdtemp, readFile, readdir, rm, stat } from 'node:fs/promises';
import { homedir, tmpdir } from 'node:os';
import { delimiter, dirname, join } from 'node:path';
import { spawn } from 'node:child_process';
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

  async extractClipboard(
    value: string,
    saveAudio = false
  ): Promise<ExtractedContent | undefined> {
    const sourceURL = webURL(value);
    if (!sourceURL) return undefined;

    return this.extractURL(sourceURL.toString(), saveAudio);
  }

  async extractURL(value: string, saveAudio = false): Promise<ExtractedContent> {
    const sourceURL = webURL(value);
    if (!sourceURL) throw new Error('Only HTTP(S) links can be extracted.');
    const saveYouTubeAudio = saveAudio && isYouTubeURL(sourceURL);
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

  async discoverSource(value: string): Promise<DiscoveredSource> {
    const helper = this.helperPath('watch.mjs');
    if (!helper) {
      throw new Error(
        'The source watcher is missing from Briefly. Reinstall the application.'
      );
    }
    const discovered = await runHelper<DiscoveredSource>(
      helper,
      [value],
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
