<script lang="ts">
  import {
    Check,
    FileText,
    Headphones,
    LoaderCircle,
    Plus,
    Sparkles,
    Trash2
  } from '@lucide/svelte';
  import {
    defaultPodcastPrompt,
    type PodcastDefinition,
    type PodcastDraft,
    type PodcastSnapshot
  } from '../shared/contracts';

  let {
    onshowepisodes,
    onmessage
  }: {
    onshowepisodes: (podcastID: string) => void;
    onmessage: (message: string) => void;
  } = $props();

  let snapshot = $state<PodcastSnapshot | null>(null);
  let selectedID = $state('');
  let draft = $state<PodcastDraft>(emptyDraft());
  let sourcesText = $state('');
  let busy = $state(false);
  let dirty = $state(false);
  let revision = $state(0);
  let saveTimer: ReturnType<typeof setTimeout> | null = null;

  let selected = $derived(
    snapshot?.podcasts.find((podcast) => podcast.id === selectedID) ?? null
  );
  let saveStatus = $derived(
    dirty ? (busy ? 'Saving…' : 'Unsaved changes') : 'Saved'
  );

  void initialize();

  async function initialize(): Promise<void> {
    try {
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
      onmessage(error instanceof Error ? error.message : 'Podcasts could not be loaded.');
    }
  }

  function applySnapshot(next: PodcastSnapshot, refreshDraft = true): void {
    snapshot = next;
    if (
      selectedID &&
      !next.podcasts.some((podcast) => podcast.id === selectedID)
    ) {
      selectedID = next.podcasts[0]?.id ?? '';
    }
    if (!selectedID && next.podcasts.length) selectedID = next.podcasts[0].id;
    const podcast = next.podcasts.find((candidate) => candidate.id === selectedID);
    if (refreshDraft && podcast) loadDraft(podcast);
    if (!next.podcasts.length && !dirty) void createPodcast();
  }

  function loadDraft(podcast: PodcastDefinition): void {
    draft = {
      id: podcast.id,
      title: podcast.title,
      prompt: podcast.prompt,
      schedule: podcast.schedule,
      length: podcast.length,
      sources: [...podcast.sources]
    };
    sourcesText = podcast.sources.join('\n');
    dirty = false;
  }

  async function selectPodcast(podcast: PodcastDefinition): Promise<void> {
    if (dirty && selectedID) await save();
    if (dirty && selectedID) return;
    selectedID = podcast.id;
    loadDraft(podcast);
  }

  async function createPodcast(): Promise<void> {
    if (dirty && selectedID) await save();
    if (dirty && selectedID) return;
    if (saveTimer) clearTimeout(saveTimer);
    selectedID = '';
    draft = emptyDraft();
    sourcesText = '';
    dirty = true;
    revision += 1;
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
    const sources = sourcesText
      .split(/\r?\n/)
      .map((source) => source.trim().replace(/^[-*]\s+/, ''))
      .filter(Boolean);
    if (!title || !prompt || !sources.length) return;

    const savingRevision = revision;
    const knownIDs = new Set(snapshot?.podcasts.map((podcast) => podcast.id) ?? []);
    busy = true;
    try {
      const next = await window.sharedLibrary.savePodcast({
        ...draft,
        title,
        prompt,
        sources
      });
      snapshot = next;
      const saved =
        next.podcasts.find((podcast) => podcast.id === draft.id) ??
        next.podcasts.find((podcast) => !knownIDs.has(podcast.id)) ??
        next.podcasts.find((podcast) => podcast.title === title);
      if (saved) {
        selectedID = saved.id;
        if (revision === savingRevision) loadDraft(saved);
      }
    } catch (error) {
      onmessage(error instanceof Error ? error.message : 'The podcast could not be saved.');
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
          'Podcast run finished.'
      );
    } catch (error) {
      onmessage(error instanceof Error ? error.message : 'The podcast could not be generated.');
    } finally {
      busy = false;
    }
  }

  async function remove(): Promise<void> {
    if (!selected || !window.confirm(`Move “${selected.title}” to Trash?`)) return;
    busy = true;
    try {
      applySnapshot(await window.sharedLibrary.removePodcast(selected.id));
      onmessage('Podcast definition moved to Trash.');
    } catch (error) {
      onmessage(error instanceof Error ? error.message : 'The podcast could not be removed.');
    } finally {
      busy = false;
    }
  }

  function emptyDraft(): PodcastDraft {
    return {
      title: 'New podcast',
      prompt: defaultPodcastPrompt,
      schedule: 'manual',
      length: '',
      sources: []
    };
  }
</script>

<div class="podcast-document-workspace bg-background! bg-none! text-foreground! font-sans!">
  <header class="podcast-document-toolbar border-border!">
    <div class="topic-strip podcast-document-switcher" aria-label="Podcasts">
      {#each snapshot?.podcasts ?? [] as podcast (podcast.id)}
        <button
          class="topic-chip border-border! bg-secondary! bg-none! text-secondary-foreground! rounded-lg! border shadow-sm! hover:bg-secondary/80! [&.active]:border-primary! [&.active]:bg-primary! [&.active]:text-primary-foreground!"
          class:active={selectedID === podcast.id}
          onclick={() => void selectPodcast(podcast)}
        >{podcast.title}</button>
      {/each}
      <button
        class="topic-chip podcast-new-chip border-border! bg-secondary! bg-none! text-secondary-foreground! rounded-lg! border shadow-sm! hover:bg-secondary/80! [&.active]:border-primary! [&.active]:bg-primary! [&.active]:text-primary-foreground!"
        class:active={!selectedID}
        disabled={Boolean(snapshot && snapshot.podcasts.length >= snapshot.maximumPodcasts)}
        onclick={() => void createPodcast()}
      ><Plus /> New podcast</button>
    </div>

    <div class="podcast-document-actions">
      <span class="podcast-save-status text-muted-foreground!">
        {#if !dirty}<Check />{/if}{saveStatus}
      </span>
      {#if selected}
        <button
          class="secondary-button border-border! bg-secondary! bg-none! text-secondary-foreground! rounded-lg! border shadow-sm! hover:bg-secondary/80!"
          onclick={() => onshowepisodes(selected!.id)}
        ><Headphones /> Show episodes</button>
        <button
          class="secondary-button border-border! bg-secondary! bg-none! text-secondary-foreground! rounded-lg! border shadow-sm! hover:bg-secondary/80!"
          onclick={() => window.sharedLibrary.revealPodcast(selected!.id)}
        ><FileText /> File</button>
      {/if}
      <button
        class="primary-button border-primary! bg-primary! bg-none! text-primary-foreground! rounded-lg! border shadow-sm! hover:bg-primary/80!"
        disabled={busy || !selected}
        onclick={generateNow}
      >
        {#if busy}<LoaderCircle class="spin" />{:else}<Sparkles />{/if}
        Generate now
      </button>
    </div>
  </header>

  <div class="podcast-document-scroll">
    <section class="podcast-document">
      <input
        class="podcast-document-title text-foreground! placeholder:text-muted-foreground!"
        aria-label="Podcast title"
        bind:value={draft.title}
        oninput={markDirty}
        placeholder="Podcast title"
      />
      <textarea
        class="podcast-prompt text-foreground! placeholder:text-muted-foreground!"
        aria-label="Podcast prompt"
        bind:value={draft.prompt}
        oninput={markDirty}
        placeholder="Describe the podcast you want Briefly to make."
      ></textarea>

      <label class="podcast-sources-field">
        <span>Sources</span>
        <textarea
          class="podcast-sources border-input! bg-background! bg-none! text-foreground! placeholder:text-muted-foreground! rounded-lg! border font-mono! focus:border-ring focus:ring-2 focus:ring-ring/20"
          aria-label="Podcast sources"
          bind:value={sourcesText}
          oninput={markDirty}
          placeholder={"https://example.com/feed.xml\nhttps://youtube.com/@channel\narxiv:AI agents"}
          spellcheck="false"
        ></textarea>
        <small class="text-muted-foreground!">One source per line</small>
      </label>

      {#if selected}
        <footer class="podcast-document-footer border-border!">
          <button
            class="podcast-delete text-destructive!"
            onclick={remove}
            disabled={busy}
          ><Trash2 /> Delete podcast</button>
        </footer>
      {/if}
    </section>
  </div>
</div>
