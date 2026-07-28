<script lang="ts">
  import { onMount } from 'svelte';
  import {
    Archive,
    ArrowUpRight,
    Check,
    ChevronLeft,
    Clipboard,
    Cog,
    FileText,
    Folder,
    FolderOpen,
    Headphones,
    Keyboard,
    LoaderCircle,
    LogIn,
    Palette,
    Plus,
    RefreshCw,
    RotateCcw,
    Search,
    Share2,
    Sparkles,
    X
  } from '@lucide/svelte';
  import AudioPlayer from './AudioPlayer.svelte';
  import DepthControl from './DepthControl.svelte';
  import MarkdownView from './MarkdownView.svelte';
  import PodcastsView from './PodcastsView.svelte';
  import appIcon from './assets/app-icon.png';
  import {
    shouldRenderSourceAsPlainText
  } from '../shared/source-presentation';
  import type {
    AccountProvider,
    DesktopAudioPreferences,
    DesktopLibraryEntry,
    DesktopLibrarySnapshot,
    DesktopConnectionStatus,
    DesktopIngestionStatus,
    DesktopOperationResult,
    DesktopShortcutPreferences,
    DesktopSyncStatus,
    LibraryVariant,
    PodcastSnapshot,
    PromptID,
    PromptPreferences,
    ProcessingPreferences,
    TopicDefinition
  } from '../shared/contracts';
  import {
    captureShortcutFromKeyboardEvent,
    formatCaptureShortcut
  } from '../shared/shortcuts';
  import {
    initializeTheme,
    readThemePreference,
    setThemePreference,
    themeModeOptions,
    themeOptions,
    type ThemeMode,
    type ThemeName
  } from '../../../Shared/themes';
  type SettingsTab =
    | 'general'
    | 'topics'
    | 'prompt-summarization'
    | 'prompt-podcast'
    | 'podcasts';
  let snapshot = $state<DesktopLibrarySnapshot | null>(null);
  let podcastSnapshot = $state<PodcastSnapshot | null>(null);
  let activeView = $state<'library' | 'podcasts'>('library');
  let selectedID = $state('');
  let selectedIDs = $state<string[]>([]);
  let selectedVariant = $state<LibraryVariant>('concise');
  let selectedText = $state('');
  let query = $state('');
  let selectedTopic = $state('all');
  let selectedPodcastID = $state('all');
  let expandedEpisodeIDs = $state<string[]>([]);
  let loading = $state(true);
  let loadingText = $state(false);
  let busy = $state(false);
  let message = $state('');
  let settingsOpen = $state(false);
  let settingsTab = $state<SettingsTab>('general');
  let promptsExpanded = $state(true);
  let mobileReaderVisible = $state(false);
  let connections = $state<DesktopConnectionStatus | null>(null);
  let syncStatus = $state<DesktopSyncStatus>({
    phase: 'idle',
    message: 'Sign in and choose a sync service.'
  });
  let shareBusy = $state(false);
  let processingTopicsDraft = $state<TopicDefinition[]>([]);
  let promptPreferences = $state<PromptPreferences | null>(null);
  let promptDrafts = $state<Record<PromptID, string>>({
    summarization: '',
    podcast: ''
  });
  let shortcutPreferences = $state<DesktopShortcutPreferences | null>(null);
  let audioPreferences = $state<DesktopAudioPreferences | null>(null);
  let shortcutRecording = $state(false);
  let shortcutSaving = $state(false);
  let audioPreferenceSaving = $state(false);
  let draggingPDF = $state(false);
  let themePreference = $state(readThemePreference());
  let ingestion = $state<DesktopIngestionStatus>({
    phase: 'idle',
    activeCount: 0,
    message: 'All sources are ready.'
  });

  let entries = $derived(snapshot?.entries ?? []);
  let podcastNoteEntries = $derived(
    entries.filter((entry) => entry.entryType !== 'podcast_episode')
  );
  let noteEntries = $derived(
    podcastNoteEntries.filter((entry) => entry.entryType !== 'podcast_source')
  );
  let selectedEntry = $derived(
    entries.find((entry) => entry.id === selectedID) ?? null
  );
  let normalizedQuery = $derived(query.trim().toLowerCase());
  let filteredEntries = $derived(
    noteEntries.filter((entry) => {
      if (selectedTopic !== 'all' && !entry.topicNames.includes(selectedTopic)) return false;
      if (!normalizedQuery) return true;
      return [entry.title, entry.excerpt, ...entry.topicNames, ...entry.tags]
        .join(' ')
        .toLowerCase()
        .includes(normalizedQuery);
    })
  );
  let podcastGroups = $derived.by(() =>
    (podcastSnapshot?.podcasts ?? [])
      .filter((podcast) =>
        selectedPodcastID === 'all' || podcast.id === selectedPodcastID)
      .flatMap((podcast) =>
        podcast.episodes
          .map((episode) => {
            const sourceIDs = new Set(episode.sourceIDs ?? []);
            const sourceURLs = new Set(episode.sourceURLs ?? []);
            const notes = podcastNoteEntries.filter(
              (entry) =>
                sourceIDs.has(entry.id) ||
                Boolean(entry.sourceURL && sourceURLs.has(entry.sourceURL))
            );
            return { podcast, episode, notes };
          })
          .filter(({ podcast: owner, episode, notes }) =>
            !normalizedQuery ||
            [owner.title, episode.title, episode.excerpt, ...notes.map((note) => note.title)]
              .join(' ')
              .toLowerCase()
              .includes(normalizedQuery)
          )
      )
  );
  let availableVariants = $derived(selectedEntry?.availableVariants ?? []);
  let renderSelectedTextAsPlain = $derived(
    shouldRenderSourceAsPlainText(selectedVariant, selectedEntry?.sourceURL)
  );
  let selectedSourceMediaURL = $derived(
    selectedVariant === 'source' ? selectedEntry?.mediaURL : undefined
  );
  let wordCount = $derived(
    selectedText.trim() ? selectedText.trim().split(/\s+/).length : 0
  );
  let captureShortcutLabel = $derived(
    shortcutRecording
      ? 'Press your shortcut…'
      : formatCaptureShortcut(
          shortcutPreferences?.captureShortcut ?? 'CommandOrControl+G',
          snapshot?.platform ?? 'darwin'
        )
  );
  let selectedPromptID = $derived(promptIDForTab(settingsTab));
  let selectedPrompt = $derived(
    promptPreferences?.prompts.find(({ id }) => id === selectedPromptID) ?? null
  );
  let settingsTitle = $derived(
    settingsTab === 'general'
      ? 'General'
      : settingsTab === 'topics'
        ? 'Topics'
        : settingsTab === 'podcasts'
          ? 'Podcasts'
          : (selectedPrompt?.title ?? 'Prompts')
  );

  onMount(initializeTheme);

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

  $effect(() => {
    if (
      activeView === 'library' &&
      selectedEntry &&
      !noteEntries.some((entry) => entry.id === selectedEntry?.id)
    ) {
      selectedID = noteEntries[0]?.id ?? '';
      selectedIDs = selectedID ? [selectedID] : [];
    }
  });

  void initialize();

  async function initialize(): Promise<void> {
    try {
      podcastSnapshot = await window.sharedLibrary.getPodcasts();
      applySnapshot(await window.sharedLibrary.getSnapshot());
      connections = await window.sharedLibrary.getConnectionStatus();
      syncStatus = connections.sync;
      applyProcessingPreferences(
        await window.sharedLibrary.getProcessingPreferences()
      );
      applyPromptPreferences(await window.sharedLibrary.getPromptPreferences());
      shortcutPreferences = await window.sharedLibrary.getShortcutPreferences();
      audioPreferences = await window.sharedLibrary.getAudioPreferences();
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
            selectedIDs = [result.selectedEntryID];
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
      const removePodcastsListener =
        window.sharedLibrary.onPodcastsChanged((next) => {
          podcastSnapshot = next;
          if (
            selectedPodcastID !== 'all' &&
            !next.podcasts.some((podcast) => podcast.id === selectedPodcastID)
          ) {
            selectedPodcastID = 'all';
          }
        });
      window.addEventListener(
        'beforeunload',
        () => {
          removeLibraryListener();
          removeWorkspaceListener();
          removeMessageListener();
          removeSyncListener();
          removeIngestionListener();
          removePodcastsListener();
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
    const previousEntry = next.entries.find((entry) => entry.id === previousSelection);
    selectedID =
      previousEntry &&
      (activeView === 'podcasts' || previousEntry.entryType !== 'podcast_episode')
        ? previousSelection
        : (next.entries.find((entry) => entry.entryType !== 'podcast_episode')?.id ?? '');
    selectedIDs = selectedIDs.filter((id) =>
      next.entries.some((entry) => entry.id === id)
    );
    if (selectedID && selectedIDs.length === 0) selectedIDs = [selectedID];
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
      }
    } catch (error) {
      message = error instanceof Error ? error.message : 'The document could not be read.';
    } finally {
      loadingText = false;
    }
  }

  function selectEntry(entry: DesktopLibraryEntry): void {
    selectedIDs = [entry.id];
    activateEntry(entry);
  }

  function activateEntry(entry: DesktopLibraryEntry): void {
    selectedID = entry.id;
    selectedVariant = entry.availableVariants.includes('concise')
      ? 'concise'
      : (entry.availableVariants[0] ?? 'source');
    mobileReaderVisible = true;
  }

  function selectSidebarEntry(event: MouseEvent | PointerEvent, entry: DesktopLibraryEntry): void {
    if (event.metaKey || event.ctrlKey) {
      if (selectedIDs.includes(entry.id)) {
        selectedIDs = selectedIDs.filter((id) => id !== entry.id);
        if (selectedID === entry.id) {
          const next = entries.find(({ id }) => id === selectedIDs.at(-1));
          if (next) activateEntry(next);
          else selectedID = '';
        }
      } else {
        selectedIDs = [...selectedIDs, entry.id];
        activateEntry(entry);
      }
      return;
    }
    selectEntry(entry);
  }

  function extendSidebarSelection(event: PointerEvent, entry: DesktopLibraryEntry): void {
    if (event.buttons !== 1 || selectedIDs.includes(entry.id)) return;
    selectedIDs = [...selectedIDs, entry.id];
    activateEntry(entry);
  }

  function selectTopic(topic: string): void {
    selectedTopic = topic;
    window.localStorage.setItem('shared-library-selected-topic', topic);
  }

  function selectView(view: 'library' | 'podcasts'): void {
    activeView = view;
    query = '';
    if (view === 'library') {
      if (selectedEntry?.entryType === 'podcast_episode') {
        selectedID = noteEntries[0]?.id ?? '';
      }
    } else if (!podcastGroups.some(
      ({ episode, notes }) =>
        episode.id === selectedID || notes.some((note) => note.id === selectedID)
    )) {
      selectedID = podcastGroups[0]?.episode.id ?? '';
    }
    selectedIDs = selectedID ? [selectedID] : [];
    mobileReaderVisible = false;
  }

  function selectPodcast(podcastID: string): void {
    selectedPodcastID = podcastID;
    const podcast = podcastSnapshot?.podcasts.find(({ id }) => id === podcastID);
    selectedID =
      (podcastID === 'all'
        ? podcastSnapshot?.podcasts.flatMap(({ episodes }) => episodes)[0]?.id
        : podcast?.episodes[0]?.id) ?? '';
    selectedIDs = selectedID ? [selectedID] : [];
    mobileReaderVisible = false;
  }

  function togglePodcastEpisode(entry: DesktopLibraryEntry): void {
    expandedEpisodeIDs = expandedEpisodeIDs.includes(entry.id)
      ? expandedEpisodeIDs.filter((id) => id !== entry.id)
      : [...expandedEpisodeIDs, entry.id];
  }

  function openSettings(tab: SettingsTab = 'general'): void {
    settingsTab = tab;
    settingsOpen = true;
  }

  function selectVariant(variant: LibraryVariant): void {
    selectedVariant = variant;
  }

  function updateTheme(theme?: ThemeName, mode?: ThemeMode): void {
    themePreference = {
      theme: theme ?? themePreference.theme,
      mode: mode ?? themePreference.mode
    };
    setThemePreference(themePreference);
  }

  async function refresh(): Promise<void> {
    await run(async () => {
      applySnapshot(await window.sharedLibrary.refresh());
      message = 'Library refreshed.';
    });
  }

  async function captureClipboard(): Promise<void> {
    await run(async () => {
      applyCaptureResult(await window.sharedLibrary.captureClipboard());
    });
  }

  function applyCaptureResult(result: DesktopOperationResult): void {
    applySnapshot(result.snapshot);
    if (result.selectedEntryID) {
      selectedID = result.selectedEntryID;
      selectedIDs = [result.selectedEntryID];
      mobileReaderVisible = true;
    }
    message = result.message;
  }

  function handleFileDrag(event: DragEvent): void {
    if (!connections?.entitled || !event.dataTransfer?.types.includes('Files')) return;
    event.preventDefault();
    draggingPDF = true;
  }

  function handleFileDragLeave(event: DragEvent): void {
    if (!event.relatedTarget) draggingPDF = false;
  }

  async function handleFileDrop(event: DragEvent): Promise<void> {
    if (!connections?.entitled || !event.dataTransfer?.types.includes('Files')) return;
    event.preventDefault();
    draggingPDF = false;
    const pdfs = Array.from(event.dataTransfer.files).filter(
      (file) => file.type === 'application/pdf' || file.name.toLowerCase().endsWith('.pdf')
    );
    if (pdfs.length !== 1) {
      message = pdfs.length ? 'Drop one PDF at a time.' : 'The dropped file is not a PDF.';
      return;
    }
    await run(async () => {
      applyCaptureResult(await window.sharedLibrary.capturePDF(pdfs[0]));
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
    if (!selectedIDs.includes(entry.id)) selectEntry(entry);
    void window.sharedLibrary.showEntryContextMenu(selectedIDs, variant);
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

  async function saveCapturedAudio(enabled: boolean): Promise<void> {
    if (audioPreferenceSaving) return;
    audioPreferenceSaving = true;
    try {
      audioPreferences =
        await window.sharedLibrary.setSaveCapturedAudio(enabled);
      message = enabled
        ? 'Audio from manually captured YouTube videos will be saved.'
        : 'YouTube audio will remain temporary.';
    } catch (error) {
      message =
        error instanceof Error ? error.message : 'The audio setting could not be changed.';
    } finally {
      audioPreferenceSaving = false;
    }
  }

  function applyProcessingPreferences(next: ProcessingPreferences): void {
    processingTopicsDraft = next.topics.map((topic) => ({ ...topic }));
  }

  function applyPromptPreferences(next: PromptPreferences): void {
    promptPreferences = next;
    for (const prompt of next.prompts) promptDrafts[prompt.id] = prompt.prompt;
  }

  function addProcessingTopic(): void {
    processingTopicsDraft.push({ id: '', title: '' });
  }

  function removeProcessingTopic(index: number): void {
    processingTopicsDraft.splice(index, 1);
  }

  async function saveTopics(): Promise<void> {
    await run(async () => {
      const next = await window.sharedLibrary.updateProcessingPreferences({
        topics: processingTopicsDraft.map((topic) => ({ ...topic })),
        prompt: promptDrafts.summarization
      });
      applyProcessingPreferences(next);
      message = 'Topics saved.';
    });
  }

  async function savePrompt(): Promise<void> {
    if (!selectedPromptID) return;
    await run(async () => {
      applyPromptPreferences(
        await window.sharedLibrary.updatePromptPreference({
          id: selectedPromptID,
          prompt: promptDrafts[selectedPromptID]
        })
      );
      message = `${selectedPrompt?.title ?? 'Prompt'} prompt saved.`;
    });
  }

  function promptIDForTab(tab: SettingsTab): PromptID | null {
    return tab.startsWith('prompt-') ? tab.slice(7) as PromptID : null;
  }

  async function shareDocument(): Promise<void> {
    if (!selectedEntry || shareBusy) return;
    shareBusy = true;
    try {
      const existing = await window.sharedLibrary.getShareLink(selectedEntry.id);
      if (existing.shared && existing.status === 'ready' && existing.url) {
        await navigator.clipboard.writeText(existing.url);
        message = 'Share link copied.';
        return;
      }
      const next = await window.sharedLibrary.publishShareLink(selectedEntry.id);
      message =
        next.status === 'ready'
          ? 'Share link copied.'
          : 'The share link is being prepared in the background.';
    } catch (error) {
      message = error instanceof Error ? error.message : 'The share link could not be created.';
    } finally {
      shareBusy = false;
    }
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

  function openPodcastEpisode(entryID: string): void {
    activeView = 'podcasts';
    settingsOpen = false;
    const entry = entries.find((candidate) => candidate.id === entryID);
    if (entry) selectEntry(entry);
  }

</script>

<svelte:head>
  <title>Briefly</title>
</svelte:head>

<svelte:window
  ondragenter={handleFileDrag}
  ondragover={handleFileDrag}
  ondragleave={handleFileDragLeave}
  ondrop={handleFileDrop}
/>

<div class="app-shell bg-background! bg-none! text-foreground! font-sans!">
  {#if draggingPDF}
    <div class="pdf-drop-overlay" role="status">
      <FileText />
      <strong>Drop PDF to capture</strong>
      <span>Briefly will extract its text and create a note.</span>
    </div>
  {/if}
  {#if loading}
    <main class="center-stage text-foreground!" aria-live="polite">
      <div class="launch-sequence">
        <div class="loading-mark" aria-hidden="true">
          <span class="loading-halo"></span>
          <img src={appIcon} alt="" />
        </div>
        <p class="loading-title text-foreground!">Opening your library</p>
        <p class="loading-copy text-muted-foreground!">Preparing the local collection</p>
        <div class="loading-dots [&_span]:bg-muted-foreground!" aria-hidden="true"><span></span><span></span><span></span></div>
      </div>
    </main>
  {:else if !connections?.authenticated}
    <main class="center-stage text-foreground!">
      <section class="empty-card border-border! bg-card! bg-none! text-card-foreground! rounded-xl! border shadow-sm!">
        <div class="empty-illustration bg-muted! bg-none! text-muted-foreground!">
          <LogIn />
          <span class="empty-check bg-primary! bg-none! text-primary-foreground!"><Check /></span>
        </div>
        <p class="eyebrow text-muted-foreground!">Briefly account</p>
        <h1>Sign in to continue</h1>
        <p class="empty-copy text-muted-foreground!">
          Sign in manages your Briefly membership. You will choose sync separately.
        </p>
        <div class="empty-actions">
          <button class="primary-button border-primary! bg-primary! bg-none! text-primary-foreground! rounded-lg! border shadow-sm! hover:bg-primary/80!" onclick={() => signIn('apple')} disabled={busy}>
            {#if busy}<LoaderCircle class="spin" />{:else}<LogIn />{/if}
            Sign in with Apple
          </button>
          <button class="secondary-button border-border! bg-secondary! bg-none! text-secondary-foreground! rounded-lg! border shadow-sm! hover:bg-secondary/80!" onclick={() => signIn('google')} disabled={busy}>
            {#if busy}<LoaderCircle class="spin" />{:else}<LogIn />{/if}
            Sign in with Google
          </button>
        </div>
      </section>
    </main>
  {:else if !connections.entitled}
    <main class="center-stage text-foreground!">
      <section class="empty-card border-border! bg-card! bg-none! text-card-foreground! rounded-xl! border shadow-sm!">
        <div class="empty-illustration bg-muted! bg-none! text-muted-foreground!">
          <Sparkles />
          <span class="empty-check bg-primary! bg-none! text-primary-foreground!"><Check /></span>
        </div>
        <p class="eyebrow text-muted-foreground!">Briefly membership</p>
        <h1>Activate your account</h1>
        <p class="empty-copy text-muted-foreground!">
          Choose your plan and manage billing on the web, then refresh access here.
        </p>
        <div class="empty-actions">
          <button class="primary-button border-primary! bg-primary! bg-none! text-primary-foreground! rounded-lg! border shadow-sm! hover:bg-primary/80!" onclick={openAccount}>
            <ArrowUpRight /> Open account
          </button>
          <button class="secondary-button border-border! bg-secondary! bg-none! text-secondary-foreground! rounded-lg! border shadow-sm! hover:bg-secondary/80!" onclick={refreshAccount} disabled={busy}>
            <RefreshCw class={busy ? 'spin' : ''} /> Refresh access
          </button>
        </div>
      </section>
    </main>
  {:else if activeView === 'library' && noteEntries.length === 0}
    <main class="center-stage text-foreground!">
      <section class="empty-card border-border! bg-card! bg-none! text-card-foreground! rounded-xl! border shadow-sm!">
        <div class="empty-illustration bg-muted! bg-none! text-muted-foreground!">
          <Archive />
          <span class="empty-check bg-primary! bg-none! text-primary-foreground!"><Check /></span>
        </div>
        <p class="eyebrow text-muted-foreground!">Briefly</p>
        <h1>Your library is ready</h1>
        <p class="empty-copy text-muted-foreground!">
          Capture clipboard text or choose an existing Briefly workspace.
        </p>
        <div class="empty-actions">
          <button class="primary-button border-primary! bg-primary! bg-none! text-primary-foreground! rounded-lg! border shadow-sm! hover:bg-primary/80!" onclick={captureClipboard}>
            <Clipboard /> Capture
          </button>
          <button class="secondary-button border-border! bg-secondary! bg-none! text-secondary-foreground! rounded-lg! border shadow-sm! hover:bg-secondary/80!" onclick={chooseWorkspace}>
            <FolderOpen /> Choose folder
          </button>
          <button class="secondary-button border-border! bg-secondary! bg-none! text-secondary-foreground! rounded-lg! border shadow-sm! hover:bg-secondary/80!" onclick={() => selectView('podcasts')}>
            <Headphones /> Podcasts
          </button>
        </div>
      </section>
    </main>
  {:else}
    <div class="native-workspace" class:reader-open={mobileReaderVisible}>
      <aside class="native-library-pane border-sidebar-border! bg-sidebar! bg-none! text-sidebar-foreground! rounded-xl! border shadow-sm!">
        <div class="native-library-toolbar">
          <div class="library-primary-controls">
            <div class="library-view-tabs" role="tablist" aria-label="Library view">
              <button
                class:active={activeView === 'library'}
                role="tab"
                aria-selected={activeView === 'library'}
                onclick={() => selectView('library')}
              >
                <FileText />
                <span>Main</span>
              </button>
              <button
                class:active={activeView === 'podcasts'}
                role="tab"
                aria-selected={activeView === 'podcasts'}
                onclick={() => selectView('podcasts')}
              >
                <Headphones />
                <span>Pod</span>
              </button>
            </div>

            <div class="native-search-field">
              <Search aria-hidden="true" />
              <input
                bind:value={query}
                aria-label={activeView === 'podcasts' ? 'Search podcasts' : 'Search library'}
                placeholder={activeView === 'podcasts' ? 'Search podcasts' : 'Search'}
              />
              {#if query}
                <button class="clear-search" aria-label="Clear search" onclick={() => (query = '')}>
                  <X />
                </button>
              {/if}
            </div>
          </div>

          <div class="topic-strip" aria-label={activeView === 'podcasts' ? 'Podcast filter' : 'Topic filter'}>
            <button
              class="topic-chip border-border! bg-secondary! bg-none! text-secondary-foreground! rounded-lg! border shadow-sm! hover:bg-secondary/80! [&.active]:border-primary! [&.active]:bg-primary! [&.active]:text-primary-foreground!"
              class:active={activeView === 'podcasts' ? selectedPodcastID === 'all' : selectedTopic === 'all'}
              onclick={() => activeView === 'podcasts' ? selectPodcast('all') : selectTopic('all')}
            >All</button>
            {#if activeView === 'podcasts'}
              {#each podcastSnapshot?.podcasts ?? [] as podcast (podcast.id)}
                <button
                  class="topic-chip border-border! bg-secondary! bg-none! text-secondary-foreground! rounded-lg! border shadow-sm! hover:bg-secondary/80! [&.active]:border-primary! [&.active]:bg-primary! [&.active]:text-primary-foreground!"
                  class:active={selectedPodcastID === podcast.id}
                  onclick={() => selectPodcast(podcast.id)}
                >{podcast.title}</button>
              {/each}
            {:else}
              {#each snapshot?.topics ?? [] as topic}
                <button
                  class="topic-chip border-border! bg-secondary! bg-none! text-secondary-foreground! rounded-lg! border shadow-sm! hover:bg-secondary/80! [&.active]:border-primary! [&.active]:bg-primary! [&.active]:text-primary-foreground!"
                  class:active={selectedTopic === topic}
                  onclick={() => selectTopic(topic)}
                >{topic}</button>
              {/each}
            {/if}
          </div>
        </div>

        <div class="native-entry-list" aria-label="Library items">
          {#if activeView === 'podcasts'}
            {#if podcastGroups.length === 0}
              <div class="native-no-results text-muted-foreground!">
                <Headphones />
                <p>No podcast episodes</p>
                <button class="text-primary!" onclick={() => openSettings('podcasts')}>Manage podcasts</button>
              </div>
            {:else}
              {#each podcastGroups as group (group.episode.id)}
                <div class="podcast-episode-group">
                  <button
                    class="native-entry-row podcast-episode-row text-sidebar-foreground! rounded-lg! hover:bg-sidebar-accent/60! [&.selected]:bg-sidebar-accent! [&.selected]:text-sidebar-accent-foreground!"
                    class:selected={selectedIDs.includes(group.episode.id)}
                    aria-pressed={selectedIDs.includes(group.episode.id)}
                    aria-expanded={expandedEpisodeIDs.includes(group.episode.id)}
                    onpointerdown={(event) => {
                      if (event.button === 0) selectSidebarEntry(event, group.episode);
                    }}
                    onpointerenter={(event) => extendSidebarSelection(event, group.episode)}
                    onclick={(event) => {
                      if (event.detail === 0) selectSidebarEntry(event, group.episode);
                      togglePodcastEpisode(group.episode);
                    }}
                    oncontextmenu={(event) => showEntryContextMenu(event, group.episode)}
                  >
                    {#if expandedEpisodeIDs.includes(group.episode.id)}
                      <FolderOpen class="text-sidebar-foreground/70!" aria-hidden="true" />
                    {:else}
                      <Folder class="text-sidebar-foreground/70!" aria-hidden="true" />
                    {/if}
                    <span>{group.episode.title}</span>
                  </button>
                  {#if group.notes.length && expandedEpisodeIDs.includes(group.episode.id)}
                    <div class="podcast-note-list">
                      {#each group.notes as note (note.id)}
                        <button
                          class="native-entry-row podcast-note-row text-sidebar-foreground! rounded-lg! hover:bg-sidebar-accent/60! [&.selected]:bg-sidebar-accent! [&.selected]:text-sidebar-accent-foreground!"
                          class:selected={selectedIDs.includes(note.id)}
                          aria-pressed={selectedIDs.includes(note.id)}
                          onpointerdown={(event) => {
                            if (event.button === 0) selectSidebarEntry(event, note);
                          }}
                          onpointerenter={(event) => extendSidebarSelection(event, note)}
                          onclick={(event) => {
                            if (event.detail === 0) selectSidebarEntry(event, note);
                          }}
                          oncontextmenu={(event) => showEntryContextMenu(event, note)}
                        >
                          {#if note.faviconFile}
                            <img
                              src={`briefly-favicon://icon/${note.faviconFile}`}
                              alt=""
                              aria-hidden="true"
                            />
                          {:else}
                            <FileText class="text-sidebar-foreground/70!" aria-hidden="true" />
                          {/if}
                          <span>{note.title}</span>
                        </button>
                      {/each}
                    </div>
                  {/if}
                </div>
              {/each}
            {/if}
          {:else if filteredEntries.length === 0}
            <div class="native-no-results text-muted-foreground!">
              <FileText />
              <p>No matching documents</p>
              <button class="text-primary!" onclick={() => {
                query = '';
                selectTopic('all');
              }}>Clear filters</button>
            </div>
          {:else}
            {#each filteredEntries as entry (entry.id)}
              <button
                class="native-entry-row text-sidebar-foreground! rounded-lg! hover:bg-sidebar-accent/60! [&.selected]:bg-sidebar-accent! [&.selected]:text-sidebar-accent-foreground!"
                class:selected={selectedIDs.includes(entry.id)}
                aria-pressed={selectedIDs.includes(entry.id)}
                onpointerdown={(event) => {
                  if (event.button === 0) selectSidebarEntry(event, entry);
                }}
                onpointerenter={(event) => extendSidebarSelection(event, entry)}
                onclick={(event) => {
                  if (event.detail === 0) selectSidebarEntry(event, entry);
                }}
                oncontextmenu={(event) => showEntryContextMenu(event, entry)}
              >
                {#if entry.faviconFile}
                  <img
                    src={`briefly-favicon://icon/${entry.faviconFile}`}
                    alt=""
                    aria-hidden="true"
                  />
                {:else}
                  <FileText class="text-sidebar-foreground/70!" aria-hidden="true" />
                {/if}
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
            <span>AI</span>
          </button>
          <button
            class="agent-button sidebar-settings-button"
            aria-label="Settings"
            title="Settings"
            onclick={() => openSettings(activeView === 'podcasts' ? 'podcasts' : 'general')}
          >
            <Cog />
          </button>
        </div>
      </aside>

      <main class="native-reader-pane border-border! bg-card! bg-none! text-card-foreground! rounded-xl! border shadow-sm!">
        {#if selectedEntry}
          <div class="native-mobile-reader-bar border-border! bg-card! bg-none! text-card-foreground!">
            <button class="text-card-foreground! hover:bg-accent! hover:text-accent-foreground!" onclick={() => (mobileReaderVisible = false)}>
              <ChevronLeft />
              <span>Library</span>
            </button>
          </div>

          <div class="native-document-scroll">
            <article
              class="native-document-body text-card-foreground! font-serif!"
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
                {#if selectedEntry.hasAudio && (selectedEntry.entryType === 'podcast_episode' || selectedVariant === 'source')}
                  <div class="podcast-reader-player">
                    <AudioPlayer
                      src={`briefly-podcast-audio://episode/${encodeURIComponent(selectedEntry.id)}.wav`}
                      title={selectedEntry.title}
                    />
                  </div>
                {:else if selectedSourceMediaURL}
                  <div class="podcast-reader-player">
                    <AudioPlayer
                      src={selectedSourceMediaURL}
                      title={selectedEntry.title}
                    />
                  </div>
                {/if}
                <MarkdownView text={selectedText} plain={renderSelectedTextAsPlain} />
              {:else}
                <p class="missing-text">This version is not available.</p>
              {/if}
            </article>
          </div>

          <footer
            class="native-document-footer"
            aria-label="Document actions"
          >
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

            </div>
          </footer>
        {/if}
      </main>
    </div>
  {/if}

  {#if ingestion.phase === 'processing' || message}
    <div class="notification-stack">
      {#if ingestion.phase === 'processing'}
        <div class="ingestion-indicator border-primary/30! bg-primary/10! text-foreground!" role="status" aria-live="polite">
          <LoaderCircle class="spin" />
          <span>{ingestion.message} Extracting and preparing summaries.</span>
        </div>
      {/if}
      {#if message}
        <div
          class="toast border-border! bg-popover! bg-none! text-popover-foreground! rounded-xl! border shadow-sm! [&.error]:border-destructive! [&.error]:bg-destructive/10! [&.error]:text-destructive!"
          class:error={message.includes('failed') || message.includes('could not')}
          role="status"
          aria-live="polite"
        >
          <span>{message}</span>
          <button class="text-muted-foreground! hover:text-foreground!" aria-label="Dismiss message" onclick={() => (message = '')}><X /></button>
        </div>
      {/if}
    </div>
  {/if}
</div>

{#if settingsOpen}
  <section class="settings-screen bg-popover! bg-none! text-popover-foreground! font-sans!" aria-label="Settings">
    <aside class="settings-navigation border-border! bg-sidebar! text-sidebar-foreground!">
      <button class="settings-back border-border! bg-secondary! text-secondary-foreground!" onclick={() => (settingsOpen = false)}>
        <ChevronLeft /> Back to app
      </button>
      <p class="settings-label text-muted-foreground!">Settings</p>
      <nav class="settings-tabs" aria-label="Settings categories">
        <button class:active={settingsTab === 'general'} onclick={() => (settingsTab = 'general')}>General</button>
        <button class:active={settingsTab === 'topics'} onclick={() => (settingsTab = 'topics')}>Topics</button>
        <button
          class:active={Boolean(selectedPromptID)}
          aria-expanded={promptsExpanded}
          onclick={() => (promptsExpanded = !promptsExpanded)}
        >
          Prompts <span>{promptsExpanded ? '−' : '+'}</span>
        </button>
        {#if promptsExpanded}
          <div class="settings-subtabs">
            {#each promptPreferences?.prompts ?? [] as prompt (prompt.id)}
              <button
                class:active={selectedPromptID === prompt.id}
                onclick={() => (settingsTab = `prompt-${prompt.id}` as SettingsTab)}
              >{prompt.title}</button>
            {/each}
          </div>
        {/if}
        <button class:active={settingsTab === 'podcasts'} onclick={() => (settingsTab = 'podcasts')}>Podcasts</button>
      </nav>
    </aside>
    <div class="settings-main">
      <header class="settings-header">
        <p class="settings-breadcrumb text-muted-foreground!">
          Briefly <span>›</span> Settings <span>›</span>
          {settingsTitle}
        </p>
        <h2>{settingsTitle}</h2>
      </header>
      <main class="settings-content" class:podcasts-tab={settingsTab === 'podcasts'}>
      {#if settingsTab === 'general'}
      <section class="settings-card border-border! bg-card! bg-none! text-card-foreground! rounded-xl! border shadow-sm!">
        <div class="settings-card-heading">
          <div class="provider-mark bg-muted! bg-none! text-foreground! rounded-lg!"><Palette /></div>
          <div>
            <h3>Appearance</h3>
            <p>Choose from every built-in TweakCN theme.</p>
          </div>
        </div>
        <div class="theme-controls grid grid-cols-[minmax(0,1fr)_minmax(110px,0.45fr)] gap-2.5 max-[420px]:grid-cols-1">
          <label class="theme-field grid gap-1.5">
            <span class="text-muted-foreground! text-[10px] font-semibold uppercase tracking-[0.06em]">Theme</span>
            <select
              class="border-input! bg-background! bg-none! text-foreground! h-9 w-full rounded-lg! border px-2.5 outline-none shadow-sm! focus:border-ring focus:ring-2 focus:ring-ring/20"
              value={themePreference.theme}
              onchange={(event) =>
                updateTheme((event.currentTarget as HTMLSelectElement).value as ThemeName)}
            >
              {#each themeOptions as option}
                <option value={option.value}>{option.label}</option>
              {/each}
            </select>
          </label>
          <label class="theme-field grid gap-1.5">
            <span class="text-muted-foreground! text-[10px] font-semibold uppercase tracking-[0.06em]">Mode</span>
            <select
              class="border-input! bg-background! bg-none! text-foreground! h-9 w-full rounded-lg! border px-2.5 outline-none shadow-sm! focus:border-ring focus:ring-2 focus:ring-ring/20"
              value={themePreference.mode}
              onchange={(event) =>
                updateTheme(undefined, (event.currentTarget as HTMLSelectElement).value as ThemeMode)}
            >
              {#each themeModeOptions as option}
                <option value={option.value}>{option.label}</option>
              {/each}
            </select>
          </label>
        </div>
      </section>

      <section class="settings-card border-border! bg-card! bg-none! text-card-foreground! rounded-xl! border shadow-sm!">
        <div class="settings-card-heading">
          <div class="provider-mark bg-muted! bg-none! text-foreground! rounded-lg!"><Headphones /></div>
          <div>
            <h3>YouTube audio</h3>
            <p>Control permanent storage for videos you capture yourself.</p>
          </div>
        </div>
        <label class="flex items-start gap-3">
          <input
            class="mt-1"
            type="checkbox"
            checked={audioPreferences?.saveCapturedAudio ?? true}
            disabled={!audioPreferences || audioPreferenceSaving}
            onchange={(event) =>
              void saveCapturedAudio((event.currentTarget as HTMLInputElement).checked)}
          />
          <span>
            Save audio from manually captured YouTube videos
            <small class="text-muted-foreground! block">
              Podcasts stay remote. Watched and agent-imported sources remain text-only. Generated podcast episodes keep their audio.
            </small>
          </span>
        </label>
      </section>

      <section class="settings-card border-border! bg-card! bg-none! text-card-foreground! rounded-xl! border shadow-sm!">
        <div class="settings-card-heading">
          <div class="provider-mark bg-muted! bg-none! text-foreground! rounded-lg!"><FolderOpen /></div>
          <div>
            <h3>Library workspace</h3>
            <p>The same Markdown folder structure is used by every client.</p>
          </div>
        </div>
        <code class="border-border! bg-muted! bg-none! text-foreground! rounded-lg! border font-mono!">{snapshot?.workspacePath}</code>
        <div class="panel-actions">
          <button class="secondary-button border-border! bg-secondary! bg-none! text-secondary-foreground! rounded-lg! border shadow-sm! hover:bg-secondary/80!" onclick={chooseWorkspace}>
            <FolderOpen /> Choose folder
          </button>
          <button class="secondary-button border-border! bg-secondary! bg-none! text-secondary-foreground! rounded-lg! border shadow-sm! hover:bg-secondary/80!" onclick={refresh} disabled={busy}>
            <RefreshCw class={busy ? 'spin' : ''} /> Refresh
          </button>
          <button class="secondary-button border-border! bg-secondary! bg-none! text-secondary-foreground! rounded-lg! border shadow-sm! hover:bg-secondary/80!" onclick={captureClipboard} disabled={busy}>
            <Clipboard /> Capture
          </button>
        </div>
      </section>

      <section class="settings-card border-border! bg-card! bg-none! text-card-foreground! rounded-xl! border shadow-sm!">
        <div class="settings-card-heading">
          <div class="provider-mark bg-muted! bg-none! text-foreground! rounded-lg!"><Keyboard /></div>
          <div>
            <h3>Capture shortcut</h3>
            <p>Press a new key combination to capture the clipboard from anywhere.</p>
          </div>
        </div>
        <div class="shortcut-controls">
          <input
            class="border-input! bg-background! bg-none! text-foreground! rounded-lg! border shadow-sm! font-mono! focus:border-ring focus:ring-2 focus:ring-ring/20"
            class:recording={shortcutRecording}
            aria-label="Capture shortcut"
            value={captureShortcutLabel}
            readonly
            onfocus={() => (shortcutRecording = true)}
            onblur={() => (shortcutRecording = false)}
            onkeydown={recordCaptureShortcut}
          />
          <button
            class="secondary-button border-border! bg-secondary! bg-none! text-secondary-foreground! rounded-lg! border shadow-sm! hover:bg-secondary/80!"
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
        <p class="shortcut-status text-muted-foreground!">
          {#if shortcutPreferences?.registered}
            Active system-wide. Click the field and press the replacement shortcut.
          {:else}
            The system-wide shortcut is unavailable; Capture remains in the File menu.
          {/if}
        </p>
      </section>

      <section class="settings-card border-border! bg-card! bg-none! text-card-foreground! rounded-xl! border shadow-sm!">
        <div class="settings-card-heading">
          <div>
            <h3>Briefly account</h3>
            <p>Manage membership and library sync on the web.</p>
          </div>
        </div>
        <div class="connection-status text-muted-foreground!">
          {#if connections?.syncProvider}
            <span class="status-dot bg-primary! bg-none!"></span>
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
          <button class="secondary-button border-border! bg-secondary! bg-none! text-secondary-foreground! rounded-lg! border shadow-sm! hover:bg-secondary/80!" onclick={openAccount} disabled={busy}>
            <ArrowUpRight /> Manage account and sync
          </button>
          <button class="secondary-button border-border! bg-secondary! bg-none! text-secondary-foreground! rounded-lg! border shadow-sm! hover:bg-secondary/80!" onclick={() => window.sharedLibrary.openExternal('https://readbriefly.fyi/feedback')}>
            <ArrowUpRight /> Feedback
          </button>
        </div>
      </section>

      {:else if settingsTab === 'topics'}
      <section class="settings-card border-border! bg-card! bg-none! text-card-foreground! rounded-xl! border shadow-sm!">
        <div class="processing-field-heading [&_small]:text-muted-foreground! [&_span]:text-card-foreground!">
          <div>
            <span>Topics</span>
            <small>Rename existing topics or add reusable ones.</small>
          </div>
          <button
            class="processing-add-button border-border! bg-secondary! bg-none! text-secondary-foreground! rounded-lg! border shadow-sm! hover:bg-secondary/80!"
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
                  class="border-input! bg-background! bg-none! text-foreground! rounded-lg! border shadow-sm! focus:border-ring focus:ring-2 focus:ring-ring/20"
                  aria-label={`Topic ${index + 1} title`}
                  value={topic.title}
                  placeholder="Topic name"
                  oninput={(event) => {
                    processingTopicsDraft[index].title =
                      (event.currentTarget as HTMLInputElement).value;
                  }}
                />
                <small class="text-muted-foreground!">{topic.id || 'ID created when saved'}</small>
              </div>
              <button
                class="border-border! bg-secondary! bg-none! text-secondary-foreground! rounded-lg! border shadow-sm! hover:bg-secondary/80!"
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
            <p class="processing-empty border-border! bg-muted! bg-none! text-muted-foreground! rounded-lg! border">No topics yet. Codex can create one during processing.</p>
          {/if}
        </div>
        <div class="panel-actions processing-actions">
          <button
            class="primary-button border-primary! bg-primary! bg-none! text-primary-foreground! rounded-lg! border shadow-sm! hover:bg-primary/80!"
            type="button"
            disabled={busy}
            onclick={saveTopics}
          >
            {#if busy}<LoaderCircle class="spin" />{:else}<Check />{/if}
            Save topics
          </button>
        </div>
      </section>
      {:else if selectedPrompt && selectedPromptID}
        <section class="settings-card prompt-settings-card border-border! bg-card! bg-none! text-card-foreground! rounded-xl! border shadow-sm!">
          <div class="settings-card-heading">
            <div class="provider-mark bg-muted! bg-none! text-foreground! rounded-lg!"><Sparkles /></div>
            <div>
              <h3>{selectedPrompt.title} prompt</h3>
              <p>{selectedPrompt.description}</p>
            </div>
          </div>
          <label class="processing-prompt-field">
            {#if selectedPrompt.requiredPlaceholders.length}
              <small class="text-muted-foreground!">
                Keep these placeholders:
                {#each selectedPrompt.requiredPlaceholders as placeholder, index}
                  <code>{placeholder}</code>{index < selectedPrompt.requiredPlaceholders.length - 1 ? ', ' : ''}
                {/each}
              </small>
            {/if}
            <textarea
              class="border-input! bg-background! bg-none! text-foreground! rounded-lg! border shadow-sm! font-mono! focus:border-ring focus:ring-2 focus:ring-ring/20"
              value={promptDrafts[selectedPromptID]}
              oninput={(event) => {
                promptDrafts[selectedPromptID] =
                  (event.currentTarget as HTMLTextAreaElement).value;
              }}
              spellcheck="false"
            ></textarea>
          </label>
          <div class="panel-actions processing-actions">
            <button
              class="secondary-button border-border! bg-secondary! bg-none! text-secondary-foreground! rounded-lg! border shadow-sm! hover:bg-secondary/80!"
              type="button"
              disabled={busy}
              onclick={() => (promptDrafts[selectedPromptID] = selectedPrompt.defaultPrompt)}
            >
              <RotateCcw /> Reset prompt
            </button>
            <button
              class="primary-button border-primary! bg-primary! bg-none! text-primary-foreground! rounded-lg! border shadow-sm! hover:bg-primary/80!"
              type="button"
              disabled={busy}
              onclick={savePrompt}
            >
              {#if busy}<LoaderCircle class="spin" />{:else}<Check />{/if}
              Save prompt
            </button>
          </div>
        </section>
      {:else}
        <PodcastsView
          embedded
          onlibrary={() => (settingsOpen = false)}
          onopenepisode={openPodcastEpisode}
          onmessage={(value) => (message = value)}
        />
      {/if}
      </main>
    </div>
  </section>
{/if}
