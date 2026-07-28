<script lang="ts">
  import {
    ArrowLeft,
    Check,
    ExternalLink,
    FileText,
    FolderOpen,
    LoaderCircle,
    Plus,
    Rss,
    Sparkles,
    Trash2
  } from '@lucide/svelte';
  import AudioPlayer from '../../../Shared/AudioPlayer.svelte';
  import type {
    PodcastDefinition,
    PodcastDraft,
    PodcastSnapshot
  } from '../shared/contracts';

  let {
    onlibrary,
    onopenepisode,
    onmessage,
    embedded = false
  }: {
    onlibrary: () => void;
    onopenepisode: (entryID: string) => void;
    onmessage: (message: string) => void;
    embedded?: boolean;
  } = $props();

  let snapshot = $state<PodcastSnapshot | null>(null);
  let selectedID = $state('');
  let draft = $state<PodcastDraft>(emptyDraft());
  let sourcesText = $state('');
  let busy = $state(false);
  let dirty = $state(false);
  let screen = $state<'overview' | 'start' | 'form' | 'examples'>('overview');
  let step = $state(0);
  let exampleIndex = $state(0);

  const stepNames = ['Name', 'Schedule', 'Sources', 'Length'];
  const examples: PodcastDraft[] = [
    {
      title: 'AI Research Weekly',
      schedule: 'weekly MON 08:00',
      length: '15 minutes',
      sources: [
        'arxiv:large language models',
        'arxiv:AI agents',
        'https://www.youtube.com/@GoogleDeepMind'
      ]
    },
    {
      title: 'Startup Signals',
      schedule: 'daily 08:00',
      length: '',
      sources: [
        'https://news.ycombinator.com/rss',
        'https://www.youtube.com/@ycombinator',
        'https://www.youtube.com/@a16z'
      ]
    },
    {
      title: 'Product & Design',
      schedule: 'weekly FRI 16:00',
      length: '20 minutes',
      sources: [
        'https://www.youtube.com/@Figma',
        'https://www.youtube.com/@NNgroup',
        'https://www.youtube.com/@AJSmart'
      ]
    }
  ];

  let selected = $derived(
    snapshot?.podcasts.find((podcast) => podcast.id === selectedID) ?? null
  );
  let example = $derived(examples[exampleIndex]);
  let canContinue = $derived(
    step === 0
      ? Boolean(draft.title.trim())
      : step === 1
        ? Boolean(draft.schedule.trim())
        : step === 2
          ? Boolean(sourcesText.trim())
          : true
  );

  void initialize();

  async function initialize(): Promise<void> {
    try {
      applySnapshot(await window.sharedLibrary.getPodcasts());
      const remove = window.sharedLibrary.onPodcastsChanged((next) => {
        applySnapshot(next, !dirty);
      });
      window.addEventListener('beforeunload', remove, { once: true });
    } catch (error) {
      onmessage(error instanceof Error ? error.message : 'Podcasts could not be loaded.');
    }
  }

  function applySnapshot(next: PodcastSnapshot, refreshDraft = true): void {
    snapshot = next;
    if (!selectedID && next.podcasts.length && screen === 'overview') {
      selectedID = next.podcasts[0].id;
    }
    if (
      selectedID &&
      !next.podcasts.some((podcast) => podcast.id === selectedID)
    ) {
      selectedID = next.podcasts[0]?.id ?? '';
    }
    if (!next.podcasts.length && screen === 'overview') screen = 'start';
    if (refreshDraft && screen === 'overview') {
      const podcast = next.podcasts.find((candidate) => candidate.id === selectedID);
      if (podcast) loadDraft(podcast);
    }
  }

  function selectPodcast(podcast: PodcastDefinition): void {
    selectedID = podcast.id;
    loadDraft(podcast);
    screen = 'overview';
  }

  function loadDraft(podcast: PodcastDefinition): void {
    draft = {
      id: podcast.id,
      title: podcast.title,
      schedule: podcast.schedule,
      length: podcast.length,
      sources: [...podcast.sources]
    };
    sourcesText = podcast.sources.join('\n');
    dirty = false;
  }

  function createPodcast(): void {
    selectedID = '';
    draft = emptyDraft();
    sourcesText = '';
    dirty = true;
    step = 0;
    screen = 'start';
  }

  function editPodcast(): void {
    if (!selected) return;
    loadDraft(selected);
    step = 0;
    screen = 'form';
  }

  function useExample(): void {
    draft = { ...example, sources: [...example.sources] };
    sourcesText = example.sources.join('\n');
    dirty = true;
    step = 0;
    screen = 'form';
  }

  function cancelSetup(): void {
    if (selected) {
      loadDraft(selected);
      screen = 'overview';
    } else {
      screen = 'start';
    }
  }

  function nextStep(): void {
    if (!canContinue) return;
    if (step < 3) {
      step += 1;
    } else {
      void save();
    }
  }

  function markDirty(): void {
    dirty = true;
  }

  async function save(): Promise<void> {
    await run(async () => {
      const title = draft.title.trim();
      const knownIDs = new Set(snapshot?.podcasts.map((podcast) => podcast.id) ?? []);
      const next = await window.sharedLibrary.savePodcast({
        ...draft,
        sources: sourcesText
          .split(/\r?\n/)
          .map((source) => source.trim().replace(/^[-*]\s+/, ''))
          .filter(Boolean)
      });
      snapshot = next;
      const saved =
        next.podcasts.find((podcast) => podcast.id === draft.id) ??
        next.podcasts.find((podcast) => !knownIDs.has(podcast.id)) ??
        next.podcasts.find((podcast) => podcast.title === title);
      if (saved) {
        selectedID = saved.id;
        loadDraft(saved);
        screen = 'overview';
      }
      onmessage('Podcast file saved.');
    });
  }

  async function remove(): Promise<void> {
    if (!selected || !window.confirm(`Move “${selected.title}” to Trash?`)) return;
    await run(async () => {
      applySnapshot(await window.sharedLibrary.removePodcast(selected.id));
      onmessage('Podcast definition moved to Trash.');
    });
  }

  async function generateNow(): Promise<void> {
    if (!selected) return;
    await run(async () => {
      applySnapshot(await window.sharedLibrary.runPodcast(selected.id), false);
      onmessage(
        snapshot?.podcasts.find((podcast) => podcast.id === selected.id)?.message ??
          'Podcast run finished.'
      );
    });
  }

  async function openAgent(): Promise<void> {
    try {
      await window.sharedLibrary.openAgent();
      onmessage('Opened this library workspace in Codex.');
    } catch (error) {
      onmessage(error instanceof Error ? error.message : 'Codex could not be opened.');
    }
  }

  async function run(operation: () => Promise<void>): Promise<void> {
    if (busy) return;
    busy = true;
    try {
      await operation();
    } catch (error) {
      onmessage(error instanceof Error ? error.message : 'The podcast operation failed.');
    } finally {
      busy = false;
    }
  }

  function emptyDraft(): PodcastDraft {
    return {
      title: '',
      schedule: 'daily 07:30',
      length: '',
      sources: []
    };
  }

  function formatDate(value?: string): string {
    if (!value) return 'Not yet';
    return new Intl.DateTimeFormat(undefined, {
      dateStyle: 'medium',
      timeStyle: 'short'
    }).format(new Date(value));
  }
</script>

<div class="podcast-workspace bg-background! bg-none! text-foreground! font-sans!" class:embedded>
  <aside class="podcast-sidebar border-sidebar-border! bg-sidebar! bg-none! text-sidebar-foreground! rounded-xl! border shadow-sm!">
    <div class="podcast-sidebar-header">
      {#if !embedded}
        <button class="podcast-back text-muted-foreground! hover:text-foreground!" onclick={onlibrary}><ArrowLeft /> Library</button>
      {/if}
      <div>
        <div>
          <span class="podcast-eyebrow text-muted-foreground!">Scheduled</span>
          <h1>Podcasts</h1>
        </div>
        <button
          class="podcast-add border-border! bg-secondary! bg-none! text-secondary-foreground! rounded-lg! border shadow-sm! hover:bg-secondary/80!"
          aria-label="New podcast"
          title="New podcast"
          onclick={createPodcast}
        ><Plus /></button>
      </div>
    </div>

    <div class="podcast-list">
      {#if snapshot?.podcasts.length}
        {#each snapshot.podcasts as podcast (podcast.id)}
          <button
            class="podcast-list-item text-sidebar-foreground! rounded-lg! hover:bg-sidebar-accent/60! [&.selected]:bg-sidebar-accent! [&.selected]:text-sidebar-accent-foreground!"
            class:selected={podcast.id === selectedID}
            onclick={() => selectPodcast(podcast)}
          >
            <span class="bg-primary! bg-none! [&.error]:bg-destructive!" class:error={podcast.status === 'error'}></span>
            <div>
              <strong>{podcast.title}</strong>
              <small class="text-muted-foreground!">{podcast.schedule} · {podcast.sources.length} sources</small>
            </div>
          </button>
        {/each}
      {:else}
        <div class="podcast-empty-list text-muted-foreground!">
          <Rss />
          <p>No podcasts yet.</p>
          <button class="text-primary!" onclick={createPodcast}>Create one</button>
        </div>
      {/if}
    </div>
  </aside>

  <main class="podcast-editor border-border! bg-card! bg-none! text-card-foreground! rounded-xl! border shadow-sm!">
    <header class="podcast-editor-header border-border!">
      <div>
        {#if screen === 'form'}
          <span class="podcast-eyebrow text-muted-foreground!">{step + 1} / 4</span>
          <h2>{stepNames[step]}</h2>
        {:else if screen === 'examples'}
          <span class="podcast-eyebrow text-muted-foreground!">Examples</span>
          <h2>Pick one</h2>
        {:else if screen === 'start'}
          <span class="podcast-eyebrow text-muted-foreground!">New</span>
          <h2>Podcast</h2>
        {:else if selected}
          <span class="podcast-eyebrow text-muted-foreground!">{selected.schedule}</span>
          <h2>{selected.title}</h2>
        {/if}
      </div>
      <div class="podcast-header-actions">
        {#if screen === 'overview' && selected}
          <button
            class="secondary-button border-border! bg-secondary! bg-none! text-secondary-foreground! rounded-lg! border shadow-sm! hover:bg-secondary/80!"
            onclick={() => window.sharedLibrary.revealPodcast(selected!.id)}
          ><FolderOpen /> File</button>
          <button class="primary-button border-primary! bg-primary! bg-none! text-primary-foreground! rounded-lg! border shadow-sm! hover:bg-primary/80!" onclick={editPodcast}>Edit</button>
        {:else if screen === 'form'}
          <button class="secondary-button border-border! bg-secondary! bg-none! text-secondary-foreground! rounded-lg! border shadow-sm! hover:bg-secondary/80!" onclick={cancelSetup}>Cancel</button>
        {:else if screen === 'examples'}
          <button class="secondary-button border-border! bg-secondary! bg-none! text-secondary-foreground! rounded-lg! border shadow-sm! hover:bg-secondary/80!" onclick={() => (screen = 'start')}>Close</button>
        {/if}
      </div>
    </header>

    <div class="podcast-editor-scroll">
      {#if screen === 'start'}
        <section class="podcast-form-card podcast-focus-card podcast-choice border-border! bg-card! bg-none! text-card-foreground! rounded-xl! border shadow-sm!">
          <Sparkles class="podcast-choice-icon text-primary!" />
          <div>
            <span class="podcast-eyebrow text-muted-foreground!">Recommended</span>
            <h3>Create with an agent</h3>
            <p>Talk it through. The agent writes the file.</p>
          </div>
          <div class="podcast-choice-actions">
            <button class="primary-button border-primary! bg-primary! bg-none! text-primary-foreground! rounded-lg! border shadow-sm! hover:bg-primary/80!" onclick={openAgent}>Open agent</button>
            <button class="secondary-button border-border! bg-secondary! bg-none! text-secondary-foreground! rounded-lg! border shadow-sm! hover:bg-secondary/80!" onclick={() => (screen = 'examples')}>
              Examples
            </button>
            <button class="secondary-button border-border! bg-secondary! bg-none! text-secondary-foreground! rounded-lg! border shadow-sm! hover:bg-secondary/80!" onclick={() => (screen = 'form')}>
              Manual
            </button>
          </div>
        </section>
      {:else if screen === 'examples'}
        <section class="podcast-form-card podcast-focus-card podcast-example border-border! bg-card! bg-none! text-card-foreground! rounded-xl! border shadow-sm!">
          <span class="podcast-eyebrow text-muted-foreground!">{exampleIndex + 1} / {examples.length}</span>
          <h3>{example.title}</h3>
          <p>{example.schedule}{example.length ? ` · ${example.length}` : ''}</p>
          <ul>
            {#each example.sources as source}
              <li class="text-muted-foreground!">{source}</li>
            {/each}
          </ul>
          <div class="podcast-step-actions">
            <button
              class="secondary-button border-border! bg-secondary! bg-none! text-secondary-foreground! rounded-lg! border shadow-sm! hover:bg-secondary/80!"
              disabled={exampleIndex === 0}
              onclick={() => (exampleIndex -= 1)}
            >Previous</button>
            <div>
              <button
                class="secondary-button border-border! bg-secondary! bg-none! text-secondary-foreground! rounded-lg! border shadow-sm! hover:bg-secondary/80!"
                disabled={exampleIndex === examples.length - 1}
                onclick={() => (exampleIndex += 1)}
              >Next</button>
              <button class="primary-button border-primary! bg-primary! bg-none! text-primary-foreground! rounded-lg! border shadow-sm! hover:bg-primary/80!" onclick={useExample}>Use</button>
            </div>
          </div>
        </section>
      {:else if screen === 'form'}
        <section class="podcast-form-card podcast-focus-card podcast-step border-border! bg-card! bg-none! text-card-foreground! rounded-xl! border shadow-sm!">
          {#if step === 0}
            <label>
              <span class="text-muted-foreground!">Name</span>
              <input class="border-input! bg-background! bg-none! text-foreground! placeholder:text-muted-foreground! rounded-lg! border shadow-sm! focus:border-ring focus:ring-2 focus:ring-ring/20" bind:value={draft.title} oninput={markDirty} placeholder="AI Daily" />
            </label>
          {:else if step === 1}
            <label>
              <span class="text-muted-foreground!">Schedule</span>
              <input class="border-input! bg-background! bg-none! text-foreground! placeholder:text-muted-foreground! rounded-lg! border shadow-sm! focus:border-ring focus:ring-2 focus:ring-ring/20" bind:value={draft.schedule} oninput={markDirty} placeholder="daily 07:30" />
              <small class="text-muted-foreground!">daily 07:30 · weekly MON 09:00</small>
            </label>
          {:else if step === 2}
            <label>
              <span class="text-muted-foreground!">Sources</span>
              <textarea
                class="podcast-sources border-input! bg-background! bg-none! text-foreground! placeholder:text-muted-foreground! rounded-lg! border shadow-sm! font-mono! focus:border-ring focus:ring-2 focus:ring-ring/20"
                bind:value={sourcesText}
                oninput={markDirty}
                placeholder={"https://example.com/feed.xml\nhttps://youtube.com/@channel\narxiv:AI agents"}
                spellcheck="false"
              ></textarea>
              <small class="text-muted-foreground!">One per line</small>
            </label>
          {:else}
            <label>
              <span class="text-muted-foreground!">Length <em>optional</em></span>
              <input class="border-input! bg-background! bg-none! text-foreground! placeholder:text-muted-foreground! rounded-lg! border shadow-sm! focus:border-ring focus:ring-2 focus:ring-ring/20" bind:value={draft.length} oninput={markDirty} placeholder="20 minutes" />
            </label>
          {/if}
          <div class="podcast-step-actions">
            <button
              class="secondary-button border-border! bg-secondary! bg-none! text-secondary-foreground! rounded-lg! border shadow-sm! hover:bg-secondary/80!"
              onclick={() => step ? (step -= 1) : cancelSetup()}
            >Back</button>
            <button class="primary-button border-primary! bg-primary! bg-none! text-primary-foreground! rounded-lg! border shadow-sm! hover:bg-primary/80!" disabled={busy || !canContinue} onclick={nextStep}>
              {#if busy}
                <LoaderCircle class="spin" />
              {:else if step === 3}
                <Check />
              {/if}
              {step === 3 ? 'Save' : 'Next'}
            </button>
          </div>
        </section>
      {:else if selected}
        <section class="podcast-status-card border-border! bg-card! bg-none! text-card-foreground! rounded-xl! border shadow-sm!">
          <div class="podcast-section-heading">
            <div>
              <h3>{selected.message}</h3>
              <p class="text-muted-foreground!">
                {#if selected.nextRunAt}Next {formatDate(selected.nextRunAt)}{:else}Manual{/if}
              </p>
            </div>
            <div>
              <button class="primary-button border-primary! bg-primary! bg-none! text-primary-foreground! rounded-lg! border shadow-sm! hover:bg-primary/80!" disabled={busy || !selected.sources.length} onclick={generateNow}>
                <Sparkles /> Generate now
              </button>
            </div>
          </div>
        </section>

        <details class="podcast-details border-border! bg-card! bg-none! text-card-foreground! rounded-xl! border shadow-sm!">
          <summary>Sources <span class="text-muted-foreground!">{selected.sources.length}</span></summary>
          <div class="watcher-list">
            {#each selected.sourceStatuses as source}
              <div class="border-border! bg-muted! bg-none! text-foreground! [&.error]:border-destructive/40!" class:error={Boolean(source.error)}>
                <Rss class="text-primary!" />
                <span>
                  <strong>{source.title || source.source}</strong>
                  {#if source.error}<small class="watcher-error">{source.error}</small>{/if}
                </span>
                <button
                  class="text-muted-foreground! hover:bg-accent! hover:text-accent-foreground!"
                  aria-label="Open source"
                  title="Open source"
                  onclick={() => {
                    if (/^https?:\/\//i.test(source.source)) {
                      void window.sharedLibrary.openExternal(source.source);
                    }
                  }}
                ><ExternalLink /></button>
              </div>
            {/each}
          </div>
        </details>

        <details class="podcast-details border-border! bg-card! bg-none! text-card-foreground! rounded-xl! border shadow-sm!">
          <summary>Episodes <span class="text-muted-foreground!">{selected.episodes.length}</span></summary>
          {#if selected.episodes.length}
            <div class="episode-list">
            {#each selected.episodes as episode}
              <div class="border-border! bg-muted! bg-none! text-foreground!">
                <button class="text-foreground!" onclick={() => onopenepisode(episode.id)}>
                  <FileText class="text-primary!" />
                  <span>
                    <strong>{episode.title}</strong>
                    <small class="text-muted-foreground!">{formatDate(episode.createdAt)}</small>
                  </span>
                </button>
                {#if episode.hasAudio}
                  <AudioPlayer
                    src={`briefly-podcast-audio://episode/${encodeURIComponent(episode.id)}.wav`}
                    title={episode.title}
                  />
                {/if}
              </div>
            {/each}
            </div>
          {/if}
        </details>

        <button class="podcast-delete border-destructive! bg-destructive/10! bg-none! text-destructive! rounded-lg! border shadow-sm! hover:bg-destructive/20!" onclick={remove} disabled={busy}>
          <Trash2 /> Delete
        </button>
      {/if}
    </div>
  </main>
</div>
