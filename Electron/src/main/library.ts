import { randomUUID } from 'node:crypto';
import {
  mkdir,
  readFile,
  readdir,
  rename,
  stat,
  writeFile
} from 'node:fs/promises';
import { basename, dirname, join } from 'node:path';
import {
  libraryVariants,
  type DesktopPlatform,
  type DesktopLibraryEntry,
  type DesktopLibrarySnapshot,
  type LibraryVariant
} from '../shared/contracts.js';

interface ParsedMarkdown {
  metadata: Record<string, string | string[]>;
  frontmatter: string | null;
  body: string;
}

interface IndexedEntry {
  entry: DesktopLibraryEntry;
  sourcePath: string;
  variantPaths: Partial<Record<LibraryVariant, string>>;
}

type TrashHandler = (path: string) => Promise<void>;

const summaryVariants = ['brief', 'concise', 'detailed', 'comprehensive'] as const;

export class LibraryService {
  private indexedEntries = new Map<string, IndexedEntry>();

  constructor(
    private workspacePath: string,
    private readonly platform: DesktopPlatform,
    private readonly trash: TrashHandler
  ) {}

  setWorkspacePath(path: string): void {
    this.workspacePath = path;
    this.indexedEntries.clear();
  }

  getWorkspacePath(): string {
    return this.workspacePath;
  }

  async ensureWorkspace(): Promise<void> {
    await mkdir(join(this.workspacePath, 'library'), { recursive: true });
    for (const variant of summaryVariants) {
      await mkdir(join(this.workspacePath, 'library', 'summaries', variant), {
        recursive: true
      });
    }
  }

  async snapshot(): Promise<DesktopLibrarySnapshot> {
    await this.ensureWorkspace();
    const topicNames = await this.readTopicNames();
    const libraryPath = join(this.workspacePath, 'library');
    const directoryEntries = await readdir(libraryPath, { withFileTypes: true });
    const files = directoryEntries
      .filter((item) => item.isFile() && item.name.toLowerCase().endsWith('.md'))
      .map((item) => item.name)
      .sort((left, right) => left.localeCompare(right));

    const indexed = await Promise.all(
      files.map((filename) => this.indexSource(filename, topicNames))
    );
    indexed.sort((left, right) => {
      const leftDate = left.entry.createdAt ?? left.entry.updatedAt ?? '';
      const rightDate = right.entry.createdAt ?? right.entry.updatedAt ?? '';
      return rightDate.localeCompare(leftDate) || left.entry.title.localeCompare(right.entry.title);
    });
    this.indexedEntries = new Map(indexed.map((item) => [item.entry.id, item]));

    const topics = Array.from(
      new Set(indexed.flatMap((item) => item.entry.topicNames))
    ).sort((left, right) => left.localeCompare(right));
    return {
      workspacePath: this.workspacePath,
      platform: this.platform,
      generatedAt: new Date().toISOString(),
      topics,
      entries: indexed.map((item) => item.entry)
    };
  }

  async readText(entryID: string, variant: LibraryVariant): Promise<string> {
    const indexed = await this.requireEntry(entryID);
    const path = indexed.variantPaths[variant];
    if (!path) throw new Error('That document version is not available.');
    const text = await readFile(path, 'utf8');
    return variant === 'source' ? parseMarkdown(text).body.trim() : text.trim();
  }

  async writeText(entryID: string, variant: LibraryVariant, text: string): Promise<void> {
    const indexed = await this.requireEntry(entryID);
    const path = indexed.variantPaths[variant];
    if (!path) throw new Error('That document version is not available.');
    let serialized = text;
    if (variant === 'source') {
      const original = parseMarkdown(await readFile(path, 'utf8'));
      serialized = original.frontmatter
        ? `${original.frontmatter}\n\n${text.trim()}\n`
        : `${text.trim()}\n`;
    }
    await atomicWrite(path, serialized);
  }

  async trashCapture(entryID: string): Promise<void> {
    const indexed = await this.requireEntry(entryID);
    const paths = Array.from(
      new Set(
        [indexed.sourcePath, ...Object.values(indexed.variantPaths)].filter(
          (path): path is string => Boolean(path)
        )
      )
    );
    for (const path of paths) await this.trash(path);
    this.indexedEntries.delete(entryID);
  }

  async captureText(clipboardText: string): Promise<string> {
    const text = clipboardText.trim();
    if (!text) throw new Error('Clipboard does not contain text.');
    await this.ensureWorkspace();
    const captureID = randomUUID().toUpperCase();
    const now = new Date().toISOString();
    const sourceURL = safeHTTPURL(text);
    const title = sourceURL ? sourceURL.hostname.replace(/^www\./, '') : firstUsefulLine(text);
    const filename = await this.availableFilename(slug(title || 'capture'));
    const quoted = (value: string) => JSON.stringify(value);
    const metadata = [
      '---',
      `id: ${quoted(captureID)}`,
      `type: ${quoted(sourceURL ? 'link' : 'text')}`,
      `title: ${quoted(title || 'Clipboard capture')}`,
      `created_at: ${quoted(now)}`,
      `updated_at: ${quoted(now)}`,
      'tags: []',
      'topics: []',
      ...(sourceURL ? [`source_url: ${quoted(sourceURL.toString())}`] : []),
      '---',
      '',
      '',
      text,
      ''
    ].join('\n');
    await atomicWrite(join(this.workspacePath, 'library', filename), metadata);
    return captureID;
  }

  private async indexSource(
    filename: string,
    topicNames: Map<string, string>
  ): Promise<IndexedEntry> {
    const sourcePath = join(this.workspacePath, 'library', filename);
    const [sourceText, sourceStat] = await Promise.all([
      readFile(sourcePath, 'utf8'),
      stat(sourcePath)
    ]);
    const parsed = parseMarkdown(sourceText);
    const captureID = stringValue(parsed.metadata.id) || filename;
    const title =
      stringValue(parsed.metadata.title) ||
      firstHeading(parsed.body) ||
      basename(filename, '.md').replaceAll('-', ' ');
    const topicIDs = arrayValue(parsed.metadata.topics);
    const variantPaths: Partial<Record<LibraryVariant, string>> = { source: sourcePath };
    for (const variant of summaryVariants) {
      const primary = join(
        this.workspacePath,
        'library',
        'summaries',
        variant,
        filename
      );
      if (await isFile(primary)) {
        variantPaths[variant] = primary;
      } else if (variant === 'concise') {
        const legacy = join(this.workspacePath, 'library', 'summaries', filename);
        if (await isFile(legacy)) variantPaths.concise = legacy;
      }
    }
    const excerptPath =
      variantPaths.brief ?? variantPaths.concise ?? variantPaths.source ?? sourcePath;
    const excerptText =
      excerptPath === sourcePath
        ? parsed.body
        : await readFile(excerptPath, 'utf8');
    const id = `personal:${captureID}`;
    return {
      entry: {
        id,
        captureID,
        filename,
        title,
        excerpt: excerpt(excerptText),
        topicIDs,
        topicNames: topicIDs.map((topic) => topicNames.get(topic) ?? titleize(topic)),
        tags: arrayValue(parsed.metadata.tags),
        sourceURL: stringValue(parsed.metadata.source_url) || undefined,
        createdAt:
          stringValue(parsed.metadata.created_at) || sourceStat.birthtime.toISOString(),
        updatedAt:
          stringValue(parsed.metadata.updated_at) || sourceStat.mtime.toISOString(),
        availableVariants: libraryVariants.filter((variant) => variantPaths[variant])
      },
      sourcePath,
      variantPaths
    };
  }

  private async readTopicNames(): Promise<Map<string, string>> {
    const result = new Map<string, string>();
    try {
      const lines = (await readFile(join(this.workspacePath, 'topics.md'), 'utf8')).split(
        /\r?\n/
      );
      let currentID: string | null = null;
      for (const line of lines) {
        const idMatch = /^\s*-\s+id:\s*(.+?)\s*$/.exec(line);
        if (idMatch) {
          currentID = unquote(idMatch[1]);
          continue;
        }
        const titleMatch = /^\s+title:\s*(.+?)\s*$/.exec(line);
        if (currentID && titleMatch) {
          result.set(currentID, unquote(titleMatch[1]));
          currentID = null;
        }
      }
    } catch {
      // A missing taxonomy is valid for a brand-new workspace.
    }
    return result;
  }

  private async requireEntry(entryID: string): Promise<IndexedEntry> {
    if (!this.indexedEntries.has(entryID)) await this.snapshot();
    const entry = this.indexedEntries.get(entryID);
    if (!entry) throw new Error('The selected library item no longer exists.');
    return entry;
  }

  private async availableFilename(base: string): Promise<string> {
    for (let suffix = 0; ; suffix += 1) {
      const filename = `${base}${suffix === 0 ? '' : `-${suffix + 1}`}.md`;
      if (!(await isFile(join(this.workspacePath, 'library', filename)))) return filename;
    }
  }
}

export function parseMarkdown(text: string): ParsedMarkdown {
  if (!text.startsWith('---')) {
    return { metadata: {}, frontmatter: null, body: text };
  }
  const match = /^---\r?\n([\s\S]*?)\r?\n---(?:\r?\n|$)/.exec(text);
  if (!match) return { metadata: {}, frontmatter: null, body: text };
  const metadata: Record<string, string | string[]> = {};
  let activeList: string | null = null;
  for (const line of match[1].split(/\r?\n/)) {
    const property = /^([A-Za-z0-9_-]+):(?:\s*(.*))?$/.exec(line);
    if (property) {
      const [, key, raw = ''] = property;
      if (!raw.trim()) {
        metadata[key] = [];
        activeList = key;
      } else {
        metadata[key] = parseValue(raw);
        activeList = Array.isArray(metadata[key]) ? key : null;
      }
      continue;
    }
    const item = /^\s+-\s*(.*?)\s*$/.exec(line);
    if (item && activeList) {
      const values = arrayValue(metadata[activeList]);
      values.push(unquote(item[1]));
      metadata[activeList] = values;
    }
  }
  return {
    metadata,
    frontmatter: match[0].trim(),
    body: text.slice(match[0].length).replace(/^\s+/, '')
  };
}

function parseValue(value: string): string | string[] {
  const trimmed = value.trim();
  if (trimmed === '[]') return [];
  if (trimmed.startsWith('[')) {
    try {
      const decoded = JSON.parse(trimmed) as unknown;
      if (Array.isArray(decoded)) return decoded.map(String);
    } catch {
      return trimmed
        .slice(1, -1)
        .split(',')
        .map((item) => unquote(item))
        .filter(Boolean);
    }
  }
  return unquote(trimmed);
}

function unquote(value: string): string {
  const trimmed = value.trim();
  if (trimmed.startsWith('"')) {
    try {
      return JSON.parse(trimmed) as string;
    } catch {
      return trimmed.slice(1, -1);
    }
  }
  return trimmed.replace(/^'|'$/g, '');
}

function stringValue(value: string | string[] | undefined): string {
  return typeof value === 'string' ? value : '';
}

function arrayValue(value: string | string[] | undefined): string[] {
  if (Array.isArray(value)) return [...value];
  return value ? [value] : [];
}

function firstHeading(text: string): string {
  return /^#\s+(.+)$/m.exec(text)?.[1]?.trim() ?? '';
}

function firstUsefulLine(text: string): string {
  return (
    text
      .split(/\r?\n/)
      .map((line) => line.replace(/^#+\s*/, '').trim())
      .find(Boolean)
      ?.slice(0, 80) ?? 'Clipboard capture'
  );
}

function safeHTTPURL(value: string): URL | null {
  if (/\s/.test(value)) return null;
  try {
    const url = new URL(value);
    return url.protocol === 'http:' || url.protocol === 'https:' ? url : null;
  } catch {
    return null;
  }
}

function excerpt(text: string): string {
  const cleaned = text
    .replace(/^---[\s\S]*?---\s*/m, '')
    .replace(/```[\s\S]*?```/g, ' ')
    .replace(/!\[[^\]]*\]\([^)]+\)/g, ' ')
    .replace(/\[([^\]]+)\]\([^)]+\)/g, '$1')
    .replace(/[#>*_~`-]/g, ' ')
    .replace(/\s+/g, ' ')
    .trim();
  return cleaned.length > 240 ? `${cleaned.slice(0, 237).trim()}…` : cleaned;
}

function slug(value: string): string {
  const normalized = value
    .normalize('NFKD')
    .replace(/[\u0300-\u036f]/g, '')
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-|-$/g, '')
    .slice(0, 64);
  return normalized || 'capture';
}

function titleize(value: string): string {
  return value
    .replace(/[-_]+/g, ' ')
    .replace(/\b\w/g, (character) => character.toUpperCase());
}

async function isFile(path: string): Promise<boolean> {
  try {
    return (await stat(path)).isFile();
  } catch {
    return false;
  }
}

async function atomicWrite(path: string, text: string): Promise<void> {
  await mkdir(dirname(path), { recursive: true });
  const temporaryPath = `${path}.${randomUUID()}.tmp`;
  await writeFile(temporaryPath, text, 'utf8');
  await rename(temporaryPath, path);
}
