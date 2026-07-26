<script lang="ts">
  import {
    Archive,
    ArrowUpRight,
    Check,
    ChevronLeft,
    Clipboard,
    Copy,
    FileText,
    FolderOpen,
    Headphones,
    Keyboard,
    LoaderCircle,
    LogIn,
    Pause,
    Pencil,
    Play,
    Plus,
    RefreshCw,
    RotateCcw,
    Search,
    Settings2,
    Share2,
    Sparkles,
    Trash2,
    X
  } from '@lucide/svelte';
  import DepthControl from './DepthControl.svelte';
  import MarkdownView from './MarkdownView.svelte';
  import appIcon from './assets/app-icon.png';
  import { shouldRenderSourceAsPlainText } from '../shared/source-presentation';
  import type {
    AccountProvider,
    DesktopLibraryEntry,
    DesktopLibrarySnapshot,
    DesktopConnectionStatus,
    DesktopIngestionStatus,
    DesktopShortcutPreferences,
    DesktopSyncStatus,
    LibraryVariant,
    NarrationLoadingPhase,
    NarrationSegment,
    NarrationStatus,
    OpenRouterTTSModel,
    OpenRouterVoice,
    ProcessingPreferences,
    TopicDefinition,
    ShareLinkStatus
  } from '../shared/contracts';
  import {
    captureShortcutFromKeyboardEvent,
    formatCaptureShortcut
  } from '../shared/shortcuts';
  import {
    defaultOpenRouterTTSModel,
    normalizeOpenRouterTTSModel,
    openRouterTTSModels,
    openRouterVoiceName,
    voicesForTTSModel
  } from '../shared/contracts';

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
    message: 'Sign in and choose a sync service.'
  });
  let voice = $state<OpenRouterVoice>('af_heart');
  let ttsModel = $state<OpenRouterTTSModel>(defaultOpenRouterTTSModel);
  let narrationState = $state<'idle' | 'loading' | 'playing' | 'paused'>('idle');
  let narrationLoadingPhase = $state<NarrationLoadingPhase>('checking');
  let narrationRequestID = 0;
  let narrationSessionID = $state('');
  let narrationSegments = $state<string[]>([]);
  let narrationIndex = $state(0);
  let narrationTotal = $state(0);
  let narrationProgress = $state(0);
  let narrationProgressFrame = 0;
  let narrationAudio: HTMLAudioElement | null = null;
  let share = $state<ShareLinkStatus>({ shared: false });
  let shareBusy = $state(false);
  let processingPreferences = $state<ProcessingPreferences | null>(null);
  let processingPromptDraft = $state('');
  let processingTopicsDraft = $state<TopicDefinition[]>([]);
  let shortcutPreferences = $state<DesktopShortcutPreferences | null>(null);
  let shortcutRecording = $state(false);
  let shortcutSaving = $state(false);
  let ingestion = $state<DesktopIngestionStatus>({
    phase: 'idle',
    activeCount: 0,
    message: 'All sources are ready.'
  });

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
  let renderSelectedTextAsPlain = $derived(
    shouldRenderSourceAsPlainText(selectedVariant, selectedEntry?.sourceURL)
  );
  let wordCount = $derived(
    selectedText.trim() ? selectedText.trim().split(/\s+/).length : 0
  );
  let narrationLoadingLabel = $derived(
    narrationLoadingPhase === 'generating'
      ? 'Generating voice'
      : narrationLoadingPhase === 'downloading'
        ? 'Downloading audio'
        : 'Checking audio'
  );
  let currentTTSOption = $derived(
    openRouterTTSModels.find((option) => option.id === ttsModel) ??
      openRouterTTSModels[0]
  );
  let captureShortcutLabel = $derived(
    shortcutRecording
      ? 'Press your shortcut…'
      : formatCaptureShortcut(
          shortcutPreferences?.captureShortcut ?? 'CommandOrControl+G',
          snapshot?.platform ?? 'darwin'
        )
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

  $effect(() => {
    const currentMessage = message;
    if (!currentMessage) return;
    const timeout = window.setTimeout(() => {
      if (message === currentMessage) message = '';
    }, 6_000);
    return () => window.clearTimeout(timeout);
  });

  void initialize();

  async function initialize(): Promise<void> {
    try {
      applySnapshot(await window.sharedLibrary.getSnapshot());
      connections = await window.sharedLibrary.getConnectionStatus();
      syncStatus = connections.sync;
      voice = connections.voice;
      ttsModel = connections.ttsModel;
      applyProcessingPreferences(
        await window.sharedLibrary.getProcessingPreferences()
      );
      shortcutPreferences = await window.sharedLibrary.getShortcutPreferences();
      ingestion = await window.sharedLibrary.getIngestionStatus();
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
      const removeIngestionListener =
        window.sharedLibrary.onIngestionStatus((status) => {
          ingestion = status;
        });
      const removeNarrationListener =
        window.sharedLibrary.onNarrationSegment(receiveNarrationSegment);
      const removeNarrationStatusListener =
        window.sharedLibrary.onNarrationStatus(receiveNarrationStatus);
      narrationAudio = new Audio();
      narrationAudio.playbackRate = playbackRate;
      narrationAudio.addEventListener('ended', advanceNarration);
      narrationAudio.addEventListener('play', () => {
        narrationState = 'playing';
        window.cancelAnimationFrame(narrationProgressFrame);
        updateNarrationProgress();
      });
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
          removeIngestionListener();
          removeNarrationListener();
          removeNarrationStatusListener();
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

  function selectVariant(variant: LibraryVariant): void {
    stopNarration();
    selectedVariant = variant;
    editing = false;
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
        applyProcessingPreferences(
          await window.sharedLibrary.getProcessingPreferences()
        );
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

  async function launchAgent(): Promise<void> {
    try {
      await window.sharedLibrary.openAgent();
      message = 'Opened this library workspace in Codex.';
    } catch (error) {
      message = error instanceof Error ? error.message : 'Codex could not be opened.';
    }
  }

  function showEntryContextMenu(
    event: MouseEvent,
    entry: DesktopLibraryEntry,
    variant: LibraryVariant = 'source'
  ): void {
    event.preventDefault();
    if (selectedEntry?.id !== entry.id) selectEntry(entry);
    void window.sharedLibrary.showEntryContextMenu(entry.id, variant);
  }

  async function signIn(provider: AccountProvider): Promise<void> {
    await run(async () => {
      connections = await window.sharedLibrary.signIn(provider);
      syncStatus = connections.sync;
      message = `Signed in with ${provider === 'apple' ? 'Apple' : 'Google'}.`;
    });
  }

  async function refreshAccount(): Promise<void> {
    await run(async () => {
      connections = await window.sharedLibrary.getConnectionStatus();
      syncStatus = connections.sync;
      message = connections.entitled
        ? 'Your Briefly membership is active.'
        : 'An active Briefly membership is still required.';
    });
  }

  async function openAccount(): Promise<void> {
    await run(async () => {
      connections = await window.sharedLibrary.manageAccount();
      syncStatus = connections.sync;
      message = 'Account settings refreshed.';
    });
  }

  async function changeVoice(event: Event): Promise<void> {
    const input = event.currentTarget as HTMLSelectElement;
    try {
      connections = await window.sharedLibrary.setVoice(input.value);
      voice = connections.voice;
      input.value = voice;
    } catch (error) {
      input.value = voice;
      message =
        error instanceof Error ? error.message : 'The narration voice could not be changed.';
    }
  }

  async function changeTTSModel(event: Event): Promise<void> {
    const input = event.currentTarget as HTMLSelectElement;
    try {
      const selected = normalizeOpenRouterTTSModel(input.value);
      if (!selected) throw new Error('Choose Low, Medium, or High narration quality.');
      connections = await window.sharedLibrary.setTTSModel(selected);
      ttsModel = connections.ttsModel;
      voice = connections.voice;
      input.value = ttsModel;
      const option = openRouterTTSModels.find((candidate) => candidate.id === ttsModel);
      message = `${option?.quality ?? 'Selected'} quality selected for new narration.`;
    } catch (error) {
      input.value = ttsModel;
      message =
        error instanceof Error
          ? error.message
          : 'The AI voice quality could not be changed.';
    }
  }

  function recordCaptureShortcut(event: KeyboardEvent): void {
    event.preventDefault();
    event.stopPropagation();
    if (event.key === 'Escape' && !event.metaKey && !event.ctrlKey && !event.altKey) {
      shortcutRecording = false;
      (event.currentTarget as HTMLInputElement).blur();
      return;
    }
    const next = captureShortcutFromKeyboardEvent(
      event,
      snapshot?.platform ?? 'darwin'
    );
    if (!next) {
      if (!['Meta', 'Control', 'Alt', 'Shift'].includes(event.key)) {
        message = 'Use Ctrl, Command, or Alt with a letter, number, F-key, or navigation key.';
      }
      return;
    }
    shortcutRecording = false;
    (event.currentTarget as HTMLInputElement).blur();
    void saveCaptureShortcut(next);
  }

  async function saveCaptureShortcut(accelerator: string): Promise<void> {
    if (shortcutSaving) return;
    shortcutSaving = true;
    try {
      shortcutPreferences =
        await window.sharedLibrary.setCaptureShortcut(accelerator);
      message = `Capture shortcut changed to ${formatCaptureShortcut(
        shortcutPreferences.captureShortcut,
        snapshot?.platform ?? 'darwin'
      )}.`;
    } catch (error) {
      message =
        error instanceof Error ? error.message : 'The capture shortcut could not be changed.';
    } finally {
      shortcutSaving = false;
    }
  }

  function applyProcessingPreferences(next: ProcessingPreferences): void {
    processingPreferences = next;
    processingPromptDraft = next.prompt;
    processingTopicsDraft = next.topics.map((topic) => ({ ...topic }));
  }

  function addProcessingTopic(): void {
    processingTopicsDraft.push({ id: '', title: '' });
  }

  function removeProcessingTopic(index: number): void {
    processingTopicsDraft.splice(index, 1);
  }

  async function saveProcessingPreferences(): Promise<void> {
    await run(async () => {
      const next = await window.sharedLibrary.updateProcessingPreferences({
        topics: processingTopicsDraft.map((topic) => ({ ...topic })),
        prompt: processingPromptDraft
      });
      applyProcessingPreferences(next);
      message = 'Topics and summarization prompt saved.';
    });
  }

  async function listen(): Promise<void> {
    if (!selectedEntry || !narrationAudio) return;
    if (narrationState === 'loading') {
      stopNarration();
      return;
    }
    if (narrationState === 'playing') {
      narrationState = 'paused';
      narrationAudio.pause();
      return;
    }
    if (narrationState === 'paused' && narrationAudio.src) {
      await narrationAudio.play();
      return;
    }
    if (!connections?.authenticated) {
      settingsOpen = true;
      message = 'Sign in to use Briefly AI voice.';
      return;
    }
    if (!connections.tts.configured || connections.tts.balanceMicros === 0) {
      settingsOpen = true;
      message = 'Add AI voice credit from your Briefly account.';
      return;
    }
    narrationState = 'loading';
    narrationLoadingPhase = 'checking';
    narrationProgress = 0;
    const requestID = ++narrationRequestID;
    try {
      const session = await window.sharedLibrary.startNarration(
        selectedEntry.id,
        selectedVariant,
        voice
      );
      if (requestID !== narrationRequestID || narrationState !== 'loading') return;
      narrationSessionID = session.sessionID;
      narrationTotal = session.total;
      narrationIndex = 0;
      narrationSegments = [];
      narrationSegments[0] = session.first.url;
      await playNarrationIndex(0);
    } catch (error) {
      if (requestID !== narrationRequestID) return;
      narrationState = 'idle';
      message = error instanceof Error ? error.message : 'Narration could not be started.';
    }
  }

  function receiveNarrationStatus(status: NarrationStatus): void {
    if (narrationState !== 'loading') return;
    if (narrationSessionID && status.sessionID !== narrationSessionID) return;
    narrationLoadingPhase = status.phase;
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
    const next = narrationIndex + 1;
    if (next >= narrationTotal) {
      narrationState = 'idle';
      narrationIndex = 0;
      return;
    }
    narrationProgress = next / Math.max(narrationTotal, 1);
    narrationIndex = next;
    void playNarrationIndex(next);
  }

  function updateNarrationProgress(): void {
    if (narrationState !== 'playing' || !narrationAudio) return;
    if (Number.isFinite(narrationAudio.duration) && narrationAudio.duration > 0) {
      narrationProgress =
        (narrationIndex + narrationAudio.currentTime / narrationAudio.duration) /
        Math.max(narrationTotal, 1);
    }
    narrationProgressFrame = window.requestAnimationFrame(updateNarrationProgress);
  }

  function stopNarration(): void {
    narrationRequestID += 1;
    window.cancelAnimationFrame(narrationProgressFrame);
    narrationAudio?.pause();
    if (narrationAudio) narrationAudio.removeAttribute('src');
    narrationSessionID = '';
    narrationSegments = [];
    narrationState = 'idle';
    narrationLoadingPhase = 'checking';
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
  <title>Briefly</title>
</svelte:head>

<div class="app-shell">
  {#if loading}
    <main class="center-stage" aria-live="polite">
      <div class="launch-sequence">
        <div class="loading-mark" aria-hidden="true">
          <span class="loading-halo"></span>
          <img src={appIcon} alt="" />
        </div>
        <p class="loading-title">Opening your library</p>
        <p class="loading-copy">Preparing the local collection</p>
        <div class="loading-dots" aria-hidden="true"><span></span><span></span><span></span></div>
      </div>
    </main>
  {:else if !connections?.authenticated}
    <main class="center-stage">
      <section class="empty-card">
        <div class="empty-illustration">
          <LogIn />
          <span class="empty-check"><Check /></span>
        </div>
        <p class="eyebrow">Briefly account</p>
        <h1>Sign in to continue</h1>
        <p class="empty-copy">
          Sign in manages your Briefly membership and AI voice credit. You will choose
          sync separately.
        </p>
        <div class="empty-actions">
          <button class="primary-button" onclick={() => signIn('apple')} disabled={busy}>
            {#if busy}<LoaderCircle class="spin" />{:else}<LogIn />{/if}
            Sign in with Apple
          </button>
          <button class="secondary-button" onclick={() => signIn('google')} disabled={busy}>
            {#if busy}<LoaderCircle class="spin" />{:else}<LogIn />{/if}
            Sign in with Google
          </button>
        </div>
      </section>
    </main>
  {:else if !connections.entitled}
    <main class="center-stage">
      <section class="empty-card">
        <div class="empty-illustration">
          <Sparkles />
          <span class="empty-check"><Check /></span>
        </div>
        <p class="eyebrow">Briefly membership</p>
        <h1>Activate your account</h1>
        <p class="empty-copy">
          Choose your plan and manage billing on the web, then refresh access here.
        </p>
        <div class="empty-actions">
          <button class="primary-button" onclick={openAccount}>
            <ArrowUpRight /> Open account
          </button>
          <button class="secondary-button" onclick={refreshAccount} disabled={busy}>
            <RefreshCw class={busy ? 'spin' : ''} /> Refresh access
          </button>
        </div>
      </section>
    </main>
  {:else if entries.length === 0}
    <main class="center-stage">
      <section class="empty-card">
        <div class="empty-illustration">
          <Archive />
          <span class="empty-check"><Check /></span>
        </div>
        <p class="eyebrow">Briefly</p>
        <h1>Your library is ready</h1>
        <p class="empty-copy">
          Capture clipboard text or choose an existing Briefly workspace.
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
                oncontextmenu={(event) => showEntryContextMenu(event, entry)}
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
            onclick={launchAgent}
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
            <article
              class="native-document-body"
              aria-busy={loadingText}
              oncontextmenu={(event) =>
                showEntryContextMenu(event, selectedEntry!, selectedVariant)}
            >
              {#if loadingText}
                <div class="document-skeleton" aria-label="Loading document">
                  <span class="skeleton-heading"></span>
                  <span class="skeleton-line long"></span>
                  <span class="skeleton-line"></span>
                  <span class="skeleton-line medium"></span>
                  <span class="skeleton-gap"></span>
                  <span class="skeleton-line long"></span>
                  <span class="skeleton-line"></span>
                  <span class="skeleton-line short"></span>
                </div>
              {:else if selectedText}
                <MarkdownView text={selectedText} plain={renderSelectedTextAsPlain} />
              {:else}
                <p class="missing-text">This version is not available.</p>
              {/if}
            </article>
          </div>

          <footer class="native-document-footer">
            <div
              class="native-player-progress"
              class:visible={narrationState === 'playing'}
              style={`--progress: ${narrationProgress * 100}%`}
            ></div>
            <div class="footer-stat">{wordCount.toLocaleString()} words</div>

            <DepthControl
              variants={availableVariants}
              selected={selectedVariant}
              onselect={selectVariant}
            />

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
                class="native-play-button"
                class:loading={narrationState === 'loading'}
                aria-label={narrationState === 'loading'
                  ? `Cancel ${narrationLoadingLabel.toLowerCase()}`
                  : narrationState === 'playing'
                    ? 'Pause'
                    : 'Play'}
                title={narrationState === 'loading'
                  ? narrationLoadingLabel
                  : narrationState === 'playing'
                    ? 'Pause'
                    : 'Play'}
                onclick={listen}
              >
                {#if narrationState === 'loading'}
                  <span class="narration-loading-wave" aria-hidden="true">
                    <span></span><span></span><span></span><span></span>
                  </span>
                  <span class="narration-loading-label">{narrationLoadingLabel}</span>
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

  {#if ingestion.phase === 'processing' || message}
    <div class="notification-stack">
      {#if ingestion.phase === 'processing'}
        <div class="ingestion-indicator" role="status" aria-live="polite">
          <LoaderCircle class="spin" />
          <span>{ingestion.message} Extracting and preparing summaries.</span>
        </div>
      {/if}
      {#if message}
        <div
          class="toast"
          class:error={message.includes('failed') || message.includes('could not')}
          role="status"
          aria-live="polite"
        >
          <span>{message}</span>
          <button aria-label="Dismiss message" onclick={() => (message = '')}><X /></button>
        </div>
      {/if}
    </div>
  {/if}
</div>

{#if settingsOpen}
  <div class="audio-backdrop" role="presentation" onclick={() => (settingsOpen = false)}></div>
  <aside class="audio-panel connections-panel" aria-label="Settings">
    <div class="audio-header">
      <div>
        <p class="eyebrow">Desktop</p>
        <h2>Settings</h2>
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
          <div class="provider-mark"><Keyboard /></div>
          <div>
            <h3>Capture shortcut</h3>
            <p>Press a new key combination to capture the clipboard from anywhere.</p>
          </div>
        </div>
        <div class="shortcut-controls">
          <input
            class:recording={shortcutRecording}
            aria-label="Capture shortcut"
            value={captureShortcutLabel}
            readonly
            onfocus={() => (shortcutRecording = true)}
            onblur={() => (shortcutRecording = false)}
            onkeydown={recordCaptureShortcut}
          />
          <button
            class="secondary-button"
            type="button"
            disabled={shortcutSaving ||
              !shortcutPreferences ||
              shortcutPreferences.captureShortcut ===
                shortcutPreferences.defaultCaptureShortcut}
            onclick={() => {
              if (shortcutPreferences) {
                void saveCaptureShortcut(shortcutPreferences.defaultCaptureShortcut);
              }
            }}
          >
            {#if shortcutSaving}<LoaderCircle class="spin" />{/if}
            Reset
          </button>
        </div>
        <p class="shortcut-status">
          {#if shortcutPreferences?.registered}
            Active system-wide. Click the field and press the replacement shortcut.
          {:else}
            The system-wide shortcut is unavailable; Capture remains in the File menu.
          {/if}
        </p>
      </section>

      <section class="settings-card">
        <div class="settings-card-heading">
          <div>
            <h3>Briefly account</h3>
            <p>Manage membership, AI voice credit, and library sync on the web.</p>
          </div>
        </div>
        <div class="connection-status">
          {#if connections?.syncProvider}
            <span class="status-dot"></span>
          {/if}
          <span>
            {connections?.syncProvider
              ? syncStatus.message
              : 'Choose iCloud or Google Drive for sync.'}
          </span>
          {#if connections?.syncProvider &&
          (syncStatus.phase === 'checking' || syncStatus.phase === 'downloading' || syncStatus.phase === 'uploading')}
            <LoaderCircle class="spin" />
          {/if}
        </div>
        <div class="panel-actions">
          <button class="secondary-button" onclick={openAccount} disabled={busy}>
            <ArrowUpRight /> Manage account and sync
          </button>
        </div>
      </section>

      <section class="settings-card">
        <div class="settings-card-heading">
          <div class="provider-mark"><Headphones /></div>
          <div>
            <h3>Narration</h3>
            <p>
              Briefly AI voice uses prepaid account credit. Audio streams as it is
              generated, caches locally, and is backed up to your selected sync service.
            </p>
          </div>
        </div>
        <label class="voice-field">
          <span>Quality</span>
          <select
            value={ttsModel}
            aria-label="Narration quality"
            onchange={changeTTSModel}
          >
            {#each openRouterTTSModels as option}
              <option value={option.id}>{option.quality}</option>
            {/each}
          </select>
          <small>{currentTTSOption.description}</small>
        </label>
        <label class="voice-field">
          <span>Voice</span>
          <select
            value={voice}
            aria-label="AI voice narrator"
            onchange={changeVoice}
          >
            {#each voicesForTTSModel(ttsModel) as option}
              <option value={option}>{openRouterVoiceName(option)}</option>
            {/each}
          </select>
        </label>
        <div class="connection-status">
          <span class="status-dot"></span>
          <span>
            {new Intl.NumberFormat(undefined, {
              style: 'currency',
              currency: 'EUR',
              minimumFractionDigits: 2,
              maximumFractionDigits: 4
            }).format((connections?.tts.balanceMicros ?? 0) / 100_000_000)}
            AI voice credit
          </span>
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

      <section class="settings-card">
        <div class="settings-card-heading">
          <div class="provider-mark"><Sparkles /></div>
          <div>
            <h3>Capture processing</h3>
            <p>
              These topics and this prompt are sent to Codex for every future capture.
              Existing summaries are unchanged.
            </p>
          </div>
        </div>

        <div class="processing-field-heading">
          <div>
            <span>Topics</span>
            <small>Rename existing topics or add reusable ones.</small>
          </div>
          <button
            class="processing-add-button"
            type="button"
            onclick={addProcessingTopic}
          >
            <Plus /> Add topic
          </button>
        </div>

        <div class="processing-topic-list">
          {#each processingTopicsDraft as topic, index (topic.id || index)}
            <div class="processing-topic-row">
              <div>
                <input
                  aria-label={`Topic ${index + 1} title`}
                  value={topic.title}
                  placeholder="Topic name"
                  oninput={(event) => {
                    processingTopicsDraft[index].title =
                      (event.currentTarget as HTMLInputElement).value;
                  }}
                />
                <small>{topic.id || 'ID created when saved'}</small>
              </div>
              <button
                type="button"
                aria-label={`Remove ${topic.title || `topic ${index + 1}`}`}
                title="Remove topic"
                onclick={() => removeProcessingTopic(index)}
              >
                <X />
              </button>
            </div>
          {/each}
          {#if processingTopicsDraft.length === 0}
            <p class="processing-empty">No topics yet. Codex can create one during processing.</p>
          {/if}
        </div>

        <label class="processing-prompt-field">
          <span>Summarization prompt</span>
          <small>
            This is the exact template sent to Codex. Keep
            <code>{'{{topics}}'}</code> and <code>{'{{source}}'}</code> where the
            current taxonomy and capture should be inserted.
          </small>
          <textarea bind:value={processingPromptDraft} spellcheck="false"></textarea>
        </label>

        <div class="panel-actions processing-actions">
          <button
            class="secondary-button"
            type="button"
            disabled={busy || !processingPreferences}
            onclick={() => {
              if (processingPreferences) {
                processingPromptDraft = processingPreferences.defaultPrompt;
              }
            }}
          >
            <RotateCcw /> Reset prompt
          </button>
          <button
            class="primary-button"
            type="button"
            disabled={busy || !processingPreferences}
            onclick={saveProcessingPreferences}
          >
            {#if busy}<LoaderCircle class="spin" />{:else}<Check />{/if}
            Save processing settings
          </button>
        </div>
      </section>
    </div>
  </aside>
{/if}
