<script lang="ts">
  import {
    Archive,
    ArrowUpRight,
    Check,
    ChevronLeft,
    Cloud,
    Clipboard,
    Copy,
    FileText,
    FolderOpen,
    Headphones,
    Link,
    ListMusic,
    LoaderCircle,
    LogIn,
    Pause,
    Pencil,
    Play,
    RefreshCw,
    Search,
    Settings2,
    Share2,
    Sparkles,
    Trash2,
    X
  } from '@lucide/svelte';
  import MarkdownView from './MarkdownView.svelte';
  import type {
    DesktopLibraryEntry,
    DesktopLibrarySnapshot,
    DesktopConnectionStatus,
    DesktopSyncStatus,
    LibraryVariant,
    NarrationSegment,
    OpenRouterVoice,
    ShareLinkStatus
  } from '../shared/contracts';

  const variantNames: Record<LibraryVariant, string> = {
    brief: 'Brief',
    concise: 'Concise',
    detailed: 'Detailed',
    comprehensive: 'Comprehensive',
    source: 'Original'
  };

  let snapshot = $state<DesktopLibrarySnapshot | null>(null);
  let selectedID = $state('');
  let selectedVariant = $state<LibraryVariant>('concise');
  let selectedText = $state('');
  let query = $state('');
  let selectedTopic = $state('all');
  let loading = $state(true);
  let loadingText = $state(false);
  let busy = $state(false);
  let message = $state('');
  let settingsOpen = $state(false);
  let editing = $state(false);
  let editorText = $state('');
  let mobileReaderVisible = $state(false);
  let playbackRate = $state(1);
  let connections = $state<DesktopConnectionStatus | null>(null);
  let syncStatus = $state<DesktopSyncStatus>({
    phase: 'idle',
    message: 'Sign in with Google to synchronize this library.'
  });
  let voice = $state<OpenRouterVoice>('eve');
  let narrationState = $state<'idle' | 'loading' | 'playing' | 'paused'>('idle');
  let narrationSessionID = $state('');
  let narrationSegments = $state<string[]>([]);
  let narrationIndex = $state(0);
  let narrationTotal = $state(0);
  let narrationProgress = $state(0);
  let narrationAudio: HTMLAudioElement | null = null;
  let share = $state<ShareLinkStatus>({ shared: false });
  let shareBusy = $state(false);

  let entries = $derived(snapshot?.entries ?? []);
  let selectedEntry = $derived(
    entries.find((entry) => entry.id === selectedID) ?? entries[0] ?? null
  );
  let normalizedQuery = $derived(query.trim().toLowerCase());
  let filteredEntries = $derived(
    entries.filter((entry) => {
      if (selectedTopic !== 'all' && !entry.topicNames.includes(selectedTopic)) return false;
      if (!normalizedQuery) return true;
      return [entry.title, entry.excerpt, ...entry.topicNames, ...entry.tags]
        .join(' ')
        .toLowerCase()
        .includes(normalizedQuery);
    })
  );
  let availableVariants = $derived(selectedEntry?.availableVariants ?? []);
  let selectedVariantIndex = $derived(
    Math.max(0, availableVariants.indexOf(selectedVariant))
  );
  let wordCount = $derived(
    selectedText.trim() ? selectedText.trim().split(/\s+/).length : 0
  );

  $effect(() => {
    if (selectedEntry && !selectedID) selectedID = selectedEntry.id;
  });

  $effect(() => {
    const entry = selectedEntry;
    if (!entry) {
      selectedText = '';
      return;
    }
    if (!entry.availableVariants.includes(selectedVariant)) {
      selectedVariant = entry.availableVariants.includes('concise')
        ? 'concise'
        : (entry.availableVariants[0] ?? 'source');
      return;
    }
    void loadText(entry, selectedVariant);
  });

  void initialize();

  async function initialize(): Promise<void> {
    try {
      applySnapshot(await window.sharedLibrary.getSnapshot());
      connections = await window.sharedLibrary.getConnectionStatus();
      syncStatus = connections.sync;
      voice = connections.voice;
      const savedTopic = window.localStorage.getItem('shared-library-selected-topic');
      if (savedTopic && snapshot?.topics.includes(savedTopic)) selectedTopic = savedTopic;
      const removeLibraryListener = window.sharedLibrary.onLibraryChanged(applySnapshot);
      const removeWorkspaceListener =
        window.sharedLibraryDesktopEvents.onChooseWorkspace(() => void chooseWorkspace());
      const removeMessageListener =
        window.sharedLibraryDesktopEvents.onOperationMessage((result) => {
          message = result.message ?? '';
          if (result.selectedEntryID) {
            selectedID = result.selectedEntryID;
            mobileReaderVisible = true;
          }
        });
      const removeSyncListener = window.sharedLibrary.onSyncStatus((status) => {
        syncStatus = status;
        if (status.phase === 'error') message = status.message;
      });
      const removeNarrationListener =
        window.sharedLibrary.onNarrationSegment(receiveNarrationSegment);
      narrationAudio = new Audio();
      narrationAudio.playbackRate = playbackRate;
      narrationAudio.addEventListener('timeupdate', updateNarrationProgress);
      narrationAudio.addEventListener('ended', advanceNarration);
      narrationAudio.addEventListener('play', () => (narrationState = 'playing'));
      narrationAudio.addEventListener('pause', () => {
        if (narrationState === 'playing') narrationState = 'paused';
      });
      window.addEventListener(
        'beforeunload',
        () => {
          removeLibraryListener();
          removeWorkspaceListener();
          removeMessageListener();
          removeSyncListener();
          removeNarrationListener();
          narrationAudio?.pause();
        },
        { once: true }
      );
    } catch (error) {
      message = error instanceof Error ? error.message : 'The library could not be opened.';
    } finally {
      loading = false;
    }
  }

  function applySnapshot(next: DesktopLibrarySnapshot): void {
    const previousSelection = selectedID;
    snapshot = next;
    selectedID = next.entries.some((entry) => entry.id === previousSelection)
      ? previousSelection
      : (next.entries[0]?.id ?? '');
    if (selectedTopic !== 'all' && !next.topics.includes(selectedTopic)) {
      selectTopic('all');
    }
  }

  async function loadText(
    entry: DesktopLibraryEntry,
    variant: LibraryVariant
  ): Promise<void> {
    loadingText = true;
    try {
      const text = await window.sharedLibrary.readText(entry.id, variant);
      if (selectedEntry?.id === entry.id && selectedVariant === variant) {
        selectedText = text;
        editorText = text;
      }
    } catch (error) {
      message = error instanceof Error ? error.message : 'The document could not be read.';
    } finally {
      loadingText = false;
    }
  }

  function selectEntry(entry: DesktopLibraryEntry): void {
    stopNarration();
    share = { shared: false };
    selectedID = entry.id;
    selectedVariant = entry.availableVariants.includes('concise')
      ? 'concise'
      : (entry.availableVariants[0] ?? 'source');
    editing = false;
    mobileReaderVisible = true;
  }

  function selectTopic(topic: string): void {
    selectedTopic = topic;
    window.localStorage.setItem('shared-library-selected-topic', topic);
  }

  function selectVariantFromSlider(event: Event): void {
    const index = Number((event.currentTarget as HTMLInputElement).value);
    const variant = availableVariants[index];
    if (variant) {
      stopNarration();
      selectedVariant = variant;
      editing = false;
    }
  }

  function cyclePlaybackRate(): void {
    const rates = [1, 1.25, 1.5, 1.75, 2];
    const current = rates.indexOf(playbackRate);
    playbackRate = rates[(current + 1) % rates.length];
    if (narrationAudio) narrationAudio.playbackRate = playbackRate;
  }

  async function refresh(): Promise<void> {
    await run(async () => {
      applySnapshot(await window.sharedLibrary.refresh());
      message = 'Library refreshed.';
    });
  }

  async function captureClipboard(): Promise<void> {
    await run(async () => {
      const result = await window.sharedLibrary.captureClipboard();
      applySnapshot(result.snapshot);
      if (result.selectedEntryID) {
        selectedID = result.selectedEntryID;
        mobileReaderVisible = true;
      }
      message = result.message;
    });
  }

  async function chooseWorkspace(): Promise<void> {
    await run(async () => {
      const result = await window.sharedLibrary.chooseWorkspace();
      if (result) {
        applySnapshot(result);
        settingsOpen = false;
        message = 'Workspace changed.';
      }
    });
  }

  function beginEditing(): void {
    if (!selectedEntry) return;
    editorText = selectedText;
    editing = true;
    settingsOpen = true;
  }

  async function save(): Promise<void> {
    if (!selectedEntry) return;
    await run(async () => {
      const result = await window.sharedLibrary.writeText(
        selectedEntry!.id,
        selectedVariant,
        editorText
      );
      applySnapshot(result.snapshot);
      selectedText = editorText;
      editing = false;
      message = result.message;
    });
  }

  async function trashSelected(): Promise<void> {
    if (!selectedEntry) return;
    if (!window.confirm(`Move “${selectedEntry.title}” and all summaries to Trash?`)) return;
    await run(async () => {
      const result = await window.sharedLibrary.trashCapture(selectedEntry!.id);
      applySnapshot(result.snapshot);
      settingsOpen = false;
      mobileReaderVisible = false;
      message = result.message;
    });
  }

  async function connect(provider: 'google' | 'openrouter'): Promise<void> {
    await run(async () => {
      connections = await window.sharedLibrary.connect(provider);
      syncStatus = connections.sync;
      message =
        provider === 'google'
          ? 'Google account connected. Your Drive location is now configured for this account.'
          : 'OpenRouter narration connected.';
    });
  }

  async function disconnect(provider: 'google' | 'openrouter'): Promise<void> {
    await run(async () => {
      connections = await window.sharedLibrary.disconnect(provider);
      message = provider === 'google' ? 'Google Drive disconnected.' : 'OpenRouter disconnected.';
    });
  }

  async function changeVoice(event: Event): Promise<void> {
    const next = (event.currentTarget as HTMLSelectElement).value as OpenRouterVoice;
    connections = await window.sharedLibrary.setVoice(next);
    voice = connections.voice;
  }

  async function listen(): Promise<void> {
    if (!selectedEntry || !narrationAudio) return;
    if (narrationState === 'playing') {
      narrationAudio.pause();
      return;
    }
    if (narrationState === 'paused' && narrationAudio.src) {
      await narrationAudio.play();
      return;
    }
    if (!connections?.openrouter.connected) {
      settingsOpen = true;
      message = 'Connect OpenRouter to generate narration.';
      return;
    }
    narrationState = 'loading';
    narrationProgress = 0;
    try {
      const session = await window.sharedLibrary.startNarration(
        selectedEntry.id,
        selectedVariant,
        voice
      );
      narrationSessionID = session.sessionID;
      narrationTotal = session.total;
      narrationIndex = 0;
      narrationSegments = [];
      narrationSegments[0] = session.first.url;
      await playNarrationIndex(0);
    } catch (error) {
      narrationState = 'idle';
      message = error instanceof Error ? error.message : 'Narration could not be started.';
    }
  }

  function receiveNarrationSegment(segment: NarrationSegment): void {
    if (segment.sessionID !== narrationSessionID) return;
    narrationSegments[segment.index] = segment.url;
    narrationSegments = [...narrationSegments];
    if (narrationState === 'loading' && narrationIndex === segment.index) {
      void playNarrationIndex(segment.index);
    }
  }

  async function playNarrationIndex(index: number): Promise<void> {
    const url = narrationSegments[index];
    if (!url || !narrationAudio) {
      narrationState = 'loading';
      return;
    }
    narrationIndex = index;
    narrationAudio.src = url;
    narrationAudio.playbackRate = playbackRate;
    await narrationAudio.play();
  }

  function advanceNarration(): void {
    narrationProgress = 0;
    const next = narrationIndex + 1;
    if (next >= narrationTotal) {
      narrationState = 'idle';
      narrationIndex = 0;
      return;
    }
    narrationIndex = next;
    void playNarrationIndex(next);
  }

  function updateNarrationProgress(): void {
    if (!narrationAudio || !Number.isFinite(narrationAudio.duration)) {
      narrationProgress = 0;
      return;
    }
    narrationProgress =
      (narrationIndex + narrationAudio.currentTime / narrationAudio.duration) /
      Math.max(narrationTotal, 1);
  }

  function stopNarration(): void {
    narrationAudio?.pause();
    if (narrationAudio) narrationAudio.removeAttribute('src');
    narrationSessionID = '';
    narrationSegments = [];
    narrationState = 'idle';
    narrationProgress = 0;
  }

  async function shareDocument(): Promise<void> {
    if (!selectedEntry || shareBusy) return;
    shareBusy = true;
    try {
      share = await window.sharedLibrary.getShareLink(selectedEntry.id);
      if (share.shared && share.status === 'ready' && share.url) {
        await navigator.clipboard.writeText(share.url);
        message = 'Share link copied.';
        return;
      }
      share = await window.sharedLibrary.publishShareLink(selectedEntry.id, voice);
      message =
        share.status === 'ready'
          ? 'Share link copied.'
          : 'The share link is being prepared in the background.';
    } catch (error) {
      message = error instanceof Error ? error.message : 'The share link could not be created.';
    } finally {
      shareBusy = false;
    }
  }

  async function revokeShare(): Promise<void> {
    if (!share.token) return;
    await run(async () => {
      await window.sharedLibrary.revokeShareLink(share.token!);
      share = { shared: false };
      message = 'Share link revoked.';
    });
  }

  async function run(operation: () => Promise<void>): Promise<void> {
    if (busy) return;
    busy = true;
    try {
      await operation();
    } catch (error) {
      message = error instanceof Error ? error.message : 'The operation failed.';
    } finally {
      busy = false;
    }
  }

</script>

<svelte:head>
  <title>Shared Library</title>
</svelte:head>

<div class="app-shell">
  {#if loading}
    <main class="center-stage" aria-live="polite">
      <div class="loading-mark"><LoaderCircle class="spin" /></div>
      <p>Opening your offline library…</p>
    </main>
  {:else if entries.length === 0}
    <main class="center-stage">
      <section class="empty-card">
        <div class="empty-illustration">
          <Archive />
          <span class="empty-check"><Check /></span>
        </div>
        <p class="eyebrow">Shared Library</p>
        <h1>Your library is ready</h1>
        <p class="empty-copy">
          Capture clipboard text or choose the existing Shared Library workspace.
        </p>
        <div class="empty-actions">
          <button class="primary-button" onclick={captureClipboard}>
            <Clipboard /> Capture
          </button>
          <button class="secondary-button" onclick={chooseWorkspace}>
            <FolderOpen /> Choose folder
          </button>
        </div>
      </section>
    </main>
  {:else}
    <div class="native-workspace" class:reader-open={mobileReaderVisible}>
      <aside class="native-library-pane">
        <div class="native-library-toolbar">
          <div class="native-search-field">
            <Search aria-hidden="true" />
            <input bind:value={query} aria-label="Search library" placeholder="Search" />
            {#if query}
              <button class="clear-search" aria-label="Clear search" onclick={() => (query = '')}>
                <X />
              </button>
            {/if}
          </div>

          <div class="topic-strip" aria-label="Topic filter">
            <button
              class="topic-chip"
              class:active={selectedTopic === 'all'}
              onclick={() => selectTopic('all')}
            >All</button>
            {#each snapshot?.topics ?? [] as topic}
              <button
                class="topic-chip"
                class:active={selectedTopic === topic}
                onclick={() => selectTopic(topic)}
              >{topic}</button>
            {/each}
          </div>
        </div>

        <div class="native-entry-list">
          {#if filteredEntries.length === 0}
            <div class="native-no-results">
              <FileText />
              <p>No matching documents</p>
              <button onclick={() => {
                query = '';
                selectTopic('all');
              }}>Clear filters</button>
            </div>
          {:else}
            {#each filteredEntries as entry (entry.id)}
              <button
                class="native-entry-row"
                class:selected={selectedEntry?.id === entry.id}
                onclick={() => selectEntry(entry)}
              >
                <FileText aria-hidden="true" />
                <span>{entry.title}</span>
              </button>
            {/each}
          {/if}
        </div>

        <div class="native-sidebar-footer">
          <button
            class="agent-button"
            onclick={() => window.sharedLibrary.openExternal('https://chatgpt.com/')}
          >
            <Sparkles />
            <span>Agent</span>
          </button>
        </div>
      </aside>

      <main class="native-reader-pane">
        {#if selectedEntry}
          <div class="native-mobile-reader-bar">
            <button onclick={() => (mobileReaderVisible = false)}>
              <ChevronLeft />
              <span>Library</span>
            </button>
          </div>

          <div class="native-document-scroll">
            <article class="native-document-body">
              {#if loadingText}
                <div class="document-loading"><LoaderCircle class="spin" /></div>
              {:else if selectedText}
                <MarkdownView text={selectedText} />
              {:else}
                <p class="missing-text">This version is not available.</p>
              {/if}
            </article>
          </div>

          <footer class="native-document-footer">
            <div
              class="native-player-progress"
              class:visible={narrationState !== 'idle'}
              style={`--progress: ${narrationProgress * 100}%`}
            ></div>
            <div class="footer-stat">{wordCount.toLocaleString()} words</div>

            <div class="native-variant-control">
              <span>Concise</span>
              <input
                type="range"
                min="0"
                max={Math.max(availableVariants.length - 1, 0)}
                step="1"
                value={selectedVariantIndex}
                aria-label={`Document version: ${variantNames[selectedVariant]}`}
                oninput={selectVariantFromSlider}
              />
              <span>Original</span>
            </div>

            <div class="native-footer-actions">
              {#if selectedEntry.sourceURL}
                <button
                  class="native-icon-button"
                  aria-label="Open original source"
                  title="Open original source"
                  onclick={() => window.sharedLibrary.openExternal(selectedEntry!.sourceURL!)}
                >
                  <ArrowUpRight />
                </button>
              {/if}

              <button
                class="native-icon-button"
                aria-label="Share document"
                title="Create share link"
                onclick={shareDocument}
              >
                {#if shareBusy}
                  <LoaderCircle class="spin" />
                {:else}
                  <Share2 />
                {/if}
              </button>

              <button
                class="native-icon-button"
                aria-label="Audio settings"
                title="Audio settings"
                onclick={() => (settingsOpen = true)}
              >
                <Headphones />
                {#if connections?.openrouter.connected}
                  <span class="connection-dot" aria-hidden="true"></span>
                {/if}
              </button>

              <button
                class="native-play-button"
                aria-label={narrationState === 'playing' ? 'Pause' : 'Play'}
                title={narrationState === 'loading'
                  ? 'Preparing audio'
                  : narrationState === 'playing'
                    ? 'Pause'
                    : 'Play'}
                onclick={listen}
              >
                {#if narrationState === 'loading'}
                  <LoaderCircle class="spin" />
                {:else if narrationState === 'playing'}
                  <Pause />
                {:else}
                  <Play />
                {/if}
              </button>

              <button
                class="native-rate-button"
                aria-label={`Playback speed ${playbackRate.toFixed(1)} times`}
                title="Change playback speed"
                onclick={cyclePlaybackRate}
              >
                {playbackRate.toFixed(1)}×
              </button>

              <button
                class="native-icon-button queue-action"
                aria-label="Add to listening queue"
                title="Add to listening queue"
                onclick={() => (message = 'Added to the listening queue.')}
              >
                <ListMusic />
              </button>

              <button
                class="native-icon-button"
                class:active={settingsOpen}
                aria-label="Connections"
                title="Connections"
                onclick={() => (settingsOpen = true)}
              >
                <Settings2 />
              </button>
            </div>
          </footer>
        {/if}
      </main>
    </div>
  {/if}

  {#if message}
    <div class="toast" class:error={message.includes('failed') || message.includes('could not')}>
      <span>{message}</span>
      <button aria-label="Dismiss message" onclick={() => (message = '')}><X /></button>
    </div>
  {/if}
</div>

{#if settingsOpen}
  <div class="audio-backdrop" role="presentation" onclick={() => (settingsOpen = false)}></div>
  <aside class="audio-panel connections-panel" aria-label="Connections">
    <div class="audio-header">
      <div>
        <p class="eyebrow">Desktop</p>
        <h2>Connections</h2>
      </div>
      <button class="panel-close" aria-label="Close settings" onclick={() => (settingsOpen = false)}>
        <X />
      </button>
    </div>
    <div class="audio-content">
      <section class="settings-card">
        <div class="settings-card-heading">
          <div class="provider-mark"><FolderOpen /></div>
          <div>
            <h3>Library workspace</h3>
            <p>The same Markdown folder structure is used by every client.</p>
          </div>
        </div>
        <code>{snapshot?.workspacePath}</code>
        <div class="panel-actions">
          <button class="secondary-button" onclick={chooseWorkspace}>
            <FolderOpen /> Choose folder
          </button>
          <button class="secondary-button" onclick={refresh} disabled={busy}>
            <RefreshCw class={busy ? 'spin' : ''} /> Refresh
          </button>
          <button class="secondary-button" onclick={captureClipboard} disabled={busy}>
            <Clipboard /> Capture
          </button>
        </div>
      </section>

      <section class="settings-card">
        <div class="settings-card-heading">
          <div class="provider-mark"><Cloud /></div>
          <div>
            <h3>Google account</h3>
            <p>
              {#if connections?.google.connected}
                Connected. This account’s Drive folder is mirrored automatically.
              {:else}
                Sign in once to configure the personal Drive location for every client.
              {/if}
            </p>
          </div>
        </div>
        {#if connections?.google.connected}
          <div class="connection-status">
            <span class="status-dot"></span>
            <span>{syncStatus.message}</span>
            {#if syncStatus.phase === 'checking' || syncStatus.phase === 'downloading' || syncStatus.phase === 'uploading'}
              <LoaderCircle class="spin" />
            {/if}
          </div>
          <div class="panel-actions">
            <button class="secondary-button danger-button" onclick={() => disconnect('google')} disabled={busy}>
              Disconnect Drive
            </button>
          </div>
        {:else}
          <div class="panel-actions">
            <button class="primary-button" onclick={() => connect('google')} disabled={busy}>
              {#if busy}<LoaderCircle class="spin" />{:else}<LogIn />{/if}
              Sign in with Google
            </button>
          </div>
        {/if}
      </section>

      <section class="settings-card">
        <div class="settings-card-heading">
          <div class="provider-mark"><Headphones /></div>
          <div>
            <h3>Narration</h3>
            <p>
              Connect OpenRouter for Grok Voice narration. Audio is cached locally and
              backed up to your Drive folder.
            </p>
          </div>
        </div>
        <label class="voice-field">
          <span>Voice</span>
          <select value={voice} onchange={changeVoice}>
            <option value="eve">Eve · energetic</option>
            <option value="ara">Ara · composed</option>
            <option value="leo">Leo · warm</option>
            <option value="rex">Rex · direct</option>
            <option value="sal">Sal · conversational</option>
          </select>
        </label>
        <div class="panel-actions">
          {#if connections?.openrouter.connected}
            <button class="secondary-button danger-button" onclick={() => disconnect('openrouter')} disabled={busy}>
              Disconnect OpenRouter
            </button>
          {:else}
            <button class="primary-button" onclick={() => connect('openrouter')} disabled={busy}>
              {#if busy}<LoaderCircle class="spin" />{:else}<Link />{/if}
              Connect OpenRouter
            </button>
          {/if}
        </div>
      </section>

      {#if selectedEntry}
        <section class="settings-card">
          <div class="settings-card-heading">
            <div class="provider-mark"><FileText /></div>
            <div>
              <h3>Current document</h3>
              <p>{selectedEntry.title}</p>
            </div>
          </div>

          {#if editing}
            <textarea class="document-editor" bind:value={editorText}></textarea>
            <div class="panel-actions">
              <button class="secondary-button" onclick={() => {
                editing = false;
                editorText = selectedText;
              }}>Cancel</button>
              <button class="primary-button" onclick={save} disabled={busy}>
                <Check /> Save
              </button>
            </div>
          {:else}
            <div class="panel-actions">
              <button class="secondary-button" onclick={() => {
                window.sharedLibrary.revealEntry(selectedEntry!.id);
              }}>
                <FolderOpen /> Reveal
              </button>
              <button class="secondary-button" onclick={beginEditing}>
                <Pencil /> Edit
              </button>
              <button class="secondary-button" onclick={shareDocument} disabled={shareBusy}>
                {#if shareBusy}<LoaderCircle class="spin" />{:else}<Copy />{/if}
                {share.shared ? 'Copy link' : 'Share'}
              </button>
              {#if share.shared && share.token}
                <button class="secondary-button danger-button" onclick={revokeShare}>
                  Revoke link
                </button>
              {/if}
              <button class="secondary-button danger-button" onclick={trashSelected}>
                <Trash2 /> Trash
              </button>
            </div>
          {/if}
        </section>
      {/if}

      <section class="settings-card muted-card">
        <div class="settings-card-heading">
          <div class="provider-mark"><Sparkles /></div>
          <div>
            <h3>Capture processing</h3>
            <p>
              Clipboard links are extracted and every new capture is assigned a topic
              with four summary levels by the local Codex installation.
            </p>
          </div>
        </div>
      </section>
    </div>
  </aside>
{/if}
