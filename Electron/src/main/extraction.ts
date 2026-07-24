import { app } from 'electron';
import { existsSync, readFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { delimiter, dirname, join } from 'node:path';
import { spawn } from 'node:child_process';

export interface ExtractedContent {
  title?: string;
  content: string;
  sourceURL: string;
}

interface ExtractorOutput {
  url?: string;
  title?: string;
  content?: string;
}

const extractionTimeoutMilliseconds = 150_000;

export class ExtractionService {
  async extractClipboard(value: string): Promise<ExtractedContent | undefined> {
    const sourceURL = webURL(value);
    if (!sourceURL) return undefined;

    const helper = this.helperPath();
    if (!helper) {
      throw new Error(
        'The web extractor is missing from Briefly. Reinstall the application.'
      );
    }

    const extracted = await runHelper(helper, sourceURL.toString());
    const content = extracted.content?.trim();
    if (!content) throw new Error('The page did not contain extractable text.');

    return {
      title: extracted.title?.trim() || undefined,
      content,
      sourceURL: webURL(extracted.url ?? '')?.toString() ?? sourceURL.toString()
    };
  }

  private helperPath(): string | null {
    const candidates = [
      join(process.resourcesPath, 'Tools', 'extractor', 'extract.mjs'),
      join(app.getAppPath(), '..', 'Tools', 'extractor', 'extract.mjs'),
      join(process.cwd(), 'Tools', 'extractor', 'extract.mjs')
    ];
    return candidates.find((path) => existsSync(path)) ?? null;
  }
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

async function runHelper(helper: string, url: string): Promise<ExtractorOutput> {
  return new Promise((resolve, reject) => {
    const child = spawn(process.execPath, [helper, url], {
      cwd: dirname(helper),
      env: extractorEnvironment(helper),
      stdio: ['ignore', 'pipe', 'pipe']
    });
    let output = '';
    let error = '';
    let outputTooLarge = false;
    const timeout = setTimeout(() => {
      child.kill();
      reject(new Error('Extraction timed out after 150 seconds.'));
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
        reject(new Error(lastExtractorError(error) || 'Web extraction failed.'));
        return;
      }
      try {
        resolve(JSON.parse(output) as ExtractorOutput);
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
