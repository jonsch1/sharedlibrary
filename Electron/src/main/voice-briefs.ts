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
  defaultVoiceBriefPrompt,
  type DesktopLibrarySnapshot,
  type VoiceBriefDefinition,
  type VoiceBriefDraft,
  type VoiceBriefSnapshot
} from '../shared/contracts.js';
import type {
  DiscoveredSource,
  DiscoveredSourceItem
} from './extraction.js';
import type { ChannelWorkflowService } from './channel-workflows.js';
import { sourceIdentity, type ItemService } from './items.js';
import { LibraryService, parseMarkdown } from './library.js';
import {
  defaultProcessingCommand,
  runAIText,
  type ManagedAIRunner
} from './processing.js';

const maximumVoiceBriefs = 20;
const maximumSourcesPerVoiceBrief = 200;
const defaultChannelRetrievalCount = 5;
const maximumChannelRetrievalCount = 100;
const sourceCheckIntervalMilliseconds = 30 * 60 * 1000;
const schedulerIntervalMilliseconds = 60 * 1000;
const maximumEpisodeInputCharacters = 120_000;
const maximumAgentScriptCharacters = 60_000;
const voiceBriefPromptPlaceholders = [
  '{{voice_brief_title}}',
  '{{requested_length}}',
  '{{source_packets}}'
];

export { defaultVoiceBriefPrompt };

export function voiceBriefAudioRange(
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
  retrievalCount?: number;
  canLoadMore?: boolean;
  seen: string[];
  items: WatchedItem[];
}

interface VoiceBriefRunState {
  lastRunAt?: string;
  status?: VoiceBriefDefinition['status'];
  message?: string;
  consumed: string[];
}

interface VoiceBriefState {
  schemaVersion: 1;
  sources: Record<string, SourceState>;
  voiceBriefs: Record<string, VoiceBriefRunState>;
}

interface ParsedVoiceBrief {
  id: string;
  filename: string;
  title: string;
  prompt: string;
  prioritizeForMe: boolean;
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

export class VoiceBriefService {
  private timer: NodeJS.Timeout | null = null;
  private queue: Promise<unknown> = Promise.resolve();

  constructor(
    private readonly workspacePath: () => string,
    private readonly library: LibraryService,
    private readonly channels: Pick<ChannelWorkflowService, 'enumerate'>,
    private readonly items: Pick<ItemService, 'save'>,
    private readonly generateAudio: (text: string) => Promise<Uint8Array>,
    private readonly trash: (path: string) => Promise<void>,
    private readonly onChanged: (snapshot: VoiceBriefSnapshot) => void,
    private readonly onLibraryChanged: () => Promise<void>,
    private readonly onSyncRequested: (reason: string) => void,
    private readonly onOperationMessage: (message: string, entryID?: string) => void,
    private readonly onIngestionStarted: (source: string) => FinishIngestion,
    private readonly promptTemplate: () => Promise<string> = async () =>
      defaultVoiceBriefPrompt,
    private readonly processingCommand: () => Promise<string> = async () =>
      defaultProcessingCommand,
    private readonly managedAIRunner?: ManagedAIRunner,
    private readonly personalContext?: () => Promise<string>
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

  snapshot(): Promise<VoiceBriefSnapshot> {
    return this.enqueue(() => this.buildSnapshot());
  }

  save(value: VoiceBriefDraft): Promise<VoiceBriefSnapshot> {
    return this.enqueue(async () => {
      const voiceBriefs = await this.readDefinitions();
      const draft = normalizeDraft(value);
      const existing = value.id
        ? voiceBriefs.find((voiceBrief) => voiceBrief.id === value.id)
        : undefined;
      if (!existing && voiceBriefs.length >= maximumVoiceBriefs) {
        throw new Error(`A workspace can contain up to ${maximumVoiceBriefs} voice briefs.`);
      }
      const filename =
        existing?.filename ??
        availableVoiceBriefFilename(
          slug(draft.title),
          new Set(voiceBriefs.map((voiceBrief) => voiceBrief.filename))
        );
      const id = existing?.id ?? `file:${filename}`;
      const path = join(this.workspacePath(), 'voice-briefs', filename);
      await atomicWrite(path, serializeVoiceBrief({ ...draft, id }));
      this.onSyncRequested('voice brief settings');
      return this.notify();
    });
  }

  remove(id: string): Promise<VoiceBriefSnapshot> {
    return this.enqueue(async () => {
      const voiceBrief = await this.requireVoiceBrief(id);
      await this.trash(join(this.workspacePath(), 'voice-briefs', voiceBrief.filename));
      const state = await this.readState();
      delete state.voiceBriefs[id];
      await this.saveState(state);
      this.onSyncRequested('deleted voice brief settings');
      return this.notify();
    });
  }

  addChannel(sourceValue: string): Promise<VoiceBriefSnapshot> {
    return this.enqueue(async () => {
      const source = normalizeChannelSource(sourceValue);
      const state = await this.readState();
      state.sources[source] ??= {
        retrievalCount: defaultChannelRetrievalCount,
        seen: [],
        items: []
      };
      await this.saveState(state);
      this.onSyncRequested('added channel');
      return this.notify();
    });
  }

  checkChannel(sourceValue: string): Promise<VoiceBriefSnapshot> {
    return this.enqueue(async () => {
      const source = normalizeChannelSource(sourceValue);
      const state = await this.readState();
      const owner = (await this.readDefinitions()).find((voiceBrief) =>
        voiceBrief.sources.includes(source)
      );
      if (!owner && !state.sources[source]) {
        throw new Error('The selected channel no longer exists.');
      }
      await this.checkSources(
        { id: owner?.id ?? '', sources: [source] },
        state,
        true,
        Boolean(owner)
      );
      await this.saveState(state);
      return this.notify();
    });
  }

  updateChannel(
    sourceValue: string,
    retrievalCountValue: number
  ): Promise<VoiceBriefSnapshot> {
    return this.enqueue(async () => {
      const source = normalizeChannelSource(sourceValue);
      const state = await this.readState();
      const exists =
        state.sources[source] ||
        (await this.readDefinitions()).some((voiceBrief) =>
          voiceBrief.sources.includes(source)
        );
      if (!exists) throw new Error('The selected channel no longer exists.');
      const current = state.sources[source] ??= { seen: [], items: [] };
      current.retrievalCount = normalizeChannelRetrievalCount(retrievalCountValue);
      await this.saveState(state);
      this.onSyncRequested('channel settings');
      return this.notify();
    });
  }

  loadMoreChannel(sourceValue: string): Promise<VoiceBriefSnapshot> {
    return this.enqueue(async () => {
      const source = normalizeChannelSource(sourceValue);
      const state = await this.readState();
      const owner = (await this.readDefinitions()).find((voiceBrief) =>
        voiceBrief.sources.includes(source)
      );
      const current = state.sources[source];
      if (!owner && !current) {
        throw new Error('The selected channel no longer exists.');
      }
      const retrievalCount =
        current?.retrievalCount ?? defaultChannelRetrievalCount;
      // ponytail: widen the recent window to 100; add provider cursors for deeper history.
      await this.checkSources(
        { id: owner?.id ?? '', sources: [source] },
        state,
        true,
        Boolean(owner),
        Math.min(
          maximumChannelRetrievalCount,
          (current?.items.length ?? 0) + retrievalCount
        )
      );
      await this.saveState(state);
      return this.notify();
    });
  }

  removeChannel(sourceValue: string): Promise<VoiceBriefSnapshot> {
    return this.enqueue(async () => {
      const source = normalizeChannelSource(sourceValue);
      const voiceBriefs = await this.readDefinitions();
      const owners = voiceBriefs.filter((voiceBrief) => voiceBrief.sources.includes(source));
      const state = await this.readState();
      if (!owners.length && !state.sources[source]) {
        throw new Error('The selected channel no longer exists.');
      }
      await Promise.all(
        owners.map((voiceBrief) =>
          atomicWrite(
            join(this.workspacePath(), 'voice-briefs', voiceBrief.filename),
            serializeVoiceBrief({
              ...voiceBrief,
              sources: voiceBrief.sources.filter((candidate) => candidate !== source)
            })
          )
        )
      );
      const channelKeys = new Set(
        (state.sources[source]?.items ?? []).map((item) => itemKey(source, item.id))
      );
      const channelEntryIDs =
        state.sources[source]?.items.map((item) => item.entryID) ?? [];
      const { snapshot: library } =
        await this.library.markVoiceBriefSources(channelEntryIDs);
      delete state.sources[source];
      for (const run of Object.values(state.voiceBriefs)) {
        run.consumed = run.consumed.filter((key) => !channelKeys.has(key));
      }
      await this.trashUnreferencedChannelEntries(channelEntryIDs, state, library);
      await this.saveState(state);
      await this.onLibraryChanged();
      this.onSyncRequested('deleted channel');
      return this.notify();
    });
  }

  forgetItem(entryID: string): Promise<VoiceBriefSnapshot> {
    return this.enqueue(async () => {
      const state = await this.readState();
      const removedKeys = new Set<string>();
      for (const [source, current] of Object.entries(state.sources)) {
        const removed = current.items.filter((item) => item.entryID === entryID);
        if (!removed.length) continue;
        current.items = current.items.filter((item) => item.entryID !== entryID);
        const removedIDs = new Set(removed.map((item) => item.id));
        current.seen = current.seen.filter((id) => !removedIDs.has(id));
        for (const item of removed) removedKeys.add(itemKey(source, item.id));
      }
      if (removedKeys.size) {
        for (const run of Object.values(state.voiceBriefs)) {
          run.consumed = run.consumed.filter((key) => !removedKeys.has(key));
        }
        await this.saveState(state);
      }
      return this.notify();
    });
  }

  check(id: string): Promise<VoiceBriefSnapshot> {
    return this.enqueue(async () => {
      const voiceBrief = await this.requireVoiceBrief(id);
      const state = await this.readState();
      await this.checkSources(voiceBrief, state, true);
      await this.saveState(state);
      return this.notify();
    });
  }

  run(id: string): Promise<VoiceBriefSnapshot> {
    return this.enqueue(async () => {
      const voiceBrief = await this.requireVoiceBrief(id);
      const state = await this.readState();
      if (
        !voiceBrief.sources.every((source) => state.sources[source]?.lastCheckedAt)
      ) {
        throw new Error('Check the channels before generating this voice brief.');
      }
      await this.generateEpisode(voiceBrief, state);
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
        `Voice brief scripts must contain 1–${maximumAgentScriptCharacters.toLocaleString()} characters.`
      );
    }
    const sources = normalizeAgentEpisodeSources(sourceValues);
    return this.enqueue(async () => {
      const voiceBrief = await this.requireVoiceBrief(id);
      const library = await this.library.snapshot();
      const sourceKeys = sources.map(({ url }) => sourceIdentity(url)).sort();
      const duplicate = library.entries.find(
        (entry) =>
          entry.entryType === 'voice_brief_episode' &&
          entry.voiceBriefID === voiceBrief.id &&
          sameStrings(
            (entry.sourceURLs ?? []).map(sourceIdentity).sort(),
            sourceKeys
          )
      );
      if (duplicate) {
        if (!duplicate.hasAudio) {
          await this.markAgentAudioPending(voiceBrief);
          this.queueAgentAudio(voiceBrief, duplicate.id, script, sources.length);
        }
        return {
          entryID: duplicate.id,
          duplicate: true,
          audioPending: !duplicate.hasAudio
        };
      }
      const selected: Array<{ entryID: string; title: string; url: string }> = [];
      for (const source of sources) {
        const saved = await this.items.save(source.url, {
          entryType: 'voice_brief_source',
          extracted: source.content
            ? {
                title: source.title,
                content: source.content,
                sourceURL: source.url
              }
            : undefined,
          discovered: {
            id: sourceIdentity(source.url),
            title: source.title || source.url,
            url: source.url,
            publishedAt: null
          },
          syncReason: 'agent voice brief source'
        });
        selected.push({
          entryID: saved.entryID,
          title: source.title || saved.title,
          url: saved.sourceURL || source.url
        });
      }

      const title =
        /^#\s+(.+)$/m.exec(script)?.[1]?.trim() ||
        `${voiceBrief.title} — ${new Date().toLocaleDateString('en-CA')}`;
      const sourceList = selected
        .map(
          (source, index) =>
            `${index + 1}. [${escapeLinkText(source.title)}](${source.url})`
        )
        .join('\n');
      const entryID = await this.library.captureVoiceBriefEpisode({
        voiceBriefID: voiceBrief.id,
        voiceBriefTitle: voiceBrief.title,
        title,
        body: `${script}\n\n## Sources\n\n${sourceList}`,
        sources: selected.map(({ url }) => url),
        sourceIDs: selected.map(({ entryID }) => entryID)
      });
      await this.markAgentAudioPending(voiceBrief);
      await this.onLibraryChanged();
      this.onSyncRequested('agent voice brief episode script');
      this.queueAgentAudio(voiceBrief, entryID, script, selected.length);
      return { entryID, duplicate: false, audioPending: true };
    });
  }

  async filePath(id: string): Promise<string> {
    const voiceBrief = await this.requireVoiceBrief(id);
    return join(this.workspacePath(), 'voice-briefs', voiceBrief.filename);
  }

  private enqueue<T>(work: () => Promise<T>): Promise<T> {
    const result = this.queue.then(work, work);
    this.queue = result.then(() => undefined, () => undefined);
    return result;
  }

  private async tick(): Promise<void> {
    await this.enqueue(async () => {
      const voiceBriefs = await this.readDefinitions();
      const state = await this.readState();
      let changed = false;
      for (const voiceBrief of voiceBriefs.filter((candidate) => !candidate.error)) {
        changed = (await this.checkSources(voiceBrief, state, false)) || changed;
      }
      const now = new Date();
      for (const voiceBrief of voiceBriefs.filter((candidate) => !candidate.error)) {
        const run = state.voiceBriefs[voiceBrief.id] ?? { consumed: [] };
        if (!run.lastRunAt) {
          run.lastRunAt = now.toISOString();
          run.status = 'idle';
          run.message = 'Scheduled. Generate the first voice brief when ready.';
          state.voiceBriefs[voiceBrief.id] = run;
          changed = true;
          continue;
        }
        const next = nextVoiceBriefRun(
          voiceBrief.schedule,
          voiceBrief.timezone,
          new Date(run.lastRunAt)
        );
        if (!next || next.getTime() > now.getTime()) continue;
        await this.generateEpisode(voiceBrief, state);
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
    voiceBrief: Pick<ParsedVoiceBrief, 'id' | 'sources'>,
    state: VoiceBriefState,
    force: boolean,
    updateRun = true,
    retrievalLimit?: number
  ): Promise<boolean> {
    let changed = false;
    const markedLibrary = await this.library.markVoiceBriefSources(
      Object.values(state.sources).flatMap((source) =>
        source.items.map((item) => item.entryID)
      )
    );
    const library = markedLibrary.snapshot;
    if (markedLibrary.changed) this.onSyncRequested('channel provenance');
    const availableEntryIDs = new Set(
      library.entries.map((entry) => entry.id)
    );
    for (const source of voiceBrief.sources) {
      const current = state.sources[source] ?? { seen: [], items: [] };
      state.sources[source] = current;
      const missingItemIDs = new Set(
        current.items
          .filter((item) => !availableEntryIDs.has(item.entryID))
          .map((item) => item.id)
      );
      if (missingItemIDs.size) {
        current.items = current.items.filter((item) =>
          availableEntryIDs.has(item.entryID)
        );
        current.seen = current.seen.filter((id) => !missingItemIDs.has(id));
        changed = true;
      }
      changed = (await this.pruneChannelItems(source, state, library)) || changed;
      const lastChecked = Date.parse(current.lastCheckedAt ?? '');
      if (
        !force &&
        Number.isFinite(lastChecked) &&
        Date.now() - lastChecked < sourceCheckIntervalMilliseconds
      ) {
        continue;
      }
      const run = state.voiceBriefs[voiceBrief.id] ?? { consumed: [] };
      if (updateRun) {
        run.status = 'checking';
        run.message = `Checking ${source}`;
        state.voiceBriefs[voiceBrief.id] = run;
        await this.saveState(state);
        this.onChanged(await this.buildSnapshot(state));
      }
      try {
        changed = true;
        const limit =
          retrievalLimit ??
          current.retrievalCount ??
          defaultChannelRetrievalCount;
        const discovered = await this.channels.enumerate(source, limit);
        const discoveredItems = discovered.items.slice(0, limit);
        current.canLoadMore =
          discoveredItems.length >= limit &&
          limit < maximumChannelRetrievalCount;
        const seen = new Set(current.seen);
        const unseen = discoveredItems.filter((item) => !seen.has(item.id));
        const selected = unseen;
        let finishIngestion: FinishIngestion | null = null;
        if (selected.length) finishIngestion = this.onIngestionStarted(source);
        try {
          for (const item of selected.reverse()) {
            const ingested = await this.ingestItem(item);
            const replacedIDs = new Set(
              current.items
                .filter(
                  (existing) =>
                    sourceIdentity(existing.url) === sourceIdentity(ingested.url)
                )
                .map((existing) => existing.id)
            );
            current.items = current.items.filter(
              (existing) =>
                sourceIdentity(existing.url) !== sourceIdentity(ingested.url)
            );
            current.seen = current.seen.filter((id) => !replacedIDs.has(id));
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
          error instanceof Error ? error.message : 'The channel could not be checked.';
        current.lastCheckedAt = new Date().toISOString();
      }
      state.sources[source] = current;
      changed = (await this.pruneChannelItems(source, state, library)) || changed;
    }
    if (updateRun) {
      const run = state.voiceBriefs[voiceBrief.id] ?? { consumed: [] };
      if (run.status === 'checking') {
        const errors = voiceBrief.sources
          .map((source) => state.sources[source]?.error)
          .filter(Boolean);
        run.status = errors.length ? 'error' : 'idle';
        const ready = voiceBrief.sources
          .flatMap((source) =>
            (state.sources[source]?.items ?? []).map((item) =>
              itemKey(source, item.id)
            )
          )
          .filter((key) => !run.consumed.includes(key)).length;
        run.message = errors.length
          ? `${errors.length} ${errors.length === 1 ? 'channel needs' : 'channels need'} attention.`
          : ready
            ? `${ready} gathered ${ready === 1 ? 'item is' : 'items are'} ready to review.`
            : 'Channels checked. No new items to review.';
        state.voiceBriefs[voiceBrief.id] = run;
      }
    }
    return changed;
  }

  private async pruneChannelItems(
    source: string,
    state: VoiceBriefState,
    library: DesktopLibrarySnapshot
  ): Promise<boolean> {
    const current = state.sources[source];
    if (!current || current.items.length <= maximumChannelRetrievalCount) return false;
    const removed = current.items.splice(maximumChannelRetrievalCount);
    const removedKeys = new Set(removed.map((item) => itemKey(source, item.id)));
    for (const run of Object.values(state.voiceBriefs)) {
      run.consumed = run.consumed.filter((key) => !removedKeys.has(key));
    }
    const deleted = await this.trashUnreferencedChannelEntries(
      removed.map((item) => item.entryID),
      state,
      library
    );
    if (deleted) {
      await this.onLibraryChanged();
      this.onSyncRequested('channel retention');
    }
    return true;
  }

  private async trashUnreferencedChannelEntries(
    entryIDs: string[],
    state: VoiceBriefState,
    library: DesktopLibrarySnapshot
  ): Promise<boolean> {
    const activeEntryIDs = new Set(
      Object.values(state.sources).flatMap((channel) =>
        channel.items.map((item) => item.entryID)
      )
    );
    const episodeSourceIDs = new Set(
      library.entries
        .filter(({ entryType }) => entryType === 'voice_brief_episode')
        .flatMap(({ sourceIDs }) => sourceIDs ?? [])
    );
    const entries = new Map(library.entries.map((entry) => [entry.id, entry]));
    let deleted = false;
    for (const entryID of new Set(entryIDs)) {
      if (activeEntryIDs.has(entryID) || episodeSourceIDs.has(entryID)) continue;
      if (entries.get(entryID)?.entryType !== 'voice_brief_source') continue;
      await this.library.trashCapture(entryID);
      deleted = true;
    }
    return deleted;
  }

  private async ingestItem(item: DiscoveredSourceItem): Promise<WatchedItem> {
    const saved = await this.items.save(item.url, {
      discovered: item,
      entryType: 'voice_brief_source',
      syncReason: 'watched source'
    });
    return {
      ...item,
      entryID: saved.entryID,
      ingestedAt: new Date().toISOString()
    };
  }

  private async markAgentAudioPending(voiceBrief: ParsedVoiceBrief): Promise<void> {
    const state = await this.readState();
    const run = state.voiceBriefs[voiceBrief.id] ?? { consumed: [] };
    run.lastRunAt = new Date().toISOString();
    run.status = 'generating';
    run.message = 'Episode saved. Generating audio…';
    state.voiceBriefs[voiceBrief.id] = run;
    await this.saveState(state);
    this.onChanged(await this.buildSnapshot(state));
  }

  private queueAgentAudio(
    voiceBrief: ParsedVoiceBrief,
    entryID: string,
    script: string,
    sourceCount: number
  ): void {
    void this.enqueue(async () => {
      const state = await this.readState();
      const run = state.voiceBriefs[voiceBrief.id] ?? { consumed: [] };
      try {
        await this.library.attachVoiceBriefAudio(
          entryID,
          await this.generateAudio(spokenText(script))
        );
        run.status = 'ready';
        run.message = `Episode ready from ${sourceCount} ${
          sourceCount === 1 ? 'source' : 'sources'
        }.`;
        await this.onLibraryChanged();
        this.onSyncRequested('agent voice brief episode audio');
        this.onOperationMessage('An agent-created voice brief is ready.', entryID);
      } catch (error) {
        run.status = 'error';
        run.message = `Episode saved without audio: ${
          error instanceof Error ? error.message : 'audio generation failed'
        }`;
      }
      state.voiceBriefs[voiceBrief.id] = run;
      await this.saveState(state);
      await this.notify();
    });
  }

  private async generateEpisode(
    voiceBrief: ParsedVoiceBrief,
    state: VoiceBriefState
  ): Promise<void> {
    const run = state.voiceBriefs[voiceBrief.id] ?? { consumed: [] };
    const consumed = new Set(run.consumed);
    const pending = voiceBrief.sources
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
      run.message = 'No new channel items; the episode was skipped.';
      state.voiceBriefs[voiceBrief.id] = run;
      return;
    }

    run.status = 'generating';
    run.message = `Writing an episode from ${pending.length} new ${
      pending.length === 1 ? 'item' : 'items'
    }…`;
    state.voiceBriefs[voiceBrief.id] = run;
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
        renderVoiceBriefPrompt(
          await this.promptTemplate(),
          voiceBrief,
          packets,
          voiceBrief.prioritizeForMe ? (await this.personalContext?.()) ?? '' : ''
        ),
        await this.processingCommand(),
        this.managedAIRunner
      );
      if (!script) throw new Error('The AI command returned an empty voice brief.');
      const title =
        /^#\s+(.+)$/m.exec(script)?.[1]?.trim() ||
        `${voiceBrief.title} — ${new Date().toLocaleDateString('en-CA')}`;
      const sources = selected.map(({ item }) => item.url);
      const sourceList = selected
        .map(
          ({ item }, index) =>
            `${index + 1}. [${escapeLinkText(item.title)}](${item.url})`
        )
        .join('\n');
      const entryID = await this.library.captureVoiceBriefEpisode({
        voiceBriefID: voiceBrief.id,
        voiceBriefTitle: voiceBrief.title,
        title,
        body: `${script.trim()}\n\n## Sources\n\n${sourceList}`,
        sources,
        sourceIDs: selected.map(({ item }) => item.entryID)
      });
      for (const { key } of selected) consumed.add(key);
      const activeKeys = new Set(
        voiceBrief.sources.flatMap((source) =>
          (state.sources[source]?.items ?? []).map((item) => itemKey(source, item.id))
        )
      );
      run.consumed = [...consumed].filter((key) => activeKeys.has(key));
      run.message = 'Episode saved. Generating audio…';
      state.voiceBriefs[voiceBrief.id] = run;
      await this.saveState(state);
      await this.onLibraryChanged();
      this.onSyncRequested('voice brief episode script');
      this.onChanged(await this.buildSnapshot(state));
      await this.library.attachVoiceBriefAudio(
        entryID,
        await this.generateAudio(spokenText(script))
      );
      run.status = 'ready';
      run.message = `Episode ready from ${selected.length} ${
        selected.length === 1 ? 'source' : 'sources'
      }.`;
      await this.onLibraryChanged();
      this.onSyncRequested('voice brief episode audio');
      this.onOperationMessage('A scheduled voice brief is ready.', entryID);
    } catch (error) {
      run.status = 'error';
      run.message =
        error instanceof Error ? error.message : 'The voice brief could not be written.';
    }
    state.voiceBriefs[voiceBrief.id] = run;
  }

  private async buildSnapshot(
    providedState?: VoiceBriefState
  ): Promise<VoiceBriefSnapshot> {
    await this.ensureDirectory();
    const [voiceBriefs, state] = await Promise.all([
      this.readDefinitions(),
      providedState ? Promise.resolve(providedState) : this.readState()
    ]);
    const markedLibrary = await this.library.markVoiceBriefSources(
      Object.values(state.sources).flatMap((source) =>
        source.items.map((item) => item.entryID)
      )
    );
    const library = markedLibrary.snapshot;
    if (markedLibrary.changed) this.onSyncRequested('channel provenance');
    const now = new Date();
    const entries = new Map(library.entries.map((entry) => [entry.id, entry]));
    const channelSources = [
      ...new Set([
        ...Object.keys(state.sources),
        ...voiceBriefs.flatMap((voiceBrief) => voiceBrief.sources)
      ])
    ];
    return {
      generatedAt: now.toISOString(),
      maximumVoiceBriefs,
      channels: channelSources.map((source) => {
        const channel = state.sources[source];
        const items =
          channel?.items.filter((item) => entries.has(item.entryID)) ?? [];
        const owners = voiceBriefs.filter((voiceBrief) =>
          voiceBrief.sources.includes(source)
        );
        const ownerIDs = new Set(owners.map((voiceBrief) => voiceBrief.id));
        const latestBriefAt = library.entries
          .filter(
            (entry) =>
              entry.entryType === 'voice_brief_episode' &&
              Boolean(entry.createdAt) &&
              ownerIDs.has(entry.voiceBriefID ?? '')
          )
          .map((entry) => entry.createdAt!)
          .sort()
          .at(-1);
        return {
          source,
          title: channel?.title,
          kind: channel?.kind,
          lastCheckedAt: channel?.lastCheckedAt,
          itemCount: items.length,
          error: channel?.error,
          retrievalCount:
            channel?.retrievalCount ?? defaultChannelRetrievalCount,
          canLoadMore: channel?.canLoadMore ?? true,
          entryIDs: items.map((item) => item.entryID),
          latestBriefAt,
          newEntryIDs: latestBriefAt
            ? items
                .filter((item) => item.ingestedAt > latestBriefAt)
                .map((item) => item.entryID)
            : [],
          briefIDs: owners.map((voiceBrief) => voiceBrief.id),
          briefTitles: owners.map((voiceBrief) => voiceBrief.title)
        };
      }),
      voiceBriefs: voiceBriefs.map((voiceBrief) => {
        const run = state.voiceBriefs[voiceBrief.id] ?? { consumed: [] };
        const checks = voiceBrief.sources
          .map((source) => state.sources[source]?.lastCheckedAt)
          .filter((value): value is string => Boolean(value))
          .sort();
        return {
          id: voiceBrief.id,
          filename: voiceBrief.filename,
          title: voiceBrief.title,
          prompt: voiceBrief.prompt,
          prioritizeForMe: voiceBrief.prioritizeForMe,
          schedule: voiceBrief.schedule,
          length: voiceBrief.length,
          sources: voiceBrief.sources,
          nextRunAt:
            !voiceBrief.error
              ? nextVoiceBriefRun(
                  voiceBrief.schedule,
                  voiceBrief.timezone,
                  new Date(run.lastRunAt ?? now)
                )?.toISOString()
              : undefined,
          lastRunAt: run.lastRunAt,
          lastCheckedAt: checks.at(-1),
          status: voiceBrief.error ? 'error' : (run.status ?? 'idle'),
          message: voiceBrief.error ?? run.message ?? 'Ready.',
          episodes: library.entries.filter(
            (entry) =>
              entry.entryType === 'voice_brief_episode' &&
              entry.voiceBriefID === voiceBrief.id
          ),
          sourceStatuses: voiceBrief.sources.map((source) => {
            const items = (state.sources[source]?.items ?? []).filter((item) =>
              entries.has(item.entryID)
            );
            return {
              source,
              title: state.sources[source]?.title,
              kind: state.sources[source]?.kind,
              lastCheckedAt: state.sources[source]?.lastCheckedAt,
              itemCount: items.length,
              error: state.sources[source]?.error,
              items: items.map((item) => ({
                entryID: item.entryID,
                title: item.title,
                url: item.url,
                publishedAt: item.publishedAt,
                excerpt: entries.get(item.entryID)?.excerpt ?? '',
                pending: !run.consumed.includes(itemKey(source, item.id))
              }))
            };
          })
        };
      })
    };
  }

  private async notify(): Promise<VoiceBriefSnapshot> {
    const snapshot = await this.buildSnapshot();
    this.onChanged(snapshot);
    return snapshot;
  }

  private async requireVoiceBrief(id: string): Promise<ParsedVoiceBrief> {
    const voiceBrief = (await this.readDefinitions()).find(
      (candidate) => candidate.id === id
    );
    if (!voiceBrief) throw new Error('The selected voice brief no longer exists.');
    if (voiceBrief.error) throw new Error(voiceBrief.error);
    return voiceBrief;
  }

  private async readDefinitions(): Promise<ParsedVoiceBrief[]> {
    await this.ensureDirectory();
    const entries = await readdir(join(this.workspacePath(), 'voice-briefs'), {
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
          return parseVoiceBrief(await readFile(
            join(this.workspacePath(), 'voice-briefs', filename),
            'utf8'
          ), filename);
        } catch (error) {
          return {
            id: `invalid:${filename}`,
            filename,
            title: basename(filename, '.md').replaceAll('-', ' '),
            prompt: defaultVoiceBriefPrompt,
            prioritizeForMe: false,
            schedule: 'manual',
            timezone: Intl.DateTimeFormat().resolvedOptions().timeZone || 'UTC',
            length: '',
            sources: [],
            error:
              error instanceof Error ? error.message : 'This voice brief file is invalid.'
          };
        }
      })
    );
  }

  private async ensureDirectory(): Promise<void> {
    const directory = join(this.workspacePath(), 'voice-briefs');
    await mkdir(directory, { recursive: true });
    const readme = join(directory, 'README.md');
    try {
      await readFile(readme, 'utf8');
    } catch {
      await atomicWrite(readme, voiceBriefReadme);
    }
  }

  private async readState(): Promise<VoiceBriefState> {
    try {
      const value = JSON.parse(
        await readFile(this.statePath(), 'utf8')
      ) as Partial<VoiceBriefState>;
      if (
        value.schemaVersion === 1 &&
        value.sources &&
        typeof value.sources === 'object' &&
        value.voiceBriefs &&
        typeof value.voiceBriefs === 'object'
      ) {
        return value as VoiceBriefState;
      }
    } catch {
      // New workspaces start with an empty rebuildable watcher state.
    }
    return { schemaVersion: 1, sources: {}, voiceBriefs: {} };
  }

  private saveState(state: VoiceBriefState): Promise<void> {
    return atomicWrite(this.statePath(), `${JSON.stringify(state, null, 2)}\n`);
  }

  private statePath(): string {
    return join(this.workspacePath(), '.shared-library', 'voice-brief-state.json');
  }
}

export function parseVoiceBrief(text: string, filename = 'voice-brief.md'): ParsedVoiceBrief {
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
      prompt: parsed.body.trim() || defaultVoiceBriefPrompt,
      prioritizeForMe:
        stringValue(metadata.prioritize_for_me).toLowerCase() === 'true',
      schedule: stringValue(metadata.schedule) || 'manual',
      length: stringValue(metadata.length),
      sources: arrayValue(metadata.sources)
    }),
    id,
    filename,
    timezone: Intl.DateTimeFormat().resolvedOptions().timeZone || 'UTC'
  };
}

export function nextVoiceBriefRun(
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

function normalizeDraft(value: VoiceBriefDraft): VoiceBriefDraft {
  const title = value.title.trim().replace(/\s+/g, ' ');
  if (!title || title.length > 120) {
    throw new Error('Voice brief titles must contain 1–120 characters.');
  }
  const schedule = value.schedule.trim() || 'manual';
  parseSchedule(schedule);
  const length = value.length.trim();
  if (length.length > 120) {
    throw new Error('The length instruction must be 120 characters or fewer.');
  }
  const sources = [
    ...new Set(
      value.sources
        .map((source) => source.trim())
        .filter(Boolean)
        .map(normalizeChannelSource)
    )
  ];
  const prompt = value.prompt.trim();
  if (!prompt) throw new Error('The voice brief prompt cannot be empty.');
  if (prompt.length > 50_000) {
    throw new Error('The voice brief prompt must be 50,000 characters or fewer.');
  }
  const presentPlaceholders = voiceBriefPromptPlaceholders.filter((placeholder) =>
    prompt.includes(placeholder)
  );
  const missingPlaceholder = voiceBriefPromptPlaceholders.find(
    (placeholder) => !prompt.includes(placeholder)
  );
  if (presentPlaceholders.length && missingPlaceholder) {
    throw new Error(`The voice brief prompt must include ${missingPlaceholder}.`);
  }
  if (sources.length > maximumSourcesPerVoiceBrief) {
    throw new Error(`A voice brief can watch up to ${maximumSourcesPerVoiceBrief} channels.`);
  }
  return {
    id: value.id,
    title,
    prompt,
    prioritizeForMe: value.prioritizeForMe === true,
    schedule,
    length,
    sources
  };
}

function normalizeChannelSource(value: string): string {
  const source = value.trim();
  if (!source) throw new Error('Enter a channel URL.');
  if (source.length > 2_048) throw new Error('Channel URLs are too long.');
  if (!/^https?:\/\//iu.test(source) && !/^arxiv:\S/iu.test(source)) {
    throw new Error(`Invalid channel: ${source}`);
  }
  return source;
}

function normalizeChannelRetrievalCount(value: number): number {
  if (
    !Number.isSafeInteger(value) ||
    value < 1 ||
    value > maximumChannelRetrievalCount
  ) {
    throw new Error(
      `Items per check must be between 1 and ${maximumChannelRetrievalCount}.`
    );
  }
  return value;
}

function serializeVoiceBrief(value: VoiceBriefDraft & { id: string }): string {
  const lines = [
    '---',
    ...(value.id.startsWith('file:') ? [] : [`id: ${JSON.stringify(value.id)}`]),
    `name: ${JSON.stringify(value.title)}`,
    `schedule: ${JSON.stringify(value.schedule)}`,
    ...(value.prioritizeForMe ? ['prioritize_for_me: true'] : []),
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

function availableVoiceBriefFilename(base: string, used: Set<string>): string {
  let filename = `${base}.md`;
  for (let suffix = 2; used.has(filename); suffix += 1) {
    filename = `${base}-${suffix}.md`;
  }
  return filename;
}

export function renderVoiceBriefPrompt(
  template: string,
  voiceBrief: {
    title: string;
    length: string;
    prompt?: string;
    prioritizeForMe?: boolean;
  },
  packets: string[],
  personalContext = ''
): string {
  const specific = voiceBrief.prompt?.trim() ?? '';
  const usesSpecificTemplate = voiceBriefPromptPlaceholders.some((placeholder) =>
    specific.includes(placeholder)
  );
  const selectedTemplate = usesSpecificTemplate ? specific : template;
  const missing = voiceBriefPromptPlaceholders.find(
    (placeholder) => !selectedTemplate.includes(placeholder)
  );
  if (missing) throw new Error(`The voice brief prompt must include ${missing}.`);
  const rendered = selectedTemplate
    .trim()
    .replaceAll('{{voice_brief_title}}', JSON.stringify(voiceBrief.title))
    .replaceAll(
      '{{requested_length}}',
      JSON.stringify(
        voiceBrief.length || 'Use the natural length for the available material.'
      )
    )
    .replaceAll(
      '{{source_packets}}',
      packets.map((packet) => `\n<source>\n${packet}\n</source>`).join('\n')
    );
  const prompt = specific && !usesSpecificTemplate
    ? `Voice-brief-specific instructions:\n${specific}\n\n${rendered}`
    : rendered;
  const context = personalContext.trim();
  return voiceBrief.prioritizeForMe && context
    ? `Personal context for relevance:
<personal_context>
${context}
</personal_context>

Use this context only to prioritize and emphasize source updates that fit the person. You may omit lower-value updates, but still include materially important or urgent developments. Never use the personal context as a factual source.

${prompt}`
    : prompt;
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
      .slice(0, 64) || 'voice-brief'
  );
}

async function atomicWrite(path: string, text: string): Promise<void> {
  await mkdir(dirname(path), { recursive: true });
  const temporary = `${path}.${randomUUID()}.tmp`;
  await writeFile(temporary, text, 'utf8');
  await rename(temporary, path);
}

const voiceBriefReadme = `# Voice briefs

Each other Markdown file in this folder defines one voice brief. Briefly and your
agents can edit the files directly. Add or remove lines under \`sources:\` to
change which channels it watches. The Markdown body contains its editorial
instructions.

Keep the schedule \`manual\` when an agent owns the cadence. Briefly gathers
channels headlessly and uses the visible browser only to establish a signed-in
session when needed.

\`\`\`markdown
---
name: "AI Daily"
schedule: "daily 07:30"
prioritize_for_me: true
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
\`prioritize_for_me: true\` uses the personal context saved in Briefly settings.
`;
