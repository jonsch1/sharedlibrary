<script lang="ts">
  import {
    CalendarDays,
    Check,
    FileText,
    LoaderCircle,
    Radio,
    Sparkles,
    Trash2
  } from '@lucide/svelte';
  import {
    type ChannelDefinition,
    type PodcastDefinition,
    type PodcastDraft,
    type PodcastSnapshot
  } from '../shared/contracts';

  let {
    podcastid,
    creating = false,
    onselected,
    onmessage
  }: {
    podcastid: string;
    creating?: boolean;
    onselected: (podcastID: string) => void;
    onmessage: (message: string) => void;
  } = $props();

  let snapshot = $state<PodcastSnapshot | null>(null);
  let selectedID = $state('');
  let draft = $state<PodcastDraft>(emptyDraft());
  let busy = $state(false);
  let dirty = $state(false);
  let revision = $state(0);
  let saveTimer: ReturnType<typeof setTimeout> | null = null;

  let selected = $derived(
    snapshot?.podcasts.find((podcast) => podcast.id === selectedID) ?? null
  );
  let channels = $derived(snapshot?.channels ?? []);
  let channelDomains = $derived.by(() => {
    const groups = new Map<string, ChannelDefinition[]>();
    for (const channel of channels) {
      const domain = channelDomain(channel.source);
      groups.set(domain, [...(groups.get(domain) ?? []), channel]);
    }
    return [...groups]
      .map(([domain, items]) => ({
        domain,
        items: items.toSorted((left, right) =>
          (left.title ?? left.source).localeCompare(right.title ?? right.source)
        )
      }))
      .sort((left, right) => left.domain.localeCompare(right.domain));
  });
  let saveStatus = $derived(
    dirty ? (busy ? 'Saving…' : 'Unsaved changes') : 'Saved'
  );
  let gatheredItems = $derived(
    selected?.sourceStatuses.flatMap((status) =>
      status.items
        .filter((item) => item.pending)
        .map((item) => ({
          ...item,
          channel: status.title ?? status.source
        }))
    ) ?? []
  );

  void initialize();

  async function initialize(): Promise<void> {
    try {
      selectedID = podcastid;
      dirty = creating;
      applySnapshot(await window.sharedLibrary.getPodcasts());
      const remove = window.sharedLibrary.onPodcastsChanged((next) => {
        applySnapshot(next, !dirty);
      });
      window.addEventListener(
        'beforeunload',
        () => {
          remove();
          if (saveTimer) clearTimeout(saveTimer);
        },
        { once: true }
      );
    } catch (error) {
      onmessage(error instanceof Error ? error.message : 'Audio briefs could not be loaded.');
    }
  }

  function applySnapshot(next: PodcastSnapshot, refreshDraft = true): void {
    snapshot = next;
    const podcast = next.podcasts.find((candidate) => candidate.id === selectedID);
    if (refreshDraft && podcast) loadDraft(podcast);
  }

  function loadDraft(podcast: PodcastDefinition): void {
    draft = {
      id: podcast.id,
      title: podcast.title,
      prompt: podcast.prompt,
      schedule: podcast.schedule,
      length: '',
      sources: [...podcast.sources]
    };
    dirty = false;
  }

  function markDirty(): void {
    dirty = true;
    revision += 1;
    scheduleSave();
  }

  function scheduleSave(): void {
    if (saveTimer) clearTimeout(saveTimer);
    saveTimer = setTimeout(() => void save(), 700);
  }

  async function save(): Promise<void> {
    if (busy || !dirty) return;
    if (saveTimer) clearTimeout(saveTimer);
    const title = draft.title.trim();
    const prompt = draft.prompt.trim();
    if (!title || !prompt) return;

    const savingRevision = revision;
    const knownIDs = new Set(snapshot?.podcasts.map((podcast) => podcast.id) ?? []);
    busy = true;
    try {
      const next = await window.sharedLibrary.savePodcast({
        ...draft,
        title,
        prompt,
        sources: [...draft.sources]
      });
      snapshot = next;
      const saved =
        next.podcasts.find((podcast) => podcast.id === draft.id) ??
        next.podcasts.find((podcast) => !knownIDs.has(podcast.id)) ??
        next.podcasts.find((podcast) => podcast.title === title);
      if (saved) {
        selectedID = saved.id;
        onselected(saved.id);
        if (revision === savingRevision) loadDraft(saved);
      }
    } catch (error) {
      onmessage(error instanceof Error ? error.message : 'The audio brief could not be saved.');
    } finally {
      busy = false;
      if (dirty && revision !== savingRevision) scheduleSave();
    }
  }

  async function generateNow(): Promise<void> {
    if (dirty) await save();
    if (dirty || !selected) return;
    busy = true;
    try {
      applySnapshot(await window.sharedLibrary.runPodcast(selected.id));
      onmessage(
        snapshot?.podcasts.find((podcast) => podcast.id === selected.id)?.message ??
          'Audio brief generation finished.'
      );
    } catch (error) {
      onmessage(error instanceof Error ? error.message : 'The audio brief could not be generated.');
    } finally {
      busy = false;
    }
  }

  function toggleChannel(source: string): void {
    draft.sources = draft.sources.includes(source)
      ? draft.sources.filter((candidate) => candidate !== source)
      : [...draft.sources, source];
    markDirty();
  }

  function channelSubtitle(source: string): string {
    try {
      const url = new URL(source);
      return `${url.hostname.replace(/^www\./u, '')}${url.pathname === '/' ? '' : url.pathname}`;
    } catch {
      return source;
    }
  }

  function channelDomain(source: string): string {
    if (source.toLowerCase().startsWith('arxiv:')) return 'arxiv.org';
    try {
      return new URL(source).hostname.replace(/^www\./u, '') || 'Other';
    } catch {
      return 'Other';
    }
  }

  async function remove(): Promise<void> {
    if (!selected || !window.confirm(`Move “${selected.title}” to Trash?`)) return;
    busy = true;
    try {
      applySnapshot(await window.sharedLibrary.removePodcast(selected.id));
      onselected('');
      onmessage('Audio brief moved to Trash.');
    } catch (error) {
      onmessage(error instanceof Error ? error.message : 'The audio brief could not be removed.');
    } finally {
      busy = false;
    }
  }

  function emptyDraft(): PodcastDraft {
    return {
      title: 'New audio brief',
      prompt: 'Connect the most important updates into one concise, conversational briefing.',
      schedule: 'manual',
      length: '',
      sources: []
    };
  }
</script>

<div class="podcast-document-workspace bg-background! bg-none! text-foreground! font-sans!">
  <header class="podcast-document-toolbar border-border!">
    <div class="podcast-document-actions">
      <span class="podcast-save-status text-muted-foreground!">
        {#if !dirty}<Check />{/if}{saveStatus}
      </span>
      {#if selected}
        <button
          class="secondary-button border-border! bg-secondary! bg-none! text-secondary-foreground! rounded-lg! border shadow-sm! hover:bg-secondary/80!"
          onclick={() => window.sharedLibrary.revealPodcast(selected!.id)}
        ><FileText /> File</button>
      {/if}
      <button
        class="primary-button border-primary! bg-primary! bg-none! text-primary-foreground! rounded-lg! border shadow-sm! hover:bg-primary/80!"
        disabled={busy || !selected || !gatheredItems.length}
        onclick={generateNow}
      >
        {#if busy}<LoaderCircle class="spin" />{:else}<Sparkles />{/if}
        Generate audio brief
      </button>
    </div>
  </header>

  <div class="podcast-document-scroll">
    <section class="podcast-document">
      <input
        class="podcast-document-title text-foreground! placeholder:text-muted-foreground!"
        aria-label="Audio brief title"
        bind:value={draft.title}
        oninput={markDirty}
        placeholder="Audio brief title"
      />
      <section class="brief-editor-section" aria-labelledby="brief-direction-title">
        <header>
          <h2 id="brief-direction-title">Editorial direction</h2>
          <p class="text-muted-foreground!">
            Tell Briefly what to prioritize, connect, or leave out.
          </p>
        </header>
        <textarea
          class="podcast-prompt border-input! bg-background! text-foreground! placeholder:text-muted-foreground! rounded-lg! border focus:border-ring focus:ring-2 focus:ring-ring/20"
          aria-label="Audio brief instructions"
          bind:value={draft.prompt}
          oninput={markDirty}
          placeholder="Describe the audio brief you want Briefly to make."
        ></textarea>
      </section>

      <section class="brief-editor-section" aria-labelledby="brief-channels-title">
        <header class="brief-section-heading">
          <div>
            <h2 id="brief-channels-title">Channels</h2>
            <p class="text-muted-foreground!">
              Choose from your configured Channel library.
            </p>
          </div>
          <span class="brief-selection-count text-muted-foreground!">
            {draft.sources.length} selected
          </span>
        </header>

        {#if channels.length}
          <div class="brief-channel-table-wrap border-border! rounded-lg! border">
            <table class="brief-channel-table">
              <thead class="bg-muted! text-muted-foreground!">
                <tr>
                  <th>Channel</th>
                  <th>Source</th>
                  <th>Items</th>
                </tr>
              </thead>
              {#each channelDomains as group (group.domain)}
                <tbody>
                  <tr class="brief-channel-domain bg-muted/50!">
                    <th colspan="3">{group.domain}</th>
                  </tr>
                  {#each group.items as channel (channel.source)}
                    <tr
                      class="brief-channel-row text-card-foreground! hover:bg-accent!"
                      class:selected={draft.sources.includes(channel.source)}
                      role="button"
                      tabindex="0"
                      aria-pressed={draft.sources.includes(channel.source)}
                      onclick={() => toggleChannel(channel.source)}
                      onkeydown={(event) => {
                        if (event.key === 'Enter' || event.key === ' ') {
                          event.preventDefault();
                          toggleChannel(channel.source);
                        }
                      }}
                    >
                      <td>
                        <span class="brief-channel-icon"><Radio /></span>
                        <strong>{channel.title ?? channelSubtitle(channel.source)}</strong>
                      </td>
                      <td class="text-muted-foreground!">
                        {channelSubtitle(channel.source)}
                      </td>
                      <td class="text-muted-foreground!">{channel.itemCount}</td>
                    </tr>
                  {/each}
                </tbody>
              {/each}
            </table>
          </div>
        {:else}
          <div class="brief-channel-empty border-border! bg-muted! text-muted-foreground!">
            <Radio />
            <span>Add channels in the Channel tab, then choose them here.</span>
          </div>
        {/if}
      </section>

      <section class="brief-compact-settings" aria-label="Audio brief timing">
        <label>
          <span><CalendarDays /> Schedule</span>
          <input
            class="border-input! bg-background! text-foreground! placeholder:text-muted-foreground! rounded-lg! border focus:border-ring focus:ring-2 focus:ring-ring/20"
            bind:value={draft.schedule}
            oninput={markDirty}
            placeholder="manual"
          />
        </label>
      </section>

      {#if selected}
        <footer class="podcast-document-footer border-border!">
          <button
            class="podcast-delete text-destructive!"
            onclick={remove}
            disabled={busy}
          ><Trash2 /> Delete audio brief</button>
        </footer>
      {/if}
    </section>
  </div>
</div>
