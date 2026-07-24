import { app } from 'electron';
import { existsSync } from 'node:fs';
import { join } from 'node:path';
import { spawn } from 'node:child_process';

export interface ExtractedContent {
  title?: string;
  content: string;
  sourceURL: string;
}

export class ExtractionService {
  async extractClipboard(value: string): Promise<ExtractedContent | undefined> {
    const sourceURL = webURL(value);
    if (!sourceURL) return undefined;
    const helper = this.helperPath();
    if (helper) {
      try {
        const extracted = await runHelper(helper, sourceURL.toString());
        if (extracted.content?.trim()) {
          return {
            title: extracted.title?.trim(),
            content: extracted.content.trim(),
            sourceURL: sourceURL.toString()
          };
        }
      } catch {
        // A lightweight HTML fallback keeps capture useful when an optional
        // extractor dependency or a site-specific parser is unavailable.
      }
    }
    return fallbackExtraction(sourceURL);
  }

  private helperPath(): string | null {
    const candidates = [
      join(process.resourcesPath, 'Tools', 'extractor', 'extract.mjs'),
      join(app.getAppPath(), '..', 'Tools', 'extractor', 'extract.mjs'),
      '/Users/jschaul/Code/sharedlibrary/Tools/extractor/extract.mjs'
    ];
    return candidates.find((path) => existsSync(path)) ?? null;
  }
}

function webURL(value: string): URL | null {
  if (/\s/.test(value.trim())) return null;
  try {
    const url = new URL(value.trim());
    return url.protocol === 'http:' || url.protocol === 'https:' ? url : null;
  } catch {
    return null;
  }
}

async function runHelper(
  helper: string,
  url: string
): Promise<{ title?: string; content?: string }> {
  return new Promise((resolve, reject) => {
    const child = spawn(process.execPath, [helper, url], {
      env: {
        ...process.env,
        ELECTRON_RUN_AS_NODE: '1'
      },
      stdio: ['ignore', 'pipe', 'pipe']
    });
    let output = '';
    let error = '';
    const timeout = setTimeout(() => {
      child.kill();
      reject(new Error('Web extraction timed out.'));
    }, 125_000);
    child.stdout.on('data', (chunk) => {
      output += String(chunk);
      if (output.length > 40_000_000) child.kill();
    });
    child.stderr.on('data', (chunk) => {
      error += String(chunk);
    });
    child.on('error', reject);
    child.on('close', (code) => {
      clearTimeout(timeout);
      if (code !== 0) {
        reject(new Error(error.trim() || 'Web extraction failed.'));
        return;
      }
      try {
        resolve(JSON.parse(output) as { title?: string; content?: string });
      } catch {
        reject(new Error('The web extractor returned invalid content.'));
      }
    });
  });
}

async function fallbackExtraction(url: URL): Promise<ExtractedContent> {
  const response = await fetch(url, {
    headers: {
      Accept: 'text/html, text/plain;q=0.9',
      'User-Agent': 'SharedLibrary/1.0'
    },
    signal: AbortSignal.timeout(30_000)
  });
  if (!response.ok) throw new Error(`The page could not be downloaded (${response.status}).`);
  const raw = await response.text();
  const contentType = response.headers.get('Content-Type') ?? '';
  if (!contentType.includes('html')) {
    return { content: raw.trim(), sourceURL: url.toString() };
  }
  const title = decodeHTML(
    /<title[^>]*>([\s\S]*?)<\/title>/i.exec(raw)?.[1]?.replace(/\s+/g, ' ').trim() ?? ''
  );
  const content = decodeHTML(
    raw
      .replace(/<script[\s\S]*?<\/script>/gi, ' ')
      .replace(/<style[\s\S]*?<\/style>/gi, ' ')
      .replace(/<noscript[\s\S]*?<\/noscript>/gi, ' ')
      .replace(/<[^>]+>/g, ' ')
      .replace(/\s+/g, ' ')
      .trim()
  );
  if (!content) throw new Error('The page did not contain extractable text.');
  return { title: title || undefined, content, sourceURL: url.toString() };
}

function decodeHTML(value: string): string {
  return value
    .replaceAll('&nbsp;', ' ')
    .replaceAll('&amp;', '&')
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&quot;', '"')
    .replaceAll('&#39;', "'");
}
