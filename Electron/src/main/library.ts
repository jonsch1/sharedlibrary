import { createHash, randomUUID } from 'node:crypto';
import {
  mkdir,
  readFile,
  readdir,
  rename,
  stat,
  writeFile
} from 'node:fs/promises';
import { basename, dirname, join, relative } from 'node:path';
import {
  libraryVariants,
  type DesktopPlatform,
  type DesktopLibraryEntry,
  type DesktopLibrarySnapshot,
  type LibraryVariant,
  type TopicDefinition
} from '../shared/contracts.js';
import type {
  LibraryEntry,
  LibraryFile,
  LibraryMedia,
  LibraryMediaKind,
  LibraryPodcast,
  LibraryProjection,
  LibraryText
} from '../../../Shared/library.js';

interface ParsedMarkdown {
  metadata: Record<string, string | string[]>;
  frontmatter: string | null;
  body: string;
}

interface IndexedEntry {
  entry: DesktopLibraryEntry;
  sourcePath: string;
  audioPath?: string;
  variantPaths: Partial<Record<LibraryVariant, string>>;
}

export type DriveLibraryFile = LibraryFile;
export type DriveLibraryMedia = LibraryMedia & { content: string };
export type DriveLibraryText = LibraryText & {
  path: string;
  contentHash: string;
  wordCount: number;
};

export interface DriveLibraryIndex extends Omit<LibraryProjection, 'entries'> {
  schemaVersion: 3;
  entries: Array<Omit<LibraryEntry, 'captureID' | 'origin' | 'texts'> & {
    captureID: string;
    origin: 'personal';
    texts: DriveLibraryText[];
  }>;
}

export interface DriveLibraryMirror {
  index: DriveLibraryIndex;
  files: Array<DriveLibraryFile & { content: string }>;
  media: DriveLibraryMedia[];
}

export interface MirrorMergeResult {
  changed: number;
  conflicts: number;
}

export interface ProcessingSuggestion {
  shortFilename: string;
  topicName: string;
  summaries: Record<(typeof summaryVariants)[number], string>;
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

  async topicDefinitions(): Promise<TopicDefinition[]> {
    const result: TopicDefinition[] = [];
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
          result.push({ id: currentID, title: unquote(titleMatch[1]) });
          currentID = null;
        }
      }
    } catch {
      // A missing taxonomy is valid for a brand-new workspace.
    }
    return result;
  }

  async replaceTopicDefinitions(
    definitions: TopicDefinition[]
  ): Promise<TopicDefinition[]> {
    const current = await this.topicDefinitions();
    const currentIDs = new Set(current.map((topic) => topic.id));
    const usedIDs = new Set(
      (await this.snapshot()).entries.flatMap((entry) => entry.topicIDs)
    );
    const ids = new Set<string>();
    const titles = new Set<string>();
    const normalized: TopicDefinition[] = [];

    for (const definition of definitions) {
      const title = definition.title.trim().replace(/\s+/g, ' ');
      if (!title) throw new Error('Every topic needs a title.');
      if (title.length > 48) throw new Error('Topic titles must be 48 characters or fewer.');
      const titleKey = title.toLowerCase();
      if (titles.has(titleKey)) throw new Error(`The topic “${title}” is duplicated.`);
      titles.add(titleKey);

      let id = definition.id.trim();
      if (id && !/^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$/.test(id)) {
        throw new Error(`The topic ID “${id}” is invalid.`);
      }
      if (!id) {
        const base = slug(title);
        id = base;
        for (let suffix = 2; ids.has(id) || currentIDs.has(id); suffix += 1) {
          id = `${base}-${suffix}`;
        }
      }
      if (ids.has(id)) throw new Error(`The topic ID “${id}” is duplicated.`);
      ids.add(id);
      normalized.push({ id, title });
    }

    for (const id of usedIDs) {
      if (currentIDs.has(id) && !ids.has(id)) {
        throw new Error(
          `The topic “${current.find((topic) => topic.id === id)?.title ?? id}” is still used by library items. Rename it instead of removing it.`
        );
      }
    }

    const text = [
      'topics:',
      ...normalized.flatMap((topic) => [
        `  - id: ${JSON.stringify(topic.id)}`,
        `    title: ${JSON.stringify(topic.title)}`
      ]),
      ''
    ].join('\n');
    await atomicWrite(join(this.workspacePath, 'topics.md'), text);
    this.indexedEntries.clear();
    return normalized;
  }

  async ensureTopic(titleValue: string): Promise<TopicDefinition> {
    const title = titleValue.trim().replace(/\s+/g, ' ');
    if (!title) throw new Error('The topic title cannot be empty.');
    if (title.length > 48) throw new Error('Topic titles must be 48 characters or fewer.');
    const current = await this.topicDefinitions();
    const existing = current.find(
      (topic) => topic.title.toLowerCase() === title.toLowerCase()
    );
    if (existing) return existing;
    const updated = await this.replaceTopicDefinitions([
      ...current,
      { id: '', title }
    ]);
    const created = updated.at(-1);
    if (!created) throw new Error('The topic could not be created.');
    return created;
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

  async filePath(
    entryID: string,
    variant: LibraryVariant = 'source'
  ): Promise<string> {
    const indexed = await this.requireEntry(entryID);
    return indexed.variantPaths[variant] ?? indexed.sourcePath;
  }

  async trashCapture(entryID: string): Promise<void> {
    const indexed = await this.requireEntry(entryID);
    const paths = Array.from(
      new Set(
        [indexed.sourcePath, indexed.audioPath, ...Object.values(indexed.variantPaths)].filter(
          (path): path is string => Boolean(path)
        )
      )
    );
    for (const path of paths) await this.trash(path);
    this.indexedEntries.delete(entryID);
  }

  async captureText(
    clipboardText: string,
    extracted?: {
      title?: string;
      content?: string;
      sourceURL?: string;
      entryType?: 'podcast_source';
      mediaURL?: string;
      audio?: {
        bytes: Uint8Array;
        extension: 'aac' | 'flac' | 'm4a' | 'mp3' | 'ogg' | 'opus' | 'wav' | 'webm';
      };
      favicon?: {
        bytes: Uint8Array;
        extension: 'gif' | 'ico' | 'jpg' | 'png' | 'webp';
      };
    },
    topicIDs: string[] = []
  ): Promise<string> {
    const text = clipboardText.trim();
    if (!text) throw new Error('Clipboard does not contain text.');
    await this.ensureWorkspace();
    const knownTopicIDs = new Set(
      (await this.topicDefinitions()).map((topic) => topic.id)
    );
    const normalizedTopicIDs = [...new Set(topicIDs)];
    const unknownTopicID = normalizedTopicIDs.find((id) => !knownTopicIDs.has(id));
    if (unknownTopicID) throw new Error(`The topic “${unknownTopicID}” does not exist.`);
    const captureID = randomUUID().toUpperCase();
    const now = new Date().toISOString();
    const sourceURL = safeHTTPURL(extracted?.sourceURL ?? text);
    const mediaURL = safeHTTPURL(extracted?.mediaURL ?? '');
    const audioPath = extracted?.audio
      ? `audio/${captureID}.${extracted.audio.extension}`
      : undefined;
    const faviconID = extracted?.favicon ? sha256(extracted.favicon.bytes) : undefined;
    const faviconFile =
      faviconID && extracted?.favicon
        ? `${faviconID}.${extracted.favicon.extension}`
        : undefined;
    const content = extracted?.content?.trim() || text;
    const title =
      extracted?.title?.trim() ||
      (sourceURL ? sourceURL.hostname.replace(/^www\./, '') : firstUsefulLine(content));
    const filename = await this.availableFilename(slug(title || 'capture'));
    const quoted = (value: string) => JSON.stringify(value);
    const metadata = [
      '---',
      `id: ${quoted(captureID)}`,
      `type: ${quoted(extracted?.entryType ?? (sourceURL ? 'link' : 'text'))}`,
      `title: ${quoted(title || 'Clipboard capture')}`,
      `created_at: ${quoted(now)}`,
      `updated_at: ${quoted(now)}`,
      'tags: []',
      ...(normalizedTopicIDs.length === 0
        ? ['topics: []']
        : [
            'topics:',
            ...normalizedTopicIDs.map((topicID) => `  - ${quoted(topicID)}`)
          ]),
      ...(sourceURL ? [`source_url: ${quoted(sourceURL.toString())}`] : []),
      ...(mediaURL ? [`media_url: ${quoted(mediaURL.toString())}`] : []),
      ...(audioPath ? [`audio_path: ${quoted(audioPath)}`] : []),
      ...(faviconFile ? [`favicon_path: ${quoted(`favicons/${faviconFile}`)}`] : []),
      '---',
      '',
      '',
      content,
      ''
    ].join('\n');
    if (faviconFile && extracted?.favicon) {
      const faviconPath = join(
        this.workspacePath,
        'library',
        'favicons',
        faviconFile
      );
      if (!(await isFile(faviconPath))) {
        await atomicWrite(faviconPath, extracted.favicon.bytes);
      }
    }
    if (audioPath && extracted?.audio) {
      await atomicWrite(
        join(this.workspacePath, 'library', audioPath),
        extracted.audio.bytes
      );
    }
    await atomicWrite(join(this.workspacePath, 'library', filename), metadata);
    return captureID;
  }

  async capturePodcastEpisode(value: {
    podcastID: string;
    podcastTitle: string;
    title: string;
    body: string;
    sources: string[];
    sourceIDs: string[];
    audio?: Uint8Array;
  }): Promise<string> {
    await this.ensureWorkspace();
    const captureID = randomUUID().toUpperCase();
    const now = new Date().toISOString();
    const filename = await this.availableFilename(
      slug(`${value.podcastTitle}-${now.slice(0, 10)}`)
    );
    const audioPath = value.audio ? `audio/${captureID}.wav` : undefined;
    const metadata = {
      id: captureID,
      type: 'podcast_episode',
      title: value.title.trim() || `${value.podcastTitle} — ${now.slice(0, 10)}`,
      created_at: now,
      updated_at: now,
      tags: ['podcast'],
      topics: [],
      podcast_id: value.podcastID,
      podcast_title: value.podcastTitle,
      ...(audioPath ? { audio_path: audioPath } : {}),
      source_ids: [...new Set(value.sourceIDs)],
      source_urls: [...new Set(value.sources)]
    };
    await atomicWrite(
      join(this.workspacePath, 'library', filename),
      `${serializeFrontmatter(metadata)}\n\n${value.body.trim()}\n`
    );
    if (audioPath && value.audio) {
      await atomicWrite(join(this.workspacePath, 'library', audioPath), value.audio);
    }
    this.indexedEntries.clear();
    return `personal:${captureID}`;
  }

  async attachPodcastAudio(entryID: string, audio: Uint8Array): Promise<void> {
    const indexed = await this.requireEntry(entryID);
    if (indexed.entry.entryType !== 'podcast_episode') {
      throw new Error('Audio can only be attached to an audio brief episode.');
    }
    const parsed = parseMarkdown(await readFile(indexed.sourcePath, 'utf8'));
    const audioRelativePath = `audio/${indexed.entry.captureID}.wav`;
    await atomicWrite(join(this.workspacePath, 'library', audioRelativePath), audio);
    await atomicWrite(
      indexed.sourcePath,
      `${serializeFrontmatter({
        ...parsed.metadata,
        updated_at: new Date().toISOString(),
        audio_path: audioRelativePath
      })}\n\n${parsed.body.trim()}\n`
    );
    this.indexedEntries.clear();
  }

  async markPodcastSources(
    entryIDs: string[]
  ): Promise<{ snapshot: DesktopLibrarySnapshot; changed: boolean }> {
    const sourceIDs = new Set(entryIDs);
    const snapshot = await this.snapshot();
    let changed = false;
    for (const entry of snapshot.entries) {
      if (!sourceIDs.has(entry.id) || entry.entryType === 'podcast_source') continue;
      const indexed = this.indexedEntries.get(entry.id);
      if (!indexed) continue;
      const text = await readFile(indexed.sourcePath, 'utf8');
      const updated = text.replace(/^type:.*$/m, 'type: "podcast_source"');
      if (updated === text) continue;
      await atomicWrite(indexed.sourcePath, updated);
      changed = true;
    }
    return {
      snapshot: changed ? await this.snapshot() : snapshot,
      changed
    };
  }

  async podcastAudioPath(entryID: string): Promise<string> {
    const path = (await this.requireEntry(entryID)).audioPath;
    if (!path) throw new Error('That audio brief episode has no audio.');
    return path;
  }

  async faviconPath(faviconFile: string): Promise<string> {
    if (!/^[a-f0-9]{64}\.(?:gif|ico|jpg|png|webp)$/.test(faviconFile)) {
      throw new Error('Invalid favicon.');
    }
    const path = join(this.workspacePath, 'library', 'favicons', faviconFile);
    if (!(await isFile(path))) throw new Error('That favicon does not exist.');
    return path;
  }

  async processingInput(entryID: string): Promise<{
    title: string;
    sourceURL?: string;
    sourceText: string;
    topics: string[];
  }> {
    const indexed = await this.requireEntry(entryID);
    const raw = await readFile(indexed.sourcePath, 'utf8');
    const parsed = parseMarkdown(raw);
    return {
      title: indexed.entry.title,
      sourceURL: indexed.entry.sourceURL,
      sourceText: parsed.body.trim(),
      topics: (await this.topicDefinitions()).map((topic) => topic.title)
    };
  }

  async applyProcessingSuggestion(
    entryID: string,
    suggestion: ProcessingSuggestion,
    topicIDOverride?: string
  ): Promise<string> {
    const indexed = await this.requireEntry(entryID);
    const topicID = topicIDOverride
      ? await this.requireTopicID(topicIDOverride)
      : (
          await this.ensureTopic(
            suggestion.topicName.trim().replace(/\s+/g, ' ').slice(0, 48)
          )
        ).id;
    const originalRaw = await readFile(indexed.sourcePath, 'utf8');
    const parsed = parseMarkdown(originalRaw);
    const currentFilename = basename(indexed.sourcePath);
    const requestedBase = slug(suggestion.shortFilename);
    const requestedFilename = `${requestedBase}.md`;
    const nextFilename =
      requestedFilename === currentFilename
        ? currentFilename
        : await this.availableFilename(requestedBase);
    const nextSourcePath = join(this.workspacePath, 'library', nextFilename);
    const metadata = {
      ...parsed.metadata,
      title: indexed.entry.title,
      updated_at: new Date().toISOString(),
      topics: [topicID]
    };
    await atomicWrite(
      nextSourcePath,
      `${serializeFrontmatter(metadata)}\n\n${parsed.body.trim()}\n`
    );
    if (nextSourcePath !== indexed.sourcePath) {
      await this.trash(indexed.sourcePath);
    }

    for (const variant of summaryVariants) {
      const text = suggestion.summaries[variant]?.trim();
      if (!text) throw new Error(`Processing did not return the ${variant} summary.`);
      await atomicWrite(
        join(this.workspacePath, 'library', 'summaries', variant, nextFilename),
        `${text}\n`
      );
    }
    await atomicWrite(
      join(this.workspacePath, 'library', 'summaries', nextFilename),
      `${suggestion.summaries.concise.trim()}\n`
    );
    for (const oldPath of Object.values(indexed.variantPaths)) {
      if (oldPath && basename(oldPath) !== nextFilename && oldPath !== indexed.sourcePath) {
        await this.trash(oldPath);
      }
    }
    this.indexedEntries.clear();
    return `personal:${indexed.entry.captureID}`;
  }

  async buildDriveMirror(): Promise<DriveLibraryMirror> {
    const snapshot = await this.snapshot();
    const paths = await this.mirroredPaths();
    const files = await Promise.all(
      paths.map(async (relativePath) => {
        const content = await readFile(join(this.workspacePath, relativePath), 'utf8');
        return {
          path: relativePath,
          contentHash: sha256(content),
          byteCount: Buffer.byteLength(content),
          content
        };
      })
    );
    const filesByPath = new Map(files.map((file) => [file.path, file]));
    const mediaByHash = new Map<string, DriveLibraryMedia>();
    const addMedia = async (
      kind: LibraryMediaKind,
      path: string
    ): Promise<LibraryMedia | undefined> => {
      if (!(await isFile(join(this.workspacePath, path)))) return undefined;
      const bytes = new Uint8Array(await readFile(join(this.workspacePath, path)));
      const contentHash = sha256(bytes);
      const media: DriveLibraryMedia = {
        kind,
        path,
        contentHash,
        byteCount: bytes.byteLength,
        contentType: mediaContentType(path, kind),
        content: Buffer.from(bytes).toString('base64')
      };
      mediaByHash.set(`${kind}:${contentHash}`, media);
      const { content: _, ...reference } = media;
      return reference;
    };
    const entries = await Promise.all(snapshot.entries.map(async (entry) => {
      const texts = entry.availableVariants.flatMap((variant) => {
        const path =
          variant === 'source'
            ? `library/${entry.filename}`
            : `library/summaries/${variant}/${entry.filename}`;
        const file = filesByPath.get(path);
        if (!file) return [];
        const text =
          variant === 'source' ? parseMarkdown(file.content).body : file.content;
        return [{
          variant,
          path,
          contentHash: file.contentHash,
          wordCount: countWords(text)
        }];
      });
      const indexed = this.indexedEntries.get(entry.id);
      const audioPath = indexed?.audioPath
        ? relative(this.workspacePath, indexed.audioPath).split('\\').join('/')
        : undefined;
      const audio = audioPath ? await addMedia('audio', audioPath) : undefined;
      const faviconPath = entry.faviconFile
        ? `library/favicons/${entry.faviconFile}`
        : undefined;
      const favicon = faviconPath ? await addMedia('favicon', faviconPath) : undefined;
      return {
        id: entry.id,
        captureID: entry.captureID,
        entryType: entry.entryType,
        podcastID: entry.podcastID,
        title: entry.title,
        excerpt: entry.excerpt,
        topicIDs: entry.topicIDs,
        topicNames: entry.topicNames,
        tags: entry.tags,
        sourceURL: entry.sourceURL,
        mediaURL: entry.mediaURL,
        faviconFile: entry.faviconFile,
        audio,
        favicon,
        sourceIDs: entry.sourceIDs,
        sourceURLs: entry.sourceURLs,
        hasAudio: Boolean(audio),
        createdAt: entry.createdAt,
        updatedAt: entry.updatedAt,
        origin: 'personal' as const,
        texts
      };
    }));
    const podcasts: LibraryPodcast[] = files.flatMap((file) => {
      if (
        !/^podcasts\/[^/]+\.md$/i.test(file.path) ||
        file.path.toLowerCase() === 'podcasts/readme.md'
      ) return [];
      const filename = basename(file.path);
      const metadata = parseMarkdown(file.content).metadata;
      return [{
        id: stringValue(metadata.id) || `file:${filename}`,
        filename,
        title:
          stringValue(metadata.name) ||
          stringValue(metadata.title) ||
          basename(filename, '.md').replaceAll('-', ' '),
        schedule: stringValue(metadata.schedule) || 'manual',
        length: stringValue(metadata.length),
        sources: arrayValue(metadata.sources)
      }];
    });
    return {
      index: {
        schemaVersion: 3,
        generatedAt: new Date().toISOString(),
        files: files.map(({ path, contentHash, byteCount }) => ({
          path,
          contentHash,
          byteCount
        })),
        entries,
        podcasts
      },
      files,
      media: [...mediaByHash.values()]
    };
  }

  async mergeRemoteMirror(
    index: DriveLibraryIndex,
    download: (file: DriveLibraryFile) => Promise<string>
  ): Promise<MirrorMergeResult> {
    const baseline = await this.readSyncBaseline();
    const local = await this.buildDriveMirror();
    const localHashes = new Map(local.files.map((file) => [file.path, file.contentHash]));
    const remoteFiles = new Map(
      index.files
        .filter((file) => validMirroredPath(file.path))
        .map((file) => [file.path, file])
    );
    let changed = 0;
    let conflicts = 0;
    for (const path of new Set([
      ...Object.keys(baseline),
      ...localHashes.keys(),
      ...remoteFiles.keys()
    ])) {
      const localHash = localHashes.get(path);
      const remote = remoteFiles.get(path);
      const previousHash = baseline[path];

      if (!previousHash) {
        if (!localHash && remote) {
          await this.downloadRemoteFile(remote, download);
          changed += 1;
        }
        continue;
      }

      const localChanged = localHash !== previousHash;
      const remoteChanged = remote?.contentHash !== previousHash;
      if (!localChanged && !remoteChanged) continue;

      if (!localChanged && !remote) {
        await this.trash(join(this.workspacePath, path));
        changed += 1;
        continue;
      }

      if (!localChanged && remote) {
        await this.downloadRemoteFile(remote, download);
        changed += 1;
        continue;
      }

      if (!remoteChanged || localHash === remote?.contentHash) continue;

      if (localHash) {
        const content = await readFile(join(this.workspacePath, path), 'utf8');
        await this.writeConflictCopy(path, content);
        await this.trash(join(this.workspacePath, path));
      }
      if (remote) {
        if (!localHash) {
          const content = await this.validatedRemoteContent(remote, download);
          await this.writeConflictCopy(path, content);
        } else {
          await this.downloadRemoteFile(remote, download);
        }
      }
      changed += 1;
      conflicts += 1;
    }
    if (changed > 0) this.indexedEntries.clear();
    return { changed, conflicts };
  }

  async mergeRemoteMedia(
    index: DriveLibraryIndex,
    download: (media: LibraryMedia) => Promise<Uint8Array>
  ): Promise<number> {
    const media = index.entries.flatMap((entry) =>
      [entry.audio, entry.favicon].filter(
        (candidate): candidate is LibraryMedia => Boolean(candidate)
      )
    );
    let downloaded = 0;
    for (const remote of media) {
      if (!validMediaPath(remote.path, remote.kind)) continue;
      const path = join(this.workspacePath, remote.path);
      if (await isFile(path)) {
        const local = new Uint8Array(await readFile(path));
        if (sha256(local) === remote.contentHash) continue;
      }
      const bytes = await download(remote);
      if (
        bytes.byteLength !== remote.byteCount ||
        sha256(bytes) !== remote.contentHash
      ) {
        throw new Error(`The synchronized copy of ${remote.path} is invalid.`);
      }
      await atomicWrite(path, bytes);
      downloaded += 1;
    }
    if (downloaded > 0) this.indexedEntries.clear();
    return downloaded;
  }

  async saveSyncBaseline(files: DriveLibraryFile[]): Promise<void> {
    const path = join(this.workspacePath, '.shared-library', 'electron-sync-state.json');
    await atomicWrite(
      path,
      `${JSON.stringify(
        {
          schemaVersion: 1,
          updatedAt: new Date().toISOString(),
          files: Object.fromEntries(files.map((file) => [file.path, file.contentHash]))
        },
        null,
        2
      )}\n`
    );
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
    const audioRelativePath = stringValue(parsed.metadata.audio_path);
    const audioPath =
      /^audio\/[A-Za-z0-9-]+\.(?:aac|flac|m4a|mp3|ogg|opus|wav|webm)$/.test(
        audioRelativePath
      )
        ? join(this.workspacePath, 'library', audioRelativePath)
        : undefined;
    const existingAudioPath = audioPath && (await isFile(audioPath)) ? audioPath : undefined;
    const faviconRelativePath = stringValue(parsed.metadata.favicon_path);
    const faviconMatch =
      /^favicons\/([a-f0-9]{64}\.(?:gif|ico|jpg|png|webp))$/.exec(
        faviconRelativePath
      );
    const faviconFile =
      faviconMatch &&
      (await isFile(join(this.workspacePath, 'library', faviconRelativePath)))
        ? faviconMatch[1]
        : undefined;
    return {
      entry: {
        id,
        captureID,
        entryType: stringValue(parsed.metadata.type) || undefined,
        podcastID: stringValue(parsed.metadata.podcast_id) || undefined,
        filename,
        title,
        excerpt: excerpt(excerptText),
        topicIDs,
        topicNames: topicIDs.map((topic) => topicNames.get(topic) ?? titleize(topic)),
        tags: arrayValue(parsed.metadata.tags),
        sourceURL: stringValue(parsed.metadata.source_url) || undefined,
        mediaURL: safeHTTPURL(stringValue(parsed.metadata.media_url))?.toString(),
        faviconFile,
        sourceIDs: arrayValue(parsed.metadata.source_ids),
        sourceURLs: arrayValue(parsed.metadata.source_urls),
        createdAt:
          stringValue(parsed.metadata.created_at) || sourceStat.birthtime.toISOString(),
        updatedAt:
          stringValue(parsed.metadata.updated_at) || sourceStat.mtime.toISOString(),
        hasAudio: Boolean(existingAudioPath),
        availableVariants: libraryVariants.filter((variant) => variantPaths[variant])
      },
      sourcePath,
      audioPath: existingAudioPath,
      variantPaths
    };
  }

  private async readTopicNames(): Promise<Map<string, string>> {
    return new Map(
      (await this.topicDefinitions()).map((topic) => [topic.id, topic.title])
    );
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

  private async requireTopicID(topicID: string): Promise<string> {
    const topic = (await this.topicDefinitions()).find(
      (candidate) => candidate.id === topicID
    );
    if (!topic) throw new Error(`The topic “${topicID}” does not exist.`);
    return topic.id;
  }

  private async mirroredPaths(): Promise<string[]> {
    const paths: string[] = [];
    if (await isFile(join(this.workspacePath, 'topics.md'))) paths.push('topics.md');
    const walk = async (directory: string, relative: string): Promise<void> => {
      let entries;
      try {
        entries = await readdir(directory, { withFileTypes: true });
      } catch {
        return;
      }
      for (const entry of entries) {
        const childRelative = relative ? `${relative}/${entry.name}` : entry.name;
        const childPath = join(directory, entry.name);
        if (entry.isDirectory()) await walk(childPath, childRelative);
        else if (entry.isFile() && childRelative.toLowerCase().endsWith('.md')) {
          paths.push(`library/${childRelative}`);
        }
      }
    };
    await walk(join(this.workspacePath, 'library'), '');
    const podcastDirectory = join(this.workspacePath, 'podcasts');
    try {
      const podcastFiles = await readdir(podcastDirectory, { withFileTypes: true });
      for (const entry of podcastFiles) {
        if (entry.isFile() && entry.name.toLowerCase().endsWith('.md')) {
          paths.push(`podcasts/${entry.name}`);
        }
      }
    } catch {
      // A workspace without scheduled podcasts has nothing extra to mirror.
    }
    return paths.sort((left, right) => left.localeCompare(right));
  }

  private async readSyncBaseline(): Promise<Record<string, string>> {
    try {
      const value = JSON.parse(
        await readFile(
          join(this.workspacePath, '.shared-library', 'electron-sync-state.json'),
          'utf8'
        )
      ) as { schemaVersion?: number; files?: unknown };
      if (value.schemaVersion !== 1 || typeof value.files !== 'object' || !value.files) {
        return {};
      }
      return Object.fromEntries(
        Object.entries(value.files).filter(
          ([path, hash]) => validMirroredPath(path) && typeof hash === 'string'
        )
      ) as Record<string, string>;
    } catch {
      return {};
    }
  }

  private async validatedRemoteContent(
    remote: DriveLibraryFile,
    download: (file: DriveLibraryFile) => Promise<string>
  ): Promise<string> {
    const content = await download(remote);
    if (sha256(content) !== remote.contentHash) {
      throw new Error(`The sync provider returned an invalid copy of ${remote.path}.`);
    }
    return content;
  }

  private async downloadRemoteFile(
    remote: DriveLibraryFile,
    download: (file: DriveLibraryFile) => Promise<string>
  ): Promise<void> {
    await atomicWrite(
      join(this.workspacePath, remote.path),
      await this.validatedRemoteContent(remote, download)
    );
  }

  private async writeConflictCopy(path: string, content: string): Promise<void> {
    const directory =
      path === 'topics.md'
        ? '.shared-library/conflicts'
        : path.slice(0, Math.max(0, path.lastIndexOf('/')));
    const filename = path.slice(path.lastIndexOf('/') + 1, -3);
    for (let suffix = 1; ; suffix += 1) {
      const name = `${filename}-conflict${suffix === 1 ? '' : `-${suffix}`}.md`;
      const conflictPath = directory ? `${directory}/${name}` : name;
      if (!(await isFile(join(this.workspacePath, conflictPath)))) {
        await atomicWrite(
          join(this.workspacePath, conflictPath),
          uniqueConflictMetadata(content)
        );
        return;
      }
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

function sha256(value: string | Uint8Array): string {
  return createHash('sha256').update(value).digest('hex');
}

function countWords(value: string): number {
  return value.trim() ? value.trim().split(/\s+/u).length : 0;
}

function validMirroredPath(value: string): boolean {
  if (value === 'topics.md') return true;
  if (
    !(value.startsWith('library/') || value.startsWith('podcasts/')) ||
    !value.toLowerCase().endsWith('.md')
  ) return false;
  return !value.split('/').some((component) => !component || component === '.' || component === '..');
}

function uniqueConflictMetadata(content: string): string {
  if (!content.startsWith('---')) return content;
  const id = randomUUID();
  if (/^id:\s*.*$/m.test(content)) {
    return content.replace(/^id:\s*.*$/m, `id: ${JSON.stringify(id)}`);
  }
  return content.replace(/^---\r?\n/, `---\nid: ${JSON.stringify(id)}\n`);
}

function validMediaPath(value: string, kind: LibraryMediaKind): boolean {
  const directory = kind === 'audio' ? 'audio' : 'favicons';
  return (
    value.startsWith(`library/${directory}/`) &&
    !value.split('/').some((component) => !component || component === '.' || component === '..')
  );
}

function mediaContentType(path: string, kind: LibraryMediaKind): string {
  const extension = path.split('.').at(-1)?.toLowerCase() ?? '';
  const types: Record<string, string> = kind === 'audio'
    ? {
        aac: 'audio/aac',
        flac: 'audio/flac',
        m4a: 'audio/mp4',
        mp3: 'audio/mpeg',
        ogg: 'audio/ogg',
        opus: 'audio/ogg',
        wav: 'audio/wav',
        webm: 'audio/webm'
      }
    : {
        gif: 'image/gif',
        ico: 'image/x-icon',
        jpg: 'image/jpeg',
        png: 'image/png',
        webp: 'image/webp'
      };
  return types[extension] ?? (kind === 'audio' ? 'audio/mpeg' : 'image/png');
}

function serializeFrontmatter(metadata: Record<string, string | string[]>): string {
  const preferred = [
    'id',
    'type',
    'title',
    'created_at',
    'updated_at',
    'tags',
    'topics',
    'source_url'
  ];
  const keys = [
    ...preferred.filter((key) => metadata[key] !== undefined),
    ...Object.keys(metadata)
      .filter((key) => !preferred.includes(key))
      .sort()
  ];
  const lines = ['---'];
  for (const key of keys) {
    const value = metadata[key];
    if (Array.isArray(value)) {
      if (value.length === 0) lines.push(`${key}: []`);
      else {
        lines.push(`${key}:`);
        for (const item of value) lines.push(`  - ${JSON.stringify(item)}`);
      }
    } else {
      lines.push(`${key}: ${JSON.stringify(value)}`);
    }
  }
  lines.push('---');
  return lines.join('\n');
}

async function isFile(path: string): Promise<boolean> {
  try {
    return (await stat(path)).isFile();
  } catch {
    return false;
  }
}

async function atomicWrite(path: string, value: string | Uint8Array): Promise<void> {
  await mkdir(dirname(path), { recursive: true });
  const temporaryPath = `${path}.${randomUUID()}.tmp`;
  if (typeof value === 'string') await writeFile(temporaryPath, value, 'utf8');
  else await writeFile(temporaryPath, value);
  await rename(temporaryPath, path);
}
