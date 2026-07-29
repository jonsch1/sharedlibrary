import { createHash, randomUUID } from 'node:crypto';
import {
  mkdir,
  readFile,
  readdir,
  rename,
  writeFile
} from 'node:fs/promises';
import { basename, dirname, join } from 'node:path';
import {
  defaultPodcastPrompt,
  type PodcastDefinition,
  type PodcastDraft,
  type PodcastSnapshot
} from '../shared/contracts.js';
import type {
  DiscoveredSource,
  DiscoveredSourceItem
} from './extraction.js';
import { ExtractionService } from './extraction.js';
import { LibraryService, parseMarkdown } from './library.js';
import {
  defaultProcessingCommand,
  runAIText,
  type ManagedAIRunner
} from './processing.js';

const maximumPodcasts = 20;
const maximumSourcesPerPodcast = 200;
const sourceCheckIntervalMilliseconds = 30 * 60 * 1000;
const schedulerIntervalMilliseconds = 60 * 1000;
const maximumEpisodeInputCharacters = 120_000;
const maximumAgentScriptCharacters = 60_000;
const podcastPromptPlaceholders = [
  '{{podcast_title}}',
  '{{requested_length}}',
  '{{source_packets}}'
];

export { defaultPodcastPrompt };

export function podcastAudioRange(
  value: string | null,
  size: number
): { start: number; end: number } | null {
  if (!Number.isSafeInteger(size) || size <= 0) return null;
  if (!value) return { start: 0, end: size - 1 };
  const match = /^bytes=(\d*)-(\d*)$/u.exec(value.trim());
  if (!match || (!match[1] && !match[2])) return null;
  const start = match[1] ? Number(match[1]) : Math.max(0, size - Number(match[2]));
  const end =
    match[1] && match[2] ? Math.min(Number(match[2]), size - 1) : size - 1;
  return Number.isSafeInteger(start) &&
    Number.isSafeInteger(end) &&
    start >= 0 &&
    start <= end &&
    start < size
    ? { start, end }
    : null;
}

interface WatchedItem extends DiscoveredSourceItem {
  entryID: string;
  ingestedAt: string;
}

interface SourceState {
  title?: string;
  kind?: DiscoveredSource['kind'];
  lastCheckedAt?: string;
  error?: string;
  seen: string[];
  items: WatchedItem[];
}

interface PodcastRunState {
  lastRunAt?: string;
  status?: PodcastDefinition['status'];
  message?: string;
  consumed: string[];
}

interface PodcastState {
  schemaVersion: 1;
  sources: Record<string, SourceState>;
  podcasts: Record<string, PodcastRunState>;
}

interface ParsedPodcast {
  id: string;
  filename: string;
  title: string;
  prompt: string;
  schedule: string;
  timezone: string;
  length: string;
  sources: string[];
  error?: string;
}

export interface AgentEpisodeSource {
  url: string;
  title?: string;
  content?: string;
}

export interface AgentEpisodeResult {
  entryID: string;
  duplicate: boolean;
  audioPending: boolean;
}

type FinishIngestion = () => void;

export class PodcastService {
  private timer: NodeJS.Timeout | null = null;
  private queue: Promise<unknown> = Promise.resolve();

  constructor(
    private readonly workspacePath: () => string,
    private readonly library: LibraryService,
    private readonly extraction: ExtractionService,
    private readonly generateAudio: (text: string) => Promise<Uint8Array>,
    private readonly trash: (path: string) => Promise<void>,
    private readonly onChanged: (snapshot: PodcastSnapshot) => void,
    private readonly onLibraryChanged: () => Promise<void>,
    private readonly onSyncRequested: (reason: string) => void,
    private readonly onOperationMessage: (message: string, entryID?: string) => void,
    private readonly onIngestionStarted: () => FinishIngestion,
    private readonly promptTemplate: () => Promise<string> = async () =>
      defaultPodcastPrompt,
    private readonly processingCommand: () => Promise<string> = async () =>
      defaultProcessingCommand,
    private readonly managedAIRunner?: ManagedAIRunner
  ) {}

  start(): void {
    if (this.timer) return;
    this.timer = setInterval(() => void this.tick(), schedulerIntervalMilliseconds);
    this.timer.unref();
    setTimeout(() => void this.tick(), 2_000).unref();
  }

  stop(): void {
    if (this.timer) clearInterval(this.timer);
    this.timer = null;
  }

  wake(): void {
    void this.tick();
  }

  snapshot(): Promise<PodcastSnapshot> {
    return this.enqueue(() => this.buildSnapshot());
  }

  save(value: PodcastDraft): Promise<PodcastSnapshot> {
    return this.enqueue(async () => {
      const podcasts = await this.readDefinitions();
      const draft = normalizeDraft(value);
      const existing = value.id
        ? podcasts.find((podcast) => podcast.id === value.id)
        : undefined;
      if (!existing && podcasts.length >= maximumPodcasts) {
        throw new Error(`A workspace can contain up to ${maximumPodcasts} podcasts.`);
      }
      const filename =
        existing?.filename ??
        availablePodcastFilename(
          slug(draft.title),
          new Set(podcasts.map((podcast) => podcast.filename))
        );
      const id = existing?.id ?? `file:${filename}`;
      const path = join(this.workspacePath(), 'podcasts', filename);
      await atomicWrite(path, serializePodcast({ ...draft, id }));
      this.onSyncRequested('podcast settings');
      return this.notify();
    });
  }

  remove(id: string): Promise<PodcastSnapshot> {
    return this.enqueue(async () => {
      const podcast = await this.requirePodcast(id);
      await this.trash(join(this.workspacePath(), 'podcasts', podcast.filename));
      const state = await this.readState();
      delete state.podcasts[id];
      await this.saveState(state);
      this.onSyncRequested('deleted podcast settings');
      return this.notify();
    });
  }

  check(id: string): Promise<PodcastSnapshot> {
    return this.enqueue(async () => {
      const podcast = await this.requirePodcast(id);
      const state = await this.readState();
      await this.checkSources(podcast, state, true);
      await this.saveState(state);
      return this.notify();
    });
  }

  run(id: string): Promise<PodcastSnapshot> {
    return this.enqueue(async () => {
      const podcast = await this.requirePodcast(id);
      const state = await this.readState();
      await this.checkSources(podcast, state, true);
      await this.generateEpisode(podcast, state);
      await this.saveState(state);
      return this.notify();
    });
  }

  createAgentEpisode(
    id: string,
    scriptValue: string,
    sourceValues: AgentEpisodeSource[]
  ): Promise<AgentEpisodeResult> {
    const script = scriptValue.trim();
    if (!script || script.length > maximumAgentScriptCharacters) {
      throw new Error(
        `Podcast scripts must contain 1–${maximumAgentScriptCharacters.toLocaleString()} characters.`
      );
    }
    const sources = normalizeAgentEpisodeSources(sourceValues);
    return this.enqueue(async () => {
      const podcast = await this.requirePodcast(id);
      const library = await this.library.snapshot();
      const sourceKeys = sources.map(({ url }) => sourceIdentity(url)).sort();
      const duplicate = library.entries.find(
        (entry) =>
          entry.entryType === 'podcast_episode' &&
          entry.podcastID === podcast.id &&
          sameStrings(
            (entry.sourceURLs ?? []).map(sourceIdentity).sort(),
            sourceKeys
          )
      );
      if (duplicate) {
        if (!duplicate.hasAudio) {
          await this.markAgentAudioPending(podcast);
          this.queueAgentAudio(podcast, duplicate.id, script, sources.length);
        }
        return {
          entryID: duplicate.id,
          duplicate: true,
          audioPending: !duplicate.hasAudio
        };
      }

      const existingByKey = new Map(
        library.entries.flatMap((entry) =>
          entry.sourceURL ? [[sourceIdentity(entry.sourceURL), entry] as const] : []
        )
      );
      const selected: Array<{ entryID: string; title: string; url: string }> = [];
      for (const source of sources) {
        const existing = existingByKey.get(sourceIdentity(source.url));
        if (existing) {
          selected.push({
            entryID: existing.id,
            title: source.title || existing.title,
            url: existing.sourceURL ?? source.url
          });
          continue;
        }
        const extracted = source.content
          ? {
              title: source.title,
              content: source.content,
              sourceURL: source.url
            }
          : await this.extraction.extractURL(source.url);
        const { audio: _audio, ...stored } = extracted;
        const captureID = await this.library.captureText(source.url, {
          ...stored,
          title: source.title || extracted.title,
          entryType: 'podcast_source'
        });
        const entryID = `personal:${captureID}`;
        selected.push({
          entryID,
          title: source.title || extracted.title || new URL(source.url).hostname,
          url: extracted.sourceURL || source.url
        });
      }

      const title =
        /^#\s+(.+)$/m.exec(script)?.[1]?.trim() ||
        `${podcast.title} — ${new Date().toLocaleDateString('en-CA')}`;
      const sourceList = selected
        .map(
          (source, index) =>
            `${index + 1}. [${escapeLinkText(source.title)}](${source.url})`
        )
        .join('\n');
      const entryID = await this.library.capturePodcastEpisode({
        podcastID: podcast.id,
        podcastTitle: podcast.title,
        title,
        body: `${script}\n\n## Sources\n\n${sourceList}`,
        sources: selected.map(({ url }) => url),
        sourceIDs: selected.map(({ entryID }) => entryID)
      });
      await this.markAgentAudioPending(podcast);
      await this.onLibraryChanged();
      this.onSyncRequested('agent podcast episode script');
      this.queueAgentAudio(podcast, entryID, script, selected.length);
      return { entryID, duplicate: false, audioPending: true };
    });
  }

  async filePath(id: string): Promise<string> {
    const podcast = await this.requirePodcast(id);
    return join(this.workspacePath(), 'podcasts', podcast.filename);
  }

  private enqueue<T>(work: () => Promise<T>): Promise<T> {
    const result = this.queue.then(work, work);
    this.queue = result.then(() => undefined, () => undefined);
    return result;
  }

  private async tick(): Promise<void> {
    await this.enqueue(async () => {
      const podcasts = await this.readDefinitions();
      const state = await this.readState();
      let changed = false;
      for (const podcast of podcasts.filter((candidate) => !candidate.error)) {
        changed = (await this.checkSources(podcast, state, false)) || changed;
      }
      const now = new Date();
      for (const podcast of podcasts.filter((candidate) => !candidate.error)) {
        const run = state.podcasts[podcast.id] ?? { consumed: [] };
        if (!run.lastRunAt) {
          run.lastRunAt = now.toISOString();
          run.status = 'idle';
          run.message = 'Scheduled. Use Generate now for the first episode.';
          state.podcasts[podcast.id] = run;
          changed = true;
          continue;
        }
        const next = nextPodcastRun(
          podcast.schedule,
          podcast.timezone,
          new Date(run.lastRunAt)
        );
        if (!next || next.getTime() > now.getTime()) continue;
        await this.generateEpisode(podcast, state);
        changed = true;
      }
      if (!changed) {
        this.onChanged(await this.buildSnapshot(state));
        return;
      }
      await this.saveState(state);
      await this.notify();
    });
  }

  private async checkSources(
    podcast: ParsedPodcast,
    state: PodcastState,
    force: boolean
  ): Promise<boolean> {
    let changed = false;
    for (const source of podcast.sources) {
      const current = state.sources[source] ?? { seen: [], items: [] };
      const lastChecked = Date.parse(current.lastCheckedAt ?? '');
      if (
        !force &&
        Number.isFinite(lastChecked) &&
        Date.now() - lastChecked < sourceCheckIntervalMilliseconds
      ) {
        continue;
      }
      const run = state.podcasts[podcast.id] ?? { consumed: [] };
      state.sources[source] = current;
      run.status = 'checking';
      run.message = `Checking ${source}`;
      state.podcasts[podcast.id] = run;
      await this.saveState(state);
      this.onChanged(await this.buildSnapshot(state));
      try {
        changed = true;
        const discovered = await this.extraction.discoverSource(source);
        const seen = new Set(current.seen);
        const unseen = discovered.items.filter((item) => !seen.has(item.id));
        const selected = unseen;
        let finishIngestion: FinishIngestion | null = null;
        if (selected.length) finishIngestion = this.onIngestionStarted();
        try {
          for (const item of selected.reverse()) {
            const ingested = await this.ingestItem(item);
            current.items.unshift(ingested);
            current.seen.unshift(item.id);
            current.seen = [...new Set(current.seen)];
            changed = true;
          }
        } finally {
          finishIngestion?.();
        }
        current.title = discovered.title;
        current.kind = discovered.kind;
        current.error = undefined;
        current.lastCheckedAt = new Date().toISOString();
      } catch (error) {
        current.error =
          error instanceof Error ? error.message : 'The source could not be checked.';
        current.lastCheckedAt = new Date().toISOString();
      }
      state.sources[source] = current;
    }
    const run = state.podcasts[podcast.id] ?? { consumed: [] };
    if (run.status === 'checking') {
      const errors = podcast.sources
        .map((source) => state.sources[source]?.error)
        .filter(Boolean);
      run.status = errors.length ? 'error' : 'idle';
      run.message = errors.length
        ? `${errors.length} ${errors.length === 1 ? 'source needs' : 'sources need'} attention.`
        : 'Sources are up to date.';
      state.podcasts[podcast.id] = run;
    }
    if (changed) {
      await this.onLibraryChanged();
      this.onSyncRequested('watched sources');
    }
    return changed;
  }

  private async ingestItem(item: DiscoveredSourceItem): Promise<WatchedItem> {
    const extracted = await this.extraction.extractURL(item.url);
    const { audio: _audio, ...stored } = extracted;
    const captureID = await this.library.captureText(item.url, {
      ...stored,
      title: item.title || extracted.title,
      entryType: 'podcast_source'
    });
    const entryID = `personal:${captureID}`;
    return {
      ...item,
      entryID,
      ingestedAt: new Date().toISOString()
    };
  }

  private async markAgentAudioPending(podcast: ParsedPodcast): Promise<void> {
    const state = await this.readState();
    const run = state.podcasts[podcast.id] ?? { consumed: [] };
    run.lastRunAt = new Date().toISOString();
    run.status = 'generating';
    run.message = 'Episode saved. Generating audio…';
    state.podcasts[podcast.id] = run;
    await this.saveState(state);
    this.onChanged(await this.buildSnapshot(state));
  }

  private queueAgentAudio(
    podcast: ParsedPodcast,
    entryID: string,
    script: string,
    sourceCount: number
  ): void {
    void this.enqueue(async () => {
      const state = await this.readState();
      const run = state.podcasts[podcast.id] ?? { consumed: [] };
      try {
        await this.library.attachPodcastAudio(
          entryID,
          await this.generateAudio(spokenText(script))
        );
        run.status = 'ready';
        run.message = `Episode ready from ${sourceCount} ${
          sourceCount === 1 ? 'source' : 'sources'
        }.`;
        await this.onLibraryChanged();
        this.onSyncRequested('agent podcast episode audio');
        this.onOperationMessage('An agent-created podcast episode is ready.', entryID);
      } catch (error) {
        run.status = 'error';
        run.message = `Episode saved without audio: ${
          error instanceof Error ? error.message : 'audio generation failed'
        }`;
      }
      state.podcasts[podcast.id] = run;
      await this.saveState(state);
      await this.notify();
    });
  }

  private async generateEpisode(
    podcast: ParsedPodcast,
    state: PodcastState
  ): Promise<void> {
    const run = state.podcasts[podcast.id] ?? { consumed: [] };
    const consumed = new Set(run.consumed);
    const pending = podcast.sources
      .flatMap((source) =>
        (state.sources[source]?.items ?? []).map((item) => ({
          key: itemKey(source, item.id),
          source,
          item
        }))
      )
      .filter(({ key }) => !consumed.has(key))
      .sort((left, right) =>
        (right.item.publishedAt ?? right.item.ingestedAt).localeCompare(
          left.item.publishedAt ?? left.item.ingestedAt
        )
      );
    run.lastRunAt = new Date().toISOString();
    if (!pending.length) {
      run.status = 'idle';
      run.message = 'No new source items; the episode was skipped.';
      state.podcasts[podcast.id] = run;
      return;
    }

    run.status = 'generating';
    run.message = `Writing an episode from ${pending.length} new ${
      pending.length === 1 ? 'item' : 'items'
    }…`;
    state.podcasts[podcast.id] = run;
    await this.saveState(state);
    this.onChanged(await this.buildSnapshot(state));

    try {
      const entries = new Map(
        (await this.library.snapshot()).entries.map((entry) => [entry.id, entry])
      );
      const selected = [];
      const packets = [];
      let characterCount = 0;
      for (const candidate of pending) {
        const entry = entries.get(candidate.item.entryID);
        if (!entry) continue;
        const variant = entry.availableVariants.includes('concise')
          ? 'concise'
          : entry.availableVariants.includes('brief')
            ? 'brief'
            : 'source';
        const text = await this.library.readText(entry.id, variant);
        const packet = [
          `SOURCE_ID: ${selected.length + 1}`,
          `TITLE: ${entry.title}`,
          `URL: ${candidate.item.url}`,
          `PUBLISHED: ${candidate.item.publishedAt ?? 'unknown'}`,
          'CONTENT:',
          text
        ].join('\n');
        if (
          packets.length &&
          characterCount + packet.length > maximumEpisodeInputCharacters
        ) break;
        packets.push(packet.slice(0, maximumEpisodeInputCharacters - characterCount));
        characterCount += packet.length;
        selected.push(candidate);
      }
      if (!selected.length) throw new Error('The new source items are unavailable.');
      const script = await runAIText(
        renderPodcastPrompt(await this.promptTemplate(), podcast, packets),
        await this.processingCommand(),
        this.managedAIRunner
      );
      if (!script) throw new Error('The AI command returned an empty podcast episode.');
      const title =
        /^#\s+(.+)$/m.exec(script)?.[1]?.trim() ||
        `${podcast.title} — ${new Date().toLocaleDateString('en-CA')}`;
      const sources = selected.map(({ item }) => item.url);
      const sourceList = selected
        .map(
          ({ item }, index) =>
            `${index + 1}. [${escapeLinkText(item.title)}](${item.url})`
        )
        .join('\n');
      const entryID = await this.library.capturePodcastEpisode({
        podcastID: podcast.id,
        podcastTitle: podcast.title,
        title,
        body: `${script.trim()}\n\n## Sources\n\n${sourceList}`,
        sources,
        sourceIDs: selected.map(({ item }) => item.entryID)
      });
      for (const { key } of selected) consumed.add(key);
      const activeKeys = new Set(
        podcast.sources.flatMap((source) =>
          (state.sources[source]?.items ?? []).map((item) => itemKey(source, item.id))
        )
      );
      run.consumed = [...consumed].filter((key) => activeKeys.has(key));
      run.message = 'Episode saved. Generating audio…';
      state.podcasts[podcast.id] = run;
      await this.saveState(state);
      await this.onLibraryChanged();
      this.onSyncRequested('podcast episode script');
      this.onChanged(await this.buildSnapshot(state));
      await this.library.attachPodcastAudio(
        entryID,
        await this.generateAudio(spokenText(script))
      );
      run.status = 'ready';
      run.message = `Episode ready from ${selected.length} ${
        selected.length === 1 ? 'source' : 'sources'
      }.`;
      await this.onLibraryChanged();
      this.onSyncRequested('podcast episode audio');
      this.onOperationMessage('A scheduled podcast episode is ready.', entryID);
    } catch (error) {
      run.status = 'error';
      run.message =
        error instanceof Error ? error.message : 'The podcast episode could not be written.';
    }
    state.podcasts[podcast.id] = run;
  }

  private async buildSnapshot(
    providedState?: PodcastState
  ): Promise<PodcastSnapshot> {
    await this.ensureDirectory();
    const [podcasts, state] = await Promise.all([
      this.readDefinitions(),
      providedState ? Promise.resolve(providedState) : this.readState()
    ]);
    const library = await this.library.markPodcastSources(
      Object.values(state.sources).flatMap((source) =>
        source.items.map((item) => item.entryID)
      )
    );
    const now = new Date();
    return {
      generatedAt: now.toISOString(),
      maximumPodcasts,
      podcasts: podcasts.map((podcast) => {
        const run = state.podcasts[podcast.id] ?? { consumed: [] };
        const checks = podcast.sources
          .map((source) => state.sources[source]?.lastCheckedAt)
          .filter((value): value is string => Boolean(value))
          .sort();
        return {
          id: podcast.id,
          filename: podcast.filename,
          title: podcast.title,
          prompt: podcast.prompt,
          schedule: podcast.schedule,
          length: podcast.length,
          sources: podcast.sources,
          nextRunAt:
            !podcast.error
              ? nextPodcastRun(
                  podcast.schedule,
                  podcast.timezone,
                  new Date(run.lastRunAt ?? now)
                )?.toISOString()
              : undefined,
          lastRunAt: run.lastRunAt,
          lastCheckedAt: checks.at(-1),
          status: podcast.error ? 'error' : (run.status ?? 'idle'),
          message: podcast.error ?? run.message ?? 'Ready.',
          episodes: library.entries.filter(
            (entry) =>
              entry.entryType === 'podcast_episode' &&
              entry.podcastID === podcast.id
          ),
          sourceStatuses: podcast.sources.map((source) => ({
            source,
            title: state.sources[source]?.title,
            kind: state.sources[source]?.kind,
            lastCheckedAt: state.sources[source]?.lastCheckedAt,
            itemCount: state.sources[source]?.items.length ?? 0,
            error: state.sources[source]?.error
          }))
        };
      })
    };
  }

  private async notify(): Promise<PodcastSnapshot> {
    const snapshot = await this.buildSnapshot();
    this.onChanged(snapshot);
    return snapshot;
  }

  private async requirePodcast(id: string): Promise<ParsedPodcast> {
    const podcast = (await this.readDefinitions()).find(
      (candidate) => candidate.id === id
    );
    if (!podcast) throw new Error('The selected podcast no longer exists.');
    if (podcast.error) throw new Error(podcast.error);
    return podcast;
  }

  private async readDefinitions(): Promise<ParsedPodcast[]> {
    await this.ensureDirectory();
    const entries = await readdir(join(this.workspacePath(), 'podcasts'), {
      withFileTypes: true
    });
    const files = entries
      .filter(
        (entry) =>
          entry.isFile() &&
          entry.name.toLowerCase().endsWith('.md') &&
          entry.name.toLowerCase() !== 'readme.md' &&
          !entry.name.startsWith('_')
      )
      .map((entry) => entry.name)
      .sort();
    return Promise.all(
      files.map(async (filename) => {
        try {
          return parsePodcast(await readFile(
            join(this.workspacePath(), 'podcasts', filename),
            'utf8'
          ), filename);
        } catch (error) {
          return {
            id: `invalid:${filename}`,
            filename,
            title: basename(filename, '.md').replaceAll('-', ' '),
            prompt: defaultPodcastPrompt,
            schedule: 'manual',
            timezone: Intl.DateTimeFormat().resolvedOptions().timeZone || 'UTC',
            length: '',
            sources: [],
            error:
              error instanceof Error ? error.message : 'This podcast file is invalid.'
          };
        }
      })
    );
  }

  private async ensureDirectory(): Promise<void> {
    const directory = join(this.workspacePath(), 'podcasts');
    await mkdir(directory, { recursive: true });
    const readme = join(directory, 'README.md');
    try {
      await readFile(readme, 'utf8');
    } catch {
      await atomicWrite(readme, podcastReadme);
    }
  }

  private async readState(): Promise<PodcastState> {
    try {
      const value = JSON.parse(
        await readFile(this.statePath(), 'utf8')
      ) as Partial<PodcastState>;
      if (
        value.schemaVersion === 1 &&
        value.sources &&
        typeof value.sources === 'object' &&
        value.podcasts &&
        typeof value.podcasts === 'object'
      ) {
        return value as PodcastState;
      }
    } catch {
      // New workspaces start with an empty rebuildable watcher state.
    }
    return { schemaVersion: 1, sources: {}, podcasts: {} };
  }

  private saveState(state: PodcastState): Promise<void> {
    return atomicWrite(this.statePath(), `${JSON.stringify(state, null, 2)}\n`);
  }

  private statePath(): string {
    return join(this.workspacePath(), '.shared-library', 'podcast-state.json');
  }
}

export function parsePodcast(text: string, filename = 'podcast.md'): ParsedPodcast {
  const parsed = parseMarkdown(text);
  const metadata = parsed.metadata;
  const title =
    stringValue(metadata.name) ||
    stringValue(metadata.title) ||
    basename(filename, '.md').replaceAll('-', ' ');
  const id = stringValue(metadata.id) || `file:${filename}`;
  return {
    ...normalizeDraft({
      id,
      title,
      prompt: parsed.body.trim() || defaultPodcastPrompt,
      schedule: stringValue(metadata.schedule) || 'manual',
      length: stringValue(metadata.length),
      sources: arrayValue(metadata.sources)
    }),
    id,
    filename,
    timezone: Intl.DateTimeFormat().resolvedOptions().timeZone || 'UTC'
  };
}

export function nextPodcastRun(
  scheduleValue: string,
  timezone: string,
  after: Date
): Date | null {
  const schedule = parseSchedule(scheduleValue);
  if (schedule.kind === 'manual') return null;
  const formatter = new Intl.DateTimeFormat('en-CA', {
    timeZone: timezone,
    weekday: 'short',
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
    hour: '2-digit',
    minute: '2-digit',
    hourCycle: 'h23'
  });
  const start = Math.floor(after.getTime() / 60_000) * 60_000 + 60_000;
  // ponytail: scan at minute resolution; replace with Temporal when it is
  // universally available in supported Electron runtimes.
  for (let offset = 0; offset <= 8 * 24 * 60; offset += 1) {
    const candidate = new Date(start + offset * 60_000);
    const parts = Object.fromEntries(
      formatter.formatToParts(candidate).map((part) => [part.type, part.value])
    );
    if (schedule.kind === 'hourly') {
      if (parts.minute === schedule.minute) return candidate;
      continue;
    }
    if (
      parts.hour === schedule.hour &&
      parts.minute === schedule.minute &&
      (schedule.kind === 'daily' ||
        parts.weekday?.toLowerCase().startsWith(schedule.weekday))
    ) {
      return candidate;
    }
  }
  throw new Error(`Could not calculate the next run in ${timezone}.`);
}

function parseSchedule(value: string):
  | { kind: 'manual' }
  | { kind: 'hourly'; minute: string }
  | { kind: 'daily'; hour: string; minute: string }
  | { kind: 'weekly'; weekday: string; hour: string; minute: string } {
  const normalized = value.trim().toLowerCase().replace(/\s+/g, ' ');
  if (normalized === 'manual') return { kind: 'manual' };
  const hourly = /^hourly(?:\s+at)?\s+:(\d{2})$/.exec(normalized);
  if (hourly && Number(hourly[1]) < 60) {
    return { kind: 'hourly', minute: hourly[1] };
  }
  const daily = /^daily(?:\s+at)?\s+(\d{1,2}):(\d{2})$/.exec(normalized);
  if (daily && Number(daily[1]) < 24 && Number(daily[2]) < 60) {
    return {
      kind: 'daily',
      hour: daily[1].padStart(2, '0'),
      minute: daily[2]
    };
  }
  const weekly =
    /^weekly\s+(mon|tue|wed|thu|fri|sat|sun)(?:day)?(?:\s+at)?\s+(\d{1,2}):(\d{2})$/.exec(
      normalized
    );
  if (weekly && Number(weekly[2]) < 24 && Number(weekly[3]) < 60) {
    return {
      kind: 'weekly',
      weekday: weekly[1],
      hour: weekly[2].padStart(2, '0'),
      minute: weekly[3]
    };
  }
  throw new Error(
    'Schedule must be manual, hourly :MM, daily HH:MM, or weekly MON HH:MM.'
  );
}

function normalizeDraft(value: PodcastDraft): PodcastDraft {
  const title = value.title.trim().replace(/\s+/g, ' ');
  if (!title || title.length > 120) {
    throw new Error('Podcast titles must contain 1–120 characters.');
  }
  const schedule = value.schedule.trim() || 'manual';
  parseSchedule(schedule);
  const length = value.length.trim();
  if (length.length > 120) {
    throw new Error('The length instruction must be 120 characters or fewer.');
  }
  const sources = [...new Set(value.sources.map((source) => source.trim()).filter(Boolean))];
  const prompt = value.prompt.trim();
  if (!prompt) throw new Error('The podcast prompt cannot be empty.');
  if (prompt.length > 50_000) {
    throw new Error('The podcast prompt must be 50,000 characters or fewer.');
  }
  const presentPlaceholders = podcastPromptPlaceholders.filter((placeholder) =>
    prompt.includes(placeholder)
  );
  const missingPlaceholder = podcastPromptPlaceholders.find(
    (placeholder) => !prompt.includes(placeholder)
  );
  if (presentPlaceholders.length && missingPlaceholder) {
    throw new Error(`The podcast prompt must include ${missingPlaceholder}.`);
  }
  if (!sources.length) throw new Error('Add at least one podcast source.');
  if (sources.length > maximumSourcesPerPodcast) {
    throw new Error(`A podcast can watch up to ${maximumSourcesPerPodcast} sources.`);
  }
  for (const source of sources) {
    if (source.length > 2_048) throw new Error('Podcast source URLs are too long.');
    if (!/^https?:\/\//iu.test(source) && !/^arxiv:\S/iu.test(source)) {
      throw new Error(`Invalid podcast source: ${source}`);
    }
  }
  return {
    id: value.id,
    title,
    prompt,
    schedule,
    length,
    sources
  };
}

function serializePodcast(value: PodcastDraft & { id: string }): string {
  const lines = [
    '---',
    ...(value.id.startsWith('file:') ? [] : [`id: ${JSON.stringify(value.id)}`]),
    `name: ${JSON.stringify(value.title)}`,
    `schedule: ${JSON.stringify(value.schedule)}`,
    'sources:',
    ...value.sources.map((source) => `  - ${JSON.stringify(source)}`),
    ...(value.length ? [`length: ${JSON.stringify(value.length)}`] : []),
    '---',
    '',
    value.prompt.trim(),
    ''
  ];
  return lines.join('\n');
}

function availablePodcastFilename(base: string, used: Set<string>): string {
  let filename = `${base}.md`;
  for (let suffix = 2; used.has(filename); suffix += 1) {
    filename = `${base}-${suffix}.md`;
  }
  return filename;
}

export function renderPodcastPrompt(
  template: string,
  podcast: { title: string; length: string; prompt?: string },
  packets: string[]
): string {
  const specific = podcast.prompt?.trim() ?? '';
  const usesSpecificTemplate = podcastPromptPlaceholders.some((placeholder) =>
    specific.includes(placeholder)
  );
  const selectedTemplate = usesSpecificTemplate ? specific : template;
  const missing = podcastPromptPlaceholders.find(
    (placeholder) => !selectedTemplate.includes(placeholder)
  );
  if (missing) throw new Error(`The podcast prompt must include ${missing}.`);
  const rendered = selectedTemplate
    .trim()
    .replaceAll('{{podcast_title}}', JSON.stringify(podcast.title))
    .replaceAll(
      '{{requested_length}}',
      JSON.stringify(
        podcast.length || 'Use the natural length for the available material.'
      )
    )
    .replaceAll(
      '{{source_packets}}',
      packets.map((packet) => `\n<source>\n${packet}\n</source>`).join('\n')
    );
  return specific && !usesSpecificTemplate
    ? `Podcast-specific instructions:\n${specific}\n\n${rendered}`
    : rendered;
}

function normalizeAgentEpisodeSources(values: AgentEpisodeSource[]): AgentEpisodeSource[] {
  if (!Array.isArray(values) || !values.length) {
    throw new Error('Add at least one episode source.');
  }
  const sources = values.map((value) => {
    const url = value.url?.trim();
    if (!url || url.length > 4_096) throw new Error('Episode sources need valid web URLs.');
    const parsed = new URL(url);
    if (
      !['http:', 'https:'].includes(parsed.protocol) ||
      parsed.username ||
      parsed.password
    ) {
      throw new Error(`Invalid episode source: ${url}`);
    }
    parsed.hash = '';
    const title = value.title?.trim();
    const content = value.content?.trim();
    if (title && title.length > 500) throw new Error('Episode source titles are too long.');
    if (content && content.length > maximumEpisodeInputCharacters) {
      throw new Error('Browser-captured source content is too long.');
    }
    return {
      url: parsed.toString(),
      ...(title ? { title } : {}),
      ...(content ? { content } : {})
    };
  });
  return [
    ...new Map(sources.map((source) => [sourceIdentity(source.url), source])).values()
  ];
}

export function sourceIdentity(value: string): string {
  let url: URL;
  try {
    url = new URL(value);
  } catch {
    return value.trim();
  }
  url.hash = '';
  const host = url.hostname.toLowerCase().replace(/^www\./u, '');
  const parts = url.pathname.split('/').filter(Boolean).map(decodeURIComponent);
  const status = parts.findIndex(
    (part, index) => index > 0 && part.toLowerCase() === 'status'
  );
  if (['x.com', 'twitter.com'].includes(host) && /^\d+$/u.test(parts[status + 1] ?? '')) {
    return `x:status:${parts[status + 1]}`;
  }
  const comments = parts.findIndex((part) => part.toLowerCase() === 'comments');
  if (host.endsWith('reddit.com') && /^[a-z0-9]+$/iu.test(parts[comments + 1] ?? '')) {
    return `reddit:post:${parts[comments + 1].toLowerCase()}`;
  }
  if (host === 'bsky.app' && parts[0] === 'profile' && parts[2] === 'post' && parts[3]) {
    return `bluesky:post:${parts[1]}:${parts[3]}`;
  }
  const youtubeID =
    host === 'youtu.be'
      ? parts[0]
      : host.endsWith('youtube.com')
        ? url.searchParams.get('v')
        : null;
  if (youtubeID) return `youtube:video:${youtubeID}`;
  for (const key of [...url.searchParams.keys()]) {
    if (
      key.toLowerCase().startsWith('utm_') ||
      ['fbclid', 'gclid', 'mc_cid', 'mc_eid'].includes(key.toLowerCase())
    ) {
      url.searchParams.delete(key);
    }
  }
  return url.toString();
}

function sameStrings(left: string[], right: string[]): boolean {
  return left.length === right.length && left.every((value, index) => value === right[index]);
}

function itemKey(source: string, id: string): string {
  return createHash('sha256').update(`${source}\n${id}`).digest('hex');
}

function stringValue(value: string | string[] | undefined): string {
  return typeof value === 'string' ? value : '';
}

function arrayValue(value: string | string[] | undefined): string[] {
  return Array.isArray(value) ? value : value ? [value] : [];
}

function escapeLinkText(value: string): string {
  return value.replaceAll('[', '\\[').replaceAll(']', '\\]');
}

function spokenText(markdown: string): string {
  return markdown
    .replace(/!\[[^\]]*\]\([^)]+\)/gu, '')
    .replace(/\[([^\]]+)\]\([^)]+\)/gu, '$1')
    .replace(/^#{1,6}\s+/gmu, '')
    .replace(/[*_`>~]/gu, '')
    .replace(/\s+/gu, ' ')
    .trim();
}

function slug(value: string): string {
  return (
    value
      .normalize('NFKD')
      .replace(/[\u0300-\u036f]/g, '')
      .toLowerCase()
      .replace(/[^a-z0-9]+/g, '-')
      .replace(/^-|-$/g, '')
      .slice(0, 64) || 'podcast'
  );
}

async function atomicWrite(path: string, text: string): Promise<void> {
  await mkdir(dirname(path), { recursive: true });
  const temporary = `${path}.${randomUUID()}.tmp`;
  await writeFile(temporary, text, 'utf8');
  await rename(temporary, path);
}

const podcastReadme = `# Scheduled podcasts

Each other Markdown file in this folder defines one podcast. Briefly and your
agents can edit the files directly. Add or remove lines under \`sources:\` to
change what a podcast watches. The Markdown body is the podcast-specific prompt.

Recommended: use Codex or another coding agent to set up the podcast. Keep the
schedule \`manual\` when the agent owns the cadence. Briefly extracts feeds and
public pages; the agent can discover exact post links through your signed-in
browser on sites such as Reddit and X.

\`\`\`markdown
---
name: "AI Daily"
schedule: "daily 07:30"
sources:
  - "https://example.com/feed.xml"
  - "https://www.youtube.com/@example"
  - "https://podcasts.apple.com/example/id123456"
  - "arxiv:agent alignment"
length: "about 20 minutes"
---

Connect the most important updates into one practical story. Explain why they
matter instead of reading the source summaries one after another.
\`\`\`

Schedules can be \`manual\`, \`hourly :MM\`, \`daily HH:MM\`, or
\`weekly MON HH:MM\`. Times use the device timezone automatically. The
\`length\` line is optional and is a free-form instruction, not a limit.
`;
