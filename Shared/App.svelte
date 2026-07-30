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
    Globe2,
    Headphones,
    Keyboard,
    LoaderCircle,
    LogIn,
    Palette,
    Plus,
    Radio,
    RefreshCw,
    RotateCcw,
    Search,
    Share2,
    Sparkles,
    Trash2,
    Volume2,
    X
  } from '@lucide/svelte';
  import AudioPlayer from './AudioPlayer.svelte';
  import DepthControl from './DepthControl.svelte';
  import MarkdownView from './MarkdownView.svelte';
  import VoiceBriefsView from './VoiceBriefsView.svelte';
  import {
    isMainLibraryEntry,
    matchesLibraryEntry,
    shouldRenderSourceAsPlainText
  } from './library';
  import type {
    AccountProvider,
    AICommandPreferences,
    DesktopAudioPreferences,
    DesktopLibraryEntry,
    DesktopLibrarySnapshot,
    DesktopConnectionStatus,
    DesktopIngestionStatus,
    DesktopOperationResult,
    DesktopShortcutPreferences,
    DesktopSyncStatus,
    LibraryVariant,
    VoiceBriefSnapshot,
    PromptID,
    PromptPreferences,
    ProcessingPreferences,
    ShareLinkStatus,
    TopicDefinition
  } from './contracts';
  import {
    captureShortcutFromKeyboardEvent,
    formatCaptureShortcut
  } from './shortcuts';
  import {
    initializeTheme,
    readThemePreference,
    setThemePreference,
    themeModeOptions,
    themeOptions,
    type ThemeMode,
    type ThemeName
  } from './themes';
  import {
    desktopCapabilities,
    noDesktopEvents,
    type BrieflyAppProps
  } from './app';

  let {
    api,
    capabilities = desktopCapabilities,
    desktopEvents = noDesktopEvents,
    appIcon = '',
    loadDemo
  }: BrieflyAppProps = $props();

  type SettingsTab =
    | 'general'
    | 'agents'
    | 'topics'
    | 'prompt-summarization'
    | 'prompt-voice-brief';
  type ActiveView = 'items' | 'channels' | 'briefs';
  type AudioPosition = { x: number; y: number };
  const audioPositionKey = 'briefly:reader-audio-position';
  let snapshot = $state<DesktopLibrarySnapshot | null>(null);
  let voiceBriefSnapshot = $state<VoiceBriefSnapshot | null>(null);
  let activeView = $state<ActiveView>('items');
  let selectedID = $state('');
  let selectedIDs = $state<string[]>([]);
  let selectedVariant = $state<LibraryVariant>('concise');
  let selectedText = $state('');
  let query = $state('');
  let selectedTopic = $state('all');
  let selectedVoiceBriefID = $state('');
  let selectedChannelSource = $state('');
  let newChannelURL = $state('');
  let expandedBriefIDs = $state<string[]>([]);
  let expandedChannelSources = $state<string[]>([]);
  let loading = $state(true);
  let loadingText = $state(false);
  let busy = $state(false);
  let message = $state('');
  let settingsOpen = $state(false);
  let settingsTab = $state<SettingsTab>('general');
  let promptsExpanded = $state(true);
  let mobileReaderVisible = $state(false);
  let audioExpanded = $state(false);
  let audioPlaying = $state(false);
  let audioVolume = $state(1);
  let audioPosition = $state<AudioPosition | null>(null);
  let audioDragOffset: AudioPosition | null = null;
  let readerPane = $state<HTMLElement>();
  let audioPanel = $state<HTMLDivElement>();
  let connections = $state<DesktopConnectionStatus | null>(null);
  let syncStatus = $state<DesktopSyncStatus>({
    phase: 'idle',
    message: 'Sign in and choose a sync service.'
  });
  let shareBusy = $state(false);
  let sharingOpen = $state(false);
  let shareTarget = $state<DesktopLibraryEntry | null>(null);
  let shareLink = $state<ShareLinkStatus>({ shared: false });
  let shareError = $state('');
  let processingTopicsDraft = $state<TopicDefinition[]>([]);
  let aiCommandPreferences = $state<AICommandPreferences | null>(null);
  let processingCommandDraft = $state('');
  let agentCommandDraft = $state('');
  let testingAICommand = $state(false);
  let promptPreferences = $state<PromptPreferences | null>(null);
  let promptDrafts = $state<Record<PromptID, string>>({
    summarization: '',
    'voice-brief': ''
  });
  let shortcutPreferences = $state<DesktopShortcutPreferences | null>(null);
  let audioPreferences = $state<DesktopAudioPreferences | null>(null);
  let aboutYou = $state('');
  let aboutYouDraft = $state('');
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
  let channelEntryIDs = $derived(
    new Set(voiceBriefSnapshot?.channels.flatMap((channel) => channel.entryIDs) ?? [])
  );
  let noteEntries = $derived(
    entries.filter((entry) => isMainLibraryEntry(entry) && !channelEntryIDs.has(entry.id))
  );
  let selectedEntry = $derived(
    entries.find((entry) => entry.id === selectedID) ?? null
  );
  let normalizedQuery = $derived(query.trim().toLowerCase());
  let filteredEntries = $derived(
    noteEntries.filter((entry) => {
      if (selectedTopic !== 'all' && !entry.topicNames.includes(selectedTopic)) return false;
      return matchesLibraryEntry(entry, normalizedQuery);
    })
  );
  let allChannelGroups = $derived.by(() => {
    const entriesByID = new Map(entries.map((entry) => [entry.id, entry]));
    return (voiceBriefSnapshot?.channels ?? []).map((channel) => ({
      source: channel.source,
      title: channel.title ?? channel.source,
      kind: channel.kind,
      lastCheckedAt: channel.lastCheckedAt,
      error: channel.error,
      retrievalCount: channel.retrievalCount,
      canLoadMore: channel.canLoadMore,
      latestBriefAt: channel.latestBriefAt,
      newEntryIDs: channel.newEntryIDs,
      briefs: channel.briefTitles,
      items: channel.entryIDs
        .map((entryID) => entriesByID.get(entryID))
        .filter((entry): entry is DesktopLibraryEntry => Boolean(entry))
    })).sort((left, right) =>
      left.title.localeCompare(right.title)
    );
  });
  let channelGroups = $derived(
    allChannelGroups.filter((group) =>
      !normalizedQuery ||
      [
        group.title,
        group.source,
        ...group.briefs,
        ...group.items.flatMap((item) => [item.title, item.excerpt])
      ].join(' ').toLowerCase().includes(normalizedQuery)
    )
  );
  let briefGroups = $derived(
    (voiceBriefSnapshot?.voiceBriefs ?? []).filter((brief) =>
      !normalizedQuery ||
      [brief.title, brief.message, ...brief.episodes.map((episode) => episode.title)]
        .join(' ')
        .toLowerCase()
        .includes(normalizedQuery)
    )
  );
  let selectedChannel = $derived(
    allChannelGroups.find(({ source }) => source === selectedChannelSource) ?? null
  );
  let selectedBrief = $derived(
    voiceBriefSnapshot?.voiceBriefs.find(({ id }) => id === selectedVoiceBriefID) ?? null
  );
  let availableVariants = $derived(selectedEntry?.availableVariants ?? []);
  let renderSelectedTextAsPlain = $derived(
    shouldRenderSourceAsPlainText(selectedVariant, selectedEntry?.sourceURL)
  );
  let selectedAudioURL = $derived(
    selectedEntry?.audioURL ??
      (selectedEntry?.hasAudio
        ? `briefly-voice-brief-audio://episode/${encodeURIComponent(selectedEntry.id)}.wav`
        : selectedEntry?.mediaURL)
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
  let draftUsesBrieflyAI = $derived(
    processingCommandDraft === aiCommandPreferences?.defaultProcessingCommand
  );
  let usesBrieflyAI = $derived(
    Boolean(
      aiCommandPreferences &&
        aiCommandPreferences.processingCommand ===
          aiCommandPreferences.defaultProcessingCommand
    )
  );
  let selectedProcessingPreset = $derived(
    aiCommandPreferences?.processingPresets.find(
      ({ command }) => command === processingCommandDraft
    )?.command ?? (draftUsesBrieflyAI ? '' : 'custom')
  );
  let selectedAgentPreset = $derived(
    aiCommandPreferences?.agentPresets.find(
      ({ command }) => command === agentCommandDraft
    )?.command ?? 'custom'
  );
  let settingsTitle = $derived(
    settingsTab === 'general'
      ? 'General'
      : settingsTab === 'agents'
        ? 'AI agents'
      : settingsTab === 'topics'
        ? 'Topics'
        : (selectedPrompt?.title ?? 'Prompts')
  );

  onMount(() => {
    const removeThemeListener = initializeTheme();
    try {
      const saved = JSON.parse(window.localStorage.getItem(audioPositionKey) ?? 'null');
      if (Number.isFinite(saved?.x) && Number.isFinite(saved?.y)) {
        audioPosition = { x: saved.x, y: saved.y };
      }
    } catch {
      window.localStorage.removeItem(audioPositionKey);
    }
    void initialize();
    return removeThemeListener;
  });

  $effect(() => {
    if (!audioExpanded || !audioPosition) return;
    const frame = window.requestAnimationFrame(constrainSavedAudioPosition);
    return () => window.cancelAnimationFrame(frame);
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

  $effect(() => {
    if (
      activeView === 'items' &&
      selectedEntry &&
      !noteEntries.some((entry) => entry.id === selectedEntry?.id)
    ) {
      selectedID = noteEntries[0]?.id ?? '';
      selectedIDs = selectedID ? [selectedID] : [];
    }
  });

  async function initialize(): Promise<void> {
    try {
      voiceBriefSnapshot = await api.getVoiceBriefs();
      applySnapshot(await api.getSnapshot());
      connections = await api.getConnectionStatus();
      syncStatus = connections.sync;
      applyProcessingPreferences(
        await api.getProcessingPreferences()
      );
      applyPromptPreferences(await api.getPromptPreferences());
      applyAICommandPreferences(
        await api.getAICommandPreferences()
      );
      shortcutPreferences = await api.getShortcutPreferences();
      audioPreferences = await api.getAudioPreferences();
      aboutYou = await api.getAboutYou();
      aboutYouDraft = aboutYou;
      ingestion = await api.getIngestionStatus();
      const savedTopic = window.localStorage.getItem('shared-library-selected-topic');
      if (savedTopic && snapshot?.topics.includes(savedTopic)) selectedTopic = savedTopic;
      const removeLibraryListener = api.onLibraryChanged(applySnapshot);
      const removeWorkspaceListener =
        desktopEvents.onChooseWorkspace(() => void chooseWorkspace());
      const removeMessageListener =
        desktopEvents.onOperationMessage((result) => {
          message = result.message ?? '';
          if (result.selectedEntryID) {
            selectedID = result.selectedEntryID;
            selectedIDs = [result.selectedEntryID];
            mobileReaderVisible = true;
          }
        });
      const removeSyncListener = api.onSyncStatus((status) => {
        syncStatus = status;
        if (status.phase === 'error') message = status.message;
      });
      const removeIngestionListener =
        api.onIngestionStatus((status) => {
          ingestion = status;
        });
      const removeVoiceBriefsListener =
        api.onVoiceBriefsChanged((next) => {
          voiceBriefSnapshot = next;
          if (
            selectedVoiceBriefID &&
            selectedVoiceBriefID !== 'new' &&
            !next.voiceBriefs.some((voiceBrief) => voiceBrief.id === selectedVoiceBriefID)
          ) {
            selectedVoiceBriefID = '';
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
          removeVoiceBriefsListener();
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
      previousEntry
        ? previousSelection
        : activeView === 'items'
          ? (next.entries.find(isMainLibraryEntry)?.id ?? '')
          : '';
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
      const text = await api.readText(entry.id, variant);
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
    if (event.metaKey || (snapshot?.platform !== 'darwin' && event.ctrlKey)) {
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

  function selectView(view: ActiveView): void {
    activeView = view;
    query = '';
    if (view === 'items') {
      if (!selectedEntry || !noteEntries.some(({ id }) => id === selectedEntry?.id)) {
        selectedID = noteEntries[0]?.id ?? '';
      }
    } else {
      selectedID = '';
      if (view === 'channels') {
        selectedChannelSource ||= allChannelGroups[0]?.source ?? '';
      } else {
        selectedVoiceBriefID ||=
          voiceBriefSnapshot?.voiceBriefs[0]?.id ?? '';
      }
    }
    selectedIDs = selectedID ? [selectedID] : [];
    mobileReaderVisible = false;
  }

  function selectChannel(source: string): void {
    selectedChannelSource = source;
    selectedID = '';
    selectedIDs = [];
    expandedChannelSources = expandedChannelSources.includes(source)
      ? expandedChannelSources.filter((candidate) => candidate !== source)
      : [...expandedChannelSources, source];
    mobileReaderVisible = true;
  }

  function createChannel(): void {
    selectedChannelSource = 'new';
    selectedID = '';
    selectedIDs = [];
    newChannelURL = '';
    mobileReaderVisible = true;
  }

  function selectBrief(voiceBriefID: string): void {
    selectedVoiceBriefID = voiceBriefID;
    selectedID = '';
    selectedIDs = [];
    expandedBriefIDs = expandedBriefIDs.includes(voiceBriefID)
      ? expandedBriefIDs.filter((id) => id !== voiceBriefID)
      : [...expandedBriefIDs, voiceBriefID];
    mobileReaderVisible = true;
  }

  function createBrief(): void {
    selectedVoiceBriefID = 'new';
    selectedID = '';
    selectedIDs = [];
    mobileReaderVisible = true;
  }

  function openSettings(tab: SettingsTab = 'general'): void {
    settingsTab = tab;
    settingsOpen = true;
  }

  function selectVariant(variant: LibraryVariant): void {
    selectedVariant = variant;
  }

  function constrainAudioPosition(x: number, y: number): AudioPosition {
    if (!readerPane || !audioPanel) return { x, y };
    return {
      x: Math.round(Math.max(0, Math.min(x, readerPane.clientWidth - audioPanel.offsetWidth))),
      y: Math.round(Math.max(0, Math.min(y, readerPane.clientHeight - audioPanel.offsetHeight - 44)))
    };
  }

  function constrainSavedAudioPosition(): void {
    if (!audioExpanded || !audioPosition) return;
    const next = constrainAudioPosition(audioPosition.x, audioPosition.y);
    if (next.x === audioPosition.x && next.y === audioPosition.y) return;
    audioPosition = next;
    window.localStorage.setItem(audioPositionKey, JSON.stringify(next));
  }

  function startAudioDrag(event: PointerEvent): void {
    if (!readerPane || !audioPanel) return;
    event.preventDefault();
    const panelBounds = audioPanel.getBoundingClientRect();
    audioDragOffset = {
      x: event.clientX - panelBounds.left,
      y: event.clientY - panelBounds.top
    };
    audioPosition = constrainAudioPosition(audioPanel.offsetLeft, audioPanel.offsetTop);
  }

  function dragAudio(event: PointerEvent): void {
    if (!readerPane || !audioDragOffset) return;
    const readerBounds = readerPane.getBoundingClientRect();
    audioPosition = constrainAudioPosition(
      event.clientX - readerBounds.left - audioDragOffset.x,
      event.clientY - readerBounds.top - audioDragOffset.y
    );
    window.localStorage.setItem(audioPositionKey, JSON.stringify(audioPosition));
  }

  function finishAudioDrag(): void {
    audioDragOffset = null;
  }

  function moveAudioWithKeyboard(event: KeyboardEvent): void {
    if (!audioPanel) return;
    const distance = event.shiftKey ? 40 : 10;
    const movement =
      event.key === 'ArrowLeft' ? [-distance, 0] :
      event.key === 'ArrowRight' ? [distance, 0] :
      event.key === 'ArrowUp' ? [0, -distance] :
      event.key === 'ArrowDown' ? [0, distance] :
      null;
    if (!movement) return;
    event.preventDefault();
    const current = audioPosition ?? {
      x: audioPanel.offsetLeft,
      y: audioPanel.offsetTop
    };
    audioPosition = constrainAudioPosition(
      current.x + movement[0],
      current.y + movement[1]
    );
    window.localStorage.setItem(audioPositionKey, JSON.stringify(audioPosition));
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
      applySnapshot(await api.refresh());
      message = 'Library refreshed.';
    });
  }

  async function captureClipboard(): Promise<void> {
    await run(async () => {
      applyCaptureResult(await api.captureClipboard());
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
      applyCaptureResult(await api.capturePDF(pdfs[0]));
    });
  }

  async function chooseWorkspace(): Promise<void> {
    await run(async () => {
      const result = await api.chooseWorkspace();
      if (result) {
        applySnapshot(result);
        applyProcessingPreferences(
          await api.getProcessingPreferences()
        );
        settingsOpen = false;
        message = 'Workspace changed.';
      }
    });
  }

  async function launchAgent(): Promise<void> {
    try {
      await api.openAgent();
      message = 'Opened the agent in this library workspace.';
    } catch (error) {
      message = error instanceof Error ? error.message : 'The agent could not be opened.';
    }
  }

  function showEntryContextMenu(
    event: MouseEvent,
    entry: DesktopLibraryEntry,
    variant: LibraryVariant = 'source'
  ): void {
    event.preventDefault();
    const entryIDs = selectedIDs.includes(entry.id) ? selectedIDs : [entry.id];
    if (entryIDs.length === 1) selectEntry(entry);
    void api.showEntryContextMenu([...entryIDs], variant).catch((error) => {
      message = error instanceof Error ? error.message : 'The menu could not be opened.';
    });
  }

  async function signIn(provider: AccountProvider): Promise<void> {
    await run(async () => {
      connections = await api.signIn(provider);
      syncStatus = connections.sync;
      message = `Signed in with ${provider === 'apple' ? 'Apple' : 'Google'}.`;
    });
  }

  async function showDemo(): Promise<void> {
    if (!loadDemo) return;
    message = 'Opening the sample library…';
    await run(async () => {
      const demoSnapshot = await loadDemo();
      syncStatus = { phase: 'idle', message: 'Viewing the sample library.' };
      connections = {
        authenticated: true,
        entitled: true,
        syncProvider: null,
        google: { configured: false, connected: false },
        icloud: { configured: false, connected: false },
        sync: syncStatus
      };
      applySnapshot(demoSnapshot);
      voiceBriefSnapshot = await api.getVoiceBriefs();
      message = 'Sample library opened.';
    });
  }

  async function refreshAccount(): Promise<void> {
    await run(async () => {
      connections = await api.getConnectionStatus();
      syncStatus = connections.sync;
      message = connections.entitled
        ? 'Your Briefly membership is active.'
        : 'An active Briefly membership is still required.';
    });
  }

  async function openAccount(): Promise<void> {
    await run(async () => {
      connections = await api.manageAccount();
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
        await api.setCaptureShortcut(accelerator);
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
        await api.setSaveCapturedAudio(enabled);
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

  async function saveAboutYou(): Promise<void> {
    await run(async () => {
      aboutYou = await api.setAboutYou(aboutYouDraft);
      aboutYouDraft = aboutYou;
      message = 'Personal context saved.';
    });
  }

  function applyProcessingPreferences(next: ProcessingPreferences): void {
    processingTopicsDraft = next.topics.map((topic) => ({ ...topic }));
  }

  function applyPromptPreferences(next: PromptPreferences): void {
    promptPreferences = next;
    for (const prompt of next.prompts) promptDrafts[prompt.id] = prompt.prompt;
  }

  function applyAICommandPreferences(next: AICommandPreferences): void {
    aiCommandPreferences = next;
    processingCommandDraft = next.processingCommand;
    agentCommandDraft = next.agentCommand;
  }

  async function saveAICommands(savedMessage: string): Promise<void> {
    await run(async () => {
      applyAICommandPreferences(
        await api.updateAICommandPreferences({
          processingCommand: processingCommandDraft,
          agentCommand: agentCommandDraft
        })
      );
      message = savedMessage;
    });
  }

  async function useBrieflyAI(): Promise<void> {
    if (!aiCommandPreferences) return;
    processingCommandDraft = aiCommandPreferences.defaultProcessingCommand;
    await saveAICommands('Briefly AI will process and summarize your library.');
  }

  async function testAICommand(): Promise<void> {
    if (testingAICommand) return;
    testingAICommand = true;
    try {
      await api.testAIProcessingCommand(processingCommandDraft);
      message = 'Processing command works.';
    } catch (error) {
      message = error instanceof Error ? error.message : 'The command test failed.';
    } finally {
      testingAICommand = false;
    }
  }

  function addProcessingTopic(): void {
    processingTopicsDraft.push({ id: '', title: '' });
  }

  function removeProcessingTopic(index: number): void {
    processingTopicsDraft.splice(index, 1);
  }

  async function saveTopics(): Promise<void> {
    await run(async () => {
      const next = await api.updateProcessingPreferences({
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
        await api.updatePromptPreference({
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

  async function openSharing(): Promise<void> {
    if (!selectedEntry || selectedEntry.origin === 'shared' || shareBusy) return;
    shareTarget = selectedEntry;
    shareLink = { shared: false };
    shareError = '';
    sharingOpen = true;
    shareBusy = true;
    try {
      shareLink = await api.getShareLink(selectedEntry.id);
    } catch (error) {
      shareError =
        error instanceof Error ? error.message : 'The share link could not be loaded.';
    } finally {
      shareBusy = false;
    }
  }

  async function saveSharing(): Promise<void> {
    if (!shareTarget || shareBusy) return;
    shareBusy = true;
    shareError = '';
    try {
      shareLink = await api.publishShareLink(shareTarget.id);
      message =
        shareLink.status === 'ready'
          ? 'Share link ready.'
          : 'The share link is being prepared in the background.';
    } catch (error) {
      shareError =
        error instanceof Error ? error.message : 'The share link could not be created.';
    } finally {
      shareBusy = false;
    }
  }

  async function copyShareLink(): Promise<void> {
    if (!shareLink.url) return;
    await navigator.clipboard.writeText(shareLink.url);
    message = 'Share link copied.';
  }

  async function stopSharing(): Promise<void> {
    if (!shareLink.token || shareBusy) return;
    shareBusy = true;
    shareError = '';
    try {
      await api.revokeShareLink(shareLink.token);
      shareLink = { shared: false };
      message = 'Share link revoked.';
    } catch (error) {
      shareError =
        error instanceof Error ? error.message : 'The share link could not be revoked.';
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

  async function checkSelectedChannel(): Promise<void> {
    if (!selectedChannel) return;
    await run(async () => {
      voiceBriefSnapshot = await api.checkChannel(selectedChannel.source);
      message =
        allChannelGroups.find(({ source }) => source === selectedChannel.source)?.error ??
        'Channel checked.';
    });
  }

  async function updateSelectedChannel(event: Event): Promise<void> {
    if (!selectedChannel) return;
    const retrievalCount = (event.currentTarget as HTMLInputElement).valueAsNumber;
    try {
      voiceBriefSnapshot = await api.updateChannel(
        selectedChannel.source,
        retrievalCount
      );
      message = 'Channel settings saved.';
    } catch (error) {
      message = error instanceof Error ? error.message : 'The channel could not be updated.';
    }
  }

  async function loadMoreFromSelectedChannel(): Promise<void> {
    if (!selectedChannel) return;
    const source = selectedChannel.source;
    const previousCount = selectedChannel.items.length;
    await run(async () => {
      voiceBriefSnapshot = await api.loadMoreChannel(source);
      const nextCount =
        voiceBriefSnapshot.channels.find((channel) => channel.source === source)
          ?.itemCount ?? previousCount;
      message =
        nextCount > previousCount
          ? `${nextCount - previousCount} more ${
              nextCount - previousCount === 1 ? 'item' : 'items'
            } loaded.`
          : 'No more items are available.';
    });
  }

  async function addNewChannel(): Promise<void> {
    const source = newChannelURL.trim();
    if (!source) return;
    await run(async () => {
      voiceBriefSnapshot = await api.addChannel(source);
      selectedChannelSource = source;
      expandedChannelSources = [
        ...new Set([...expandedChannelSources, source])
      ];
      message = 'Channel added. Check it when you are ready to gather content.';
    });
  }

  async function removeSelectedChannel(): Promise<void> {
    if (
      !selectedChannel ||
      !window.confirm(
        `Delete “${selectedChannel.title}” as a channel? Cached items will be removed; sources used by existing voice briefs will be kept.`
      )
    ) return;
    const source = selectedChannel.source;
    await run(async () => {
      voiceBriefSnapshot = await api.removeChannel(source);
      selectedChannelSource = allChannelGroups.find(
        (channel) => channel.source !== source
      )?.source ?? '';
      selectedID = '';
      message = 'Channel deleted. Its unreferenced cache was removed.';
    });
  }

  async function loginToSelectedChannel(): Promise<void> {
    if (!selectedChannel || !/^https?:\/\//iu.test(selectedChannel.source)) return;
    try {
      await api.loginChannel(selectedChannel.source);
      message = 'Opened the sign-in browser. Close it when you are signed in.';
    } catch (error) {
      message =
        error instanceof Error ? error.message : 'The sign-in browser could not be opened.';
    }
  }

  function handleBriefSelected(voiceBriefID: string): void {
    selectedVoiceBriefID =
      voiceBriefID ||
      voiceBriefSnapshot?.voiceBriefs.find(({ id }) => id !== selectedVoiceBriefID)?.id ||
      '';
    selectedID = '';
    if (voiceBriefID && !expandedBriefIDs.includes(voiceBriefID)) {
      expandedBriefIDs = [...expandedBriefIDs, voiceBriefID];
    }
  }

</script>

<svelte:head>
  <title>Briefly</title>
</svelte:head>

<svelte:window
  ondragenter={capabilities.capture ? handleFileDrag : undefined}
  ondragover={capabilities.capture ? handleFileDrag : undefined}
  ondragleave={capabilities.capture ? handleFileDragLeave : undefined}
  ondrop={capabilities.capture ? handleFileDrop : undefined}
  onpointermove={dragAudio}
  onpointerup={finishAudioDrag}
  onpointercancel={finishAudioDrag}
  onresize={constrainSavedAudioPosition}
/>

<div
  class="app-shell bg-background! bg-none! text-foreground! font-sans!"
  class:web-app={!capabilities.nativeSettings}
>
  {#if capabilities.capture && draggingPDF}
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
          {#if appIcon}<img src={appIcon} alt="" />{/if}
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
          {#if loadDemo}
            <button class="secondary-button border-border! bg-secondary! bg-none! text-secondary-foreground! rounded-lg! border shadow-sm! hover:bg-secondary/80!" onclick={() => void showDemo()} disabled={busy}>
              <Sparkles /> Explore demo
            </button>
          {/if}
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
  {:else if activeView === 'items' && noteEntries.length === 0}
    <main class="center-stage text-foreground!">
      <section class="empty-card border-border! bg-card! bg-none! text-card-foreground! rounded-xl! border shadow-sm!">
        <div class="empty-illustration bg-muted! bg-none! text-muted-foreground!">
          <Archive />
          <span class="empty-check bg-primary! bg-none! text-primary-foreground!"><Check /></span>
        </div>
        <p class="eyebrow text-muted-foreground!">Briefly</p>
        <h1>Your library is ready</h1>
        <p class="empty-copy text-muted-foreground!">
          {capabilities.capture
            ? 'Capture clipboard text or choose an existing Briefly workspace.'
            : connections?.syncProvider === 'icloud' && !connections.icloud.connected
              ? 'Authorize iCloud on this browser to read your private library.'
              : connections?.syncProvider === 'google' && !connections.google.connected
                ? 'Reconnect Google Drive to read your synchronized library.'
                : 'Connect your synchronized library, then refresh this reader.'}
        </p>
        <div class="empty-actions">
          {#if capabilities.capture}
            <button class="primary-button border-primary! bg-primary! bg-none! text-primary-foreground! rounded-lg! border shadow-sm! hover:bg-primary/80!" onclick={captureClipboard}>
              <Clipboard /> Capture
            </button>
            <button class="secondary-button border-border! bg-secondary! bg-none! text-secondary-foreground! rounded-lg! border shadow-sm! hover:bg-secondary/80!" onclick={chooseWorkspace}>
              <FolderOpen /> Choose folder
            </button>
          {:else}
            <button class="primary-button border-primary! bg-primary! bg-none! text-primary-foreground! rounded-lg! border shadow-sm! hover:bg-primary/80!" onclick={openAccount}>
              <ArrowUpRight />
              {connections?.syncProvider === 'icloud' && !connections.icloud.connected
                ? 'Authorize iCloud'
                : connections?.syncProvider === 'google' && !connections.google.connected
                  ? 'Reconnect Google Drive'
                  : 'Manage sync'}
            </button>
            <button class="secondary-button border-border! bg-secondary! bg-none! text-secondary-foreground! rounded-lg! border shadow-sm! hover:bg-secondary/80!" onclick={refresh} disabled={busy}>
              <RefreshCw class={busy ? 'spin' : ''} /> Refresh
            </button>
          {/if}
          {#if capabilities.briefs}
            <button class="secondary-button border-border! bg-secondary! bg-none! text-secondary-foreground! rounded-lg! border shadow-sm! hover:bg-secondary/80!" onclick={() => selectView('briefs')}>
              <Headphones /> Voice briefs
            </button>
          {/if}
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
                class:active={activeView === 'items'}
                role="tab"
                aria-selected={activeView === 'items'}
                onclick={() => selectView('items')}
              >
                <FileText />
                <span>Item</span>
              </button>
              {#if capabilities.channels}
                <button
                  class:active={activeView === 'channels'}
                  role="tab"
                  aria-selected={activeView === 'channels'}
                  onclick={() => selectView('channels')}
                >
                  <Radio />
                  <span>Channel</span>
                </button>
              {/if}
              {#if capabilities.briefs}
                <button
                  class:active={activeView === 'briefs'}
                  role="tab"
                  aria-selected={activeView === 'briefs'}
                  onclick={() => selectView('briefs')}
                >
                  <Headphones />
                  <span>Voice brief</span>
                </button>
              {/if}
            </div>

            <div class="native-search-field">
              <Search aria-hidden="true" />
              <input
                bind:value={query}
                aria-label={activeView === 'channels'
                  ? 'Search channels'
                  : activeView === 'briefs'
                    ? 'Search voice briefs'
                    : 'Search items'}
                placeholder={activeView === 'channels'
                  ? 'Search channels'
                  : activeView === 'briefs'
                    ? 'Search voice briefs'
                    : 'Search items'}
              />
              {#if query}
                <button class="clear-search" aria-label="Clear search" onclick={() => (query = '')}>
                  <X />
                </button>
              {/if}
            </div>
          </div>

          {#if activeView === 'items'}
            <div class="topic-strip" aria-label="Topic filter">
              <button
                class="topic-chip border-border! bg-secondary! bg-none! text-secondary-foreground! rounded-lg! border shadow-sm! hover:bg-secondary/80! [&.active]:border-primary! [&.active]:bg-primary! [&.active]:text-primary-foreground!"
                class:active={selectedTopic === 'all'}
                onclick={() => selectTopic('all')}
              >All</button>
              {#each snapshot?.topics ?? [] as topic}
                <button
                  class="topic-chip border-border! bg-secondary! bg-none! text-secondary-foreground! rounded-lg! border shadow-sm! hover:bg-secondary/80! [&.active]:border-primary! [&.active]:bg-primary! [&.active]:text-primary-foreground!"
                  class:active={selectedTopic === topic}
                  onclick={() => selectTopic(topic)}
                >{topic}</button>
              {/each}
            </div>
          {/if}
        </div>

        <div class="native-entry-list" aria-label="Library items">
          {#if activeView === 'channels'}
            {#if capabilities.channelManagement}
              <button
                class="native-entry-row native-create-row text-primary! rounded-lg! hover:bg-sidebar-accent/60!"
                class:selected={selectedChannelSource === 'new'}
                onclick={createChannel}
              >
                <Plus />
                <span>Add channel</span>
              </button>
            {/if}
            {#if channelGroups.length === 0}
              <div class="native-no-results text-muted-foreground!">
                <Radio />
                <p>No channels yet</p>
              </div>
            {:else}
              {#each channelGroups as group (group.source)}
                <div class="voice-brief-episode-group">
                  <button
                    class="native-entry-row voice-brief-episode-row text-sidebar-foreground! rounded-lg! hover:bg-sidebar-accent/60! [&.selected]:bg-sidebar-accent! [&.selected]:text-sidebar-accent-foreground!"
                    class:selected={selectedChannelSource === group.source && !selectedEntry}
                    aria-pressed={selectedChannelSource === group.source && !selectedEntry}
                    aria-expanded={expandedChannelSources.includes(group.source)}
                    onclick={() => selectChannel(group.source)}
                  >
                    {#if expandedChannelSources.includes(group.source)}
                      <FolderOpen class="text-sidebar-foreground/70!" aria-hidden="true" />
                    {:else}
                      <Folder class="text-sidebar-foreground/70!" aria-hidden="true" />
                    {/if}
                    <span>{group.title}</span>
                    {#if group.newEntryIDs.length}
                      <span
                        class="channel-new-badge"
                        title={`Added since the latest voice brief on ${new Date(group.latestBriefAt!).toLocaleString()}`}
                      >{group.newEntryIDs.length} new</span>
                    {/if}
                  </button>
                  {#if group.items.length && expandedChannelSources.includes(group.source)}
                    <div class="voice-brief-note-list">
                      {#each group.items as item (item.id)}
                        <button
                          class="native-entry-row voice-brief-note-row text-sidebar-foreground! rounded-lg! hover:bg-sidebar-accent/60! [&.selected]:bg-sidebar-accent! [&.selected]:text-sidebar-accent-foreground!"
                          class:selected={selectedIDs.includes(item.id)}
                          aria-pressed={selectedIDs.includes(item.id)}
                          onpointerdown={(event) => {
                            if (event.button === 0) selectSidebarEntry(event, item);
                          }}
                          onpointerenter={(event) => extendSidebarSelection(event, item)}
                          onclick={(event) => {
                            if (event.detail === 0) selectSidebarEntry(event, item);
                          }}
                          oncontextmenu={capabilities.contextMenus
                            ? (event) => showEntryContextMenu(event, item)
                            : undefined}
                        >
                          {#if item.faviconURL || item.faviconFile}
                            <img
                              src={item.faviconURL ??
                                `briefly-favicon://icon/${item.faviconFile}`}
                              alt=""
                              aria-hidden="true"
                            />
                          {:else}
                            <FileText class="text-sidebar-foreground/70!" aria-hidden="true" />
                          {/if}
                          <span>{item.title}</span>
                          {#if group.newEntryIDs.includes(item.id)}
                            <span
                              class="channel-new-badge"
                              title={`Added since the latest voice brief on ${new Date(group.latestBriefAt!).toLocaleString()}`}
                            >New</span>
                          {/if}
                        </button>
                      {/each}
                    </div>
                  {/if}
                </div>
              {/each}
            {/if}
          {:else if activeView === 'briefs'}
            {#if capabilities.briefAuthoring}
              <button
                class="native-entry-row native-create-row text-primary! rounded-lg! hover:bg-sidebar-accent/60!"
                class:selected={selectedVoiceBriefID === 'new'}
                disabled={Boolean(voiceBriefSnapshot &&
                  voiceBriefSnapshot.voiceBriefs.length >= voiceBriefSnapshot.maximumVoiceBriefs)}
                onclick={createBrief}
              >
                <Plus />
                <span>New voice brief</span>
              </button>
            {/if}
            {#if briefGroups.length === 0 && selectedVoiceBriefID !== 'new'}
              <div class="native-no-results text-muted-foreground!">
                <Headphones />
                <p>No voice briefs</p>
              </div>
            {:else}
              {#each briefGroups as brief (brief.id)}
                <div class="voice-brief-episode-group">
                  <button
                    class="native-entry-row voice-brief-episode-row text-sidebar-foreground! rounded-lg! hover:bg-sidebar-accent/60! [&.selected]:bg-sidebar-accent! [&.selected]:text-sidebar-accent-foreground!"
                    class:selected={selectedVoiceBriefID === brief.id && !selectedEntry}
                    aria-pressed={selectedVoiceBriefID === brief.id && !selectedEntry}
                    aria-expanded={expandedBriefIDs.includes(brief.id)}
                    onclick={() => selectBrief(brief.id)}
                  >
                    {#if expandedBriefIDs.includes(brief.id)}
                      <FolderOpen class="text-sidebar-foreground/70!" aria-hidden="true" />
                    {:else}
                      <Folder class="text-sidebar-foreground/70!" aria-hidden="true" />
                    {/if}
                    <span>{brief.title}</span>
                  </button>
                  {#if brief.episodes.length && expandedBriefIDs.includes(brief.id)}
                    <div class="voice-brief-note-list">
                      {#each brief.episodes as episode (episode.id)}
                        <button
                          class="native-entry-row voice-brief-note-row text-sidebar-foreground! rounded-lg! hover:bg-sidebar-accent/60! [&.selected]:bg-sidebar-accent! [&.selected]:text-sidebar-accent-foreground!"
                          class:selected={selectedIDs.includes(episode.id)}
                          aria-pressed={selectedIDs.includes(episode.id)}
                          onpointerdown={(event) => {
                            if (event.button === 0) selectSidebarEntry(event, episode);
                          }}
                          onpointerenter={(event) => extendSidebarSelection(event, episode)}
                          onclick={(event) => {
                            if (event.detail === 0) selectSidebarEntry(event, episode);
                          }}
                          oncontextmenu={capabilities.contextMenus
                            ? (event) => showEntryContextMenu(event, episode)
                            : undefined}
                        >
                          <FileText class="text-sidebar-foreground/70!" aria-hidden="true" />
                          <span>{episode.title}</span>
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
                oncontextmenu={capabilities.contextMenus
                  ? (event) => showEntryContextMenu(event, entry)
                  : undefined}
              >
                {#if entry.faviconURL || entry.faviconFile}
                  <img
                    src={entry.faviconURL ??
                      `briefly-favicon://icon/${entry.faviconFile}`}
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
          {#if capabilities.agents}
            <button
              class="agent-button"
              onclick={launchAgent}
            >
              <Sparkles />
              <span>AI</span>
            </button>
          {/if}
          <button
            class="agent-button sidebar-settings-button"
            aria-label="Settings"
            title="Settings"
            onclick={() => openSettings('general')}
          >
            <Cog />
          </button>
        </div>
      </aside>

      <main
        bind:this={readerPane}
        class="native-reader-pane border-border! bg-card! bg-none! text-card-foreground! rounded-xl! border shadow-sm!"
      >
        {#if activeView === 'channels' && selectedChannelSource === 'new' && !selectedEntry}
          <div class="native-mobile-reader-bar border-border! bg-card! bg-none! text-card-foreground!">
            <button class="text-card-foreground! hover:bg-accent! hover:text-accent-foreground!" onclick={() => (mobileReaderVisible = false)}>
              <ChevronLeft />
              <span>Channels</span>
            </button>
          </div>
          <div class="native-document-scroll">
            <section class="library-folder-config">
              <header>
                <span class="library-folder-eyebrow text-muted-foreground!"><Radio /> Channel</span>
                <h1>Add channel</h1>
                <p class="library-folder-intro text-muted-foreground!">
                  Add a profile, publication, feed, podcast, or video channel. Sign-in and gathering stay here in the Channel library.
                </p>
              </header>
              <form class="library-channel-form" onsubmit={(event) => {
                event.preventDefault();
                void addNewChannel();
              }}>
                <label for="new-channel-url">Channel URL</label>
                <input
                  id="new-channel-url"
                  class="border-input! bg-background! text-foreground! placeholder:text-muted-foreground! rounded-lg! border focus:border-ring focus:ring-2 focus:ring-ring/20"
                  bind:value={newChannelURL}
                  placeholder="https://youtube.com/@channel"
                  spellcheck="false"
                />
                <small class="text-muted-foreground!">
                  Web pages, RSS feeds, YouTube, X, Reddit, Hacker News, and Apple Podcasts are supported.
                </small>
                <button
                  type="submit"
                  class="primary-button border-primary! bg-primary! bg-none! text-primary-foreground! rounded-lg! border shadow-sm! hover:bg-primary/80!"
                  disabled={busy || !newChannelURL.trim()}
                >
                  {#if busy}<LoaderCircle class="spin" />{:else}<Plus />{/if}
                  Add channel
                </button>
              </form>
            </section>
          </div>
        {:else if activeView === 'channels' && selectedChannel && !selectedEntry}
          <div class="native-mobile-reader-bar border-border! bg-card! bg-none! text-card-foreground!">
            <button class="text-card-foreground! hover:bg-accent! hover:text-accent-foreground!" onclick={() => (mobileReaderVisible = false)}>
              <ChevronLeft />
              <span>Channels</span>
            </button>
          </div>
          <div class="native-document-scroll">
            <section class="library-folder-config">
              <header>
                <span class="library-folder-eyebrow text-muted-foreground!"><Radio /> Channel</span>
                <h1>{selectedChannel.title}</h1>
                <code class="border-border! bg-muted! text-muted-foreground!">{selectedChannel.source}</code>
              </header>

              <div class="library-folder-status border-border!">
                <div>
                  <span class="text-muted-foreground!">Status</span>
                  <strong class:text-destructive={Boolean(selectedChannel.error)}>
                    {selectedChannel.error ?? 'Healthy'}
                  </strong>
                </div>
                <div>
                  <span class="text-muted-foreground!">Last checked</span>
                  <strong>
                    {selectedChannel.lastCheckedAt
                      ? new Date(selectedChannel.lastCheckedAt).toLocaleString()
                      : 'Not checked yet'}
                  </strong>
                </div>
                <div>
                  <span class="text-muted-foreground!">Captured items</span>
                  <strong>{selectedChannel.items.length}</strong>
                </div>
              </div>

              <section class="library-folder-section">
                <h2>Configuration</h2>
                <dl>
                  <div>
                    <dt class="text-muted-foreground!">Type</dt>
                    <dd>{selectedChannel.kind ?? 'Page'}</dd>
                  </div>
                  <div>
                    <dt class="text-muted-foreground!">Used by</dt>
                    <dd>{selectedChannel.briefs.join(', ') || 'No voice briefs'}</dd>
                  </div>
                  <div>
                    <dt class="text-muted-foreground!">Items per check</dt>
                    <dd>
                      <input
                        class="channel-retrieval-input border-input! bg-background! text-foreground! rounded-lg! border focus:border-ring focus:ring-2 focus:ring-ring/20"
                        type="number"
                        min="1"
                        max="100"
                        value={selectedChannel.retrievalCount}
                        aria-label="Items retrieved per channel check"
                        disabled={busy || !capabilities.channelManagement}
                        onchange={updateSelectedChannel}
                      />
                    </dd>
                  </div>
                </dl>
              </section>

              <div class="library-folder-actions border-border!">
                {#if capabilities.channelManagement}
                  <button
                    class="primary-button border-primary! bg-primary! bg-none! text-primary-foreground! rounded-lg! border shadow-sm! hover:bg-primary/80!"
                    disabled={busy}
                    onclick={checkSelectedChannel}
                  >
                    <RefreshCw class={busy ? 'spin' : ''} /> Check channel
                  </button>
                  <button
                    class="secondary-button border-border! bg-secondary! bg-none! text-secondary-foreground! rounded-lg! border shadow-sm! hover:bg-secondary/80!"
                    disabled={busy || !selectedChannel.canLoadMore}
                    onclick={loadMoreFromSelectedChannel}
                  ><Plus /> Load more</button>
                {/if}
                {#if /^https?:\/\//iu.test(selectedChannel.source)}
                  {#if capabilities.channelManagement}
                    <button
                      class="secondary-button border-border! bg-secondary! bg-none! text-secondary-foreground! rounded-lg! border shadow-sm! hover:bg-secondary/80!"
                      onclick={loginToSelectedChannel}
                    ><Globe2 /> Sign in</button>
                  {/if}
                  <button
                    class="secondary-button border-border! bg-secondary! bg-none! text-secondary-foreground! rounded-lg! border shadow-sm! hover:bg-secondary/80!"
                    onclick={() => api.openExternal(selectedChannel!.source)}
                  ><ArrowUpRight /> Open channel</button>
                {/if}
                {#if capabilities.channelManagement}
                  <button
                    class="library-folder-delete text-destructive!"
                    disabled={busy}
                    onclick={removeSelectedChannel}
                  ><Trash2 /> Delete channel</button>
                {/if}
              </div>
            </section>
          </div>
        {:else if activeView === 'channels' && !selectedEntry}
          <div class="center-stage">
            <section class="empty-card border-border! bg-card! bg-none! text-card-foreground! rounded-xl! border shadow-sm!">
              <div class="empty-illustration bg-muted! text-muted-foreground!">
                <Radio />
              </div>
              <p class="eyebrow text-muted-foreground!">Channels</p>
              <h1>No channels yet</h1>
              <p class="empty-copy text-muted-foreground!">
                {capabilities.channelManagement
                  ? 'Add a channel to gather new items from a publication, feed, podcast, or profile.'
                  : 'Channel setup and gathering are currently available in the desktop app.'}
              </p>
              {#if capabilities.channelManagement}
                <div class="empty-actions">
                  <button
                    class="primary-button border-primary! bg-primary! bg-none! text-primary-foreground! rounded-lg! border shadow-sm! hover:bg-primary/80!"
                    onclick={createChannel}
                  ><Plus /> Add channel</button>
                </div>
              {/if}
            </section>
          </div>
        {:else if activeView === 'briefs' && !selectedEntry &&
        (selectedBrief || selectedVoiceBriefID === 'new')}
          {#if capabilities.briefAuthoring}
            {#key selectedVoiceBriefID}
              <VoiceBriefsView
                {api}
                voiceBriefID={selectedVoiceBriefID === 'new' ? '' : selectedVoiceBriefID}
                creating={selectedVoiceBriefID === 'new'}
                onselected={handleBriefSelected}
                onmessage={(value) => (message = value)}
              />
            {/key}
          {:else}
            <div class="native-no-results text-muted-foreground!">
              <Headphones />
              <p>Choose an episode to read or listen.</p>
            </div>
          {/if}
        {:else if selectedEntry}
          <div class="native-mobile-reader-bar border-border! bg-card! bg-none! text-card-foreground!">
            <button class="text-card-foreground! hover:bg-accent! hover:text-accent-foreground!" onclick={() => (mobileReaderVisible = false)}>
              <ChevronLeft />
              <span>Library</span>
            </button>
          </div>

          {#if selectedAudioURL && audioPlaying}
            <label class="native-reader-volume border-border! bg-popover! text-popover-foreground! rounded-xl! border shadow-sm!">
              <Volume2 aria-hidden="true" />
              <input
                aria-label="Volume"
                type="range"
                min="0"
                max="1"
                step="0.05"
                bind:value={audioVolume}
                style={`--played: ${audioVolume * 100}%`}
              />
            </label>
          {/if}

          <div class="native-document-scroll">
            <article
              class="native-document-body text-card-foreground! font-serif!"
              aria-busy={loadingText}
              oncontextmenu={capabilities.contextMenus
                ? (event) =>
                    showEntryContextMenu(event, selectedEntry!, selectedVariant)
                : undefined}
            >
              <div class="native-document-meta text-muted-foreground!">
                {wordCount.toLocaleString()} words
              </div>

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

          <footer
            class="native-document-footer native-reader-footer"
            aria-label="Document actions"
          >
            {#if selectedAudioURL}
              <div
                bind:this={audioPanel}
                id="reader-audio-player"
                class="native-reader-audio"
                class:collapsed={!audioExpanded}
                class:positioned={Boolean(audioPosition)}
                style={audioPosition
                  ? `left:${audioPosition.x}px;top:${audioPosition.y}px;right:auto;bottom:auto`
                  : undefined}
              >
                <button
                  type="button"
                  class="native-reader-audio-drag"
                  aria-label="Move audio controls with drag or arrow keys"
                  title="Drag to move. Use arrow keys for precise movement."
                  onpointerdown={startAudioDrag}
                  onkeydown={moveAudioWithKeyboard}
                >
                  <span aria-hidden="true"></span>
                </button>
                <AudioPlayer
                  src={selectedAudioURL}
                  title={selectedEntry.title}
                  bind:playing={audioPlaying}
                  bind:volume={audioVolume}
                  showVolume={false}
                  presentation="apple"
                />
              </div>
            {/if}

            <DepthControl
              variants={availableVariants}
              selected={selectedVariant}
              onselect={selectVariant}
            />

            <div class="native-footer-actions">
              {#if selectedAudioURL}
                <button
                  class="native-icon-button"
                  class:active={audioExpanded}
                  aria-label={audioExpanded ? 'Collapse audio player' : 'Expand audio player'}
                  aria-controls="reader-audio-player"
                  aria-expanded={audioExpanded}
                  title={audioExpanded ? 'Collapse audio player' : 'Expand audio player'}
                  onclick={() => (audioExpanded = !audioExpanded)}
                >
                  <Headphones />
                </button>
              {/if}

              {#if selectedEntry.sourceURL}
                <button
                  class="native-icon-button"
                  aria-label="Open original source"
                  title="Open original source"
                  onclick={() => api.openExternal(selectedEntry!.sourceURL!)}
                >
                  <ArrowUpRight />
                </button>
              {/if}

              {#if selectedEntry.origin !== 'shared'}
                <button
                  class="native-icon-button"
                  aria-label="Share document"
                  title="Create share link"
                  onclick={openSharing}
                >
                  {#if shareBusy}
                    <LoaderCircle class="spin" />
                  {:else}
                    <Share2 />
                  {/if}
                </button>
              {/if}

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
          <span title={ingestion.message}>{ingestion.message}</span>
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
        {#if capabilities.agents}
          <button class:active={settingsTab === 'agents'} onclick={() => (settingsTab = 'agents')}>AI agents</button>
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
        {/if}
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
      <main class="settings-content">
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

      {#if capabilities.agents}
      <section class="settings-card border-border! bg-card! bg-none! text-card-foreground! rounded-xl! border shadow-sm!">
        <div class="settings-card-heading">
          <div class="provider-mark bg-muted! bg-none! text-foreground! rounded-lg!"><Sparkles /></div>
          <div>
            <h3>About you</h3>
            <p>Describe your work, current goals, interests, and what usually matters less.</p>
          </div>
        </div>
        <textarea
          class="about-you-field border-input! bg-background! bg-none! text-foreground! placeholder:text-muted-foreground! rounded-lg! border shadow-sm! focus:border-ring focus:ring-2 focus:ring-ring/20"
          aria-label="About you"
          bind:value={aboutYouDraft}
          maxlength="10000"
          placeholder="For example: I lead a small product team, I’m currently improving onboarding, and I care most about practical AI tools and customer research."
        ></textarea>
        <div class="panel-actions about-you-actions">
          <button
            class="primary-button border-primary! bg-primary! bg-none! text-primary-foreground! rounded-lg! border shadow-sm! hover:bg-primary/80!"
            type="button"
            disabled={busy || aboutYouDraft === aboutYou}
            onclick={saveAboutYou}
          >
            {#if busy}<LoaderCircle class="spin" />{:else}<Check />{/if}
            Save
          </button>
        </div>
      </section>
      {/if}

      {#if capabilities.nativeSettings}
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
              Captured podcast audio stays remote. Channel and agent-imported items remain text-only. Generated voice brief episodes keep their audio.
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
      {/if}

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
          <button class="secondary-button border-border! bg-secondary! bg-none! text-secondary-foreground! rounded-lg! border shadow-sm! hover:bg-secondary/80!" onclick={() => api.openExternal('https://readbriefly.fyi/feedback')}>
            <ArrowUpRight /> Feedback
          </button>
        </div>
      </section>

      {:else if settingsTab === 'agents'}
      <section
        class="settings-card border-border! bg-card! bg-none! text-card-foreground! rounded-xl! border shadow-sm!"
        class:processing-choice-selected={usesBrieflyAI}
      >
        <div class="settings-card-heading">
          <div class="flex flex-1 items-start justify-between gap-3">
            <div>
              <h3>Briefly AI</h3>
              <p>Included with your membership. Briefly uses a cost-efficient hosted model under a zero data retention agreement.</p>
            </div>
            {#if usesBrieflyAI}
              <span class="text-primary! inline-flex shrink-0 items-center gap-1.5 text-[10px] font-semibold">
                <span class="border-primary! bg-primary! size-3 rounded-full border-[3px]"></span>
                In use
              </span>
            {:else}
              <span class="text-muted-foreground! inline-flex shrink-0 items-center gap-1.5 text-[10px] font-semibold">
                <span class="border-muted-foreground/50! size-3 rounded-full border"></span>
                Not in use
              </span>
            {/if}
          </div>
        </div>
        {#if !usesBrieflyAI}
          <div class="panel-actions processing-actions">
            <span></span>
            <button
              class="primary-button border-primary! bg-primary! bg-none! text-primary-foreground! rounded-lg! border shadow-sm! hover:bg-primary/80!"
              type="button"
              disabled={busy}
              onclick={useBrieflyAI}
            >
              Use Briefly AI
            </button>
          </div>
        {/if}
      </section>

      <section
        class="settings-card border-border! bg-card! bg-none! text-card-foreground! rounded-xl! border shadow-sm!"
        class:processing-choice-selected={Boolean(aiCommandPreferences && !usesBrieflyAI)}
      >
        <div class="settings-card-heading">
          <div class="flex flex-1 items-start justify-between gap-3">
            <div>
              <h3>Use your own AI</h3>
              <p>Choose an agent or enter your own command.</p>
            </div>
            {#if aiCommandPreferences && !usesBrieflyAI}
              <span class="text-primary! inline-flex shrink-0 items-center gap-1.5 text-[10px] font-semibold">
                <span class="border-primary! bg-primary! size-3 rounded-full border-[3px]"></span>
                In use
              </span>
            {:else}
              <span class="text-muted-foreground! inline-flex shrink-0 items-center gap-1.5 text-[10px] font-semibold">
                <span class="border-muted-foreground/50! size-3 rounded-full border"></span>
                Not in use
              </span>
            {/if}
          </div>
        </div>
        <div class="grid gap-3">
          <label class="theme-field grid gap-1.5">
            <span class="text-muted-foreground! text-[10px] font-semibold uppercase tracking-[0.06em]">Agent</span>
            <select
              class="border-input! bg-background! bg-none! text-foreground! h-9 w-full rounded-lg! border px-2.5 outline-none shadow-sm! focus:border-ring focus:ring-2 focus:ring-ring/20"
              value={selectedProcessingPreset}
              onchange={(event) => {
                const command = (event.currentTarget as HTMLSelectElement).value;
                if (command === 'custom') {
                  if (draftUsesBrieflyAI) processingCommandDraft = '';
                } else {
                  processingCommandDraft = command;
                }
              }}
            >
              <option value="" disabled>Choose an agent</option>
              {#each aiCommandPreferences?.processingPresets ?? [] as preset (preset.command)}
                <option value={preset.command}>{preset.label}</option>
              {/each}
              <option value="custom">Custom</option>
            </select>
          </label>
          {#if !draftUsesBrieflyAI}
            <label class="theme-field grid gap-1.5">
              <span class="text-muted-foreground! text-[10px] font-semibold uppercase tracking-[0.06em]">Command</span>
              <input
                class="border-input! bg-background! bg-none! text-foreground! h-9 w-full rounded-lg! border px-2.5 outline-none shadow-sm! font-mono! text-xs focus:border-ring focus:ring-2 focus:ring-ring/20"
                value={processingCommandDraft}
                oninput={(event) => {
                  processingCommandDraft =
                    (event.currentTarget as HTMLInputElement).value;
                }}
                spellcheck="false"
              />
            </label>
          {/if}
        </div>
        {#if !draftUsesBrieflyAI}
          <div class="panel-actions processing-actions">
            <button
              class="secondary-button border-border! bg-secondary! bg-none! text-secondary-foreground! rounded-lg! border shadow-sm! hover:bg-secondary/80!"
              type="button"
              disabled={busy || testingAICommand}
              onclick={testAICommand}
            >
              {#if testingAICommand}<LoaderCircle class="spin" />{/if}
              Test command
            </button>
            <button
              class="primary-button border-primary! bg-primary! bg-none! text-primary-foreground! rounded-lg! border shadow-sm! hover:bg-primary/80!"
              type="button"
              disabled={busy || testingAICommand}
              onclick={() => saveAICommands('Processing preference saved.')}
            >
              Save command
            </button>
          </div>
        {/if}
      </section>

      <section class="settings-card border-border! bg-card! bg-none! text-card-foreground! rounded-xl! border shadow-sm!">
        <div class="settings-card-heading">
          <div>
            <h3>Open agent</h3>
            <p>Open ChatGPT or run another agent at your library workspace.</p>
          </div>
        </div>
        <div class="grid gap-3">
          <label class="theme-field grid gap-1.5">
            <span class="text-muted-foreground! text-[10px] font-semibold uppercase tracking-[0.06em]">Default</span>
            <select
              class="border-input! bg-background! bg-none! text-foreground! h-9 w-full rounded-lg! border px-2.5 outline-none shadow-sm! focus:border-ring focus:ring-2 focus:ring-ring/20"
              value={selectedAgentPreset}
              onchange={(event) => {
                const command = (event.currentTarget as HTMLSelectElement).value;
                if (command !== 'custom') agentCommandDraft = command;
              }}
            >
              {#each aiCommandPreferences?.agentPresets ?? [] as preset (preset.command)}
                <option value={preset.command}>{preset.label}</option>
              {/each}
              <option value="custom">Custom</option>
            </select>
          </label>
          <label class="theme-field grid gap-1.5">
            <span class="text-muted-foreground! text-[10px] font-semibold uppercase tracking-[0.06em]">Command</span>
            <input
              class="border-input! bg-background! bg-none! text-foreground! h-9 w-full rounded-lg! border px-2.5 outline-none shadow-sm! font-mono! text-xs focus:border-ring focus:ring-2 focus:ring-ring/20"
              value={agentCommandDraft}
              oninput={(event) => {
                agentCommandDraft =
                  (event.currentTarget as HTMLInputElement).value;
              }}
              spellcheck="false"
            />
          </label>
        </div>
        <div class="panel-actions processing-actions">
          <span></span>
          <button
            class="primary-button border-primary! bg-primary! bg-none! text-primary-foreground! rounded-lg! border shadow-sm! hover:bg-primary/80!"
            type="button"
            disabled={busy || testingAICommand}
            onclick={() => saveAICommands('Agent preference saved.')}
          >
            Save command
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
            <p class="processing-empty border-border! bg-muted! bg-none! text-muted-foreground! rounded-lg! border">No topics yet. The processing agent can create one.</p>
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
      {/if}
      </main>
    </div>
  </section>
{/if}

{#if sharingOpen && shareTarget}
  <div
    class="audio-backdrop"
    role="presentation"
    onclick={(event) => {
      if (event.currentTarget === event.target) sharingOpen = false;
    }}
  >
    <aside
      class="audio-panel share-panel border-border! bg-popover! bg-none! text-popover-foreground! rounded-xl! border shadow-sm! font-sans!"
      aria-label="Share document"
    >
      <header class="audio-header">
        <div>
          <p class="eyebrow text-muted-foreground!">Shareable reader</p>
          <h2>Share link</h2>
        </div>
        <button
          class="native-icon-button"
          aria-label="Close sharing"
          onclick={() => (sharingOpen = false)}
        ><X /></button>
      </header>
      <div class="audio-content share-content">
        <p class="text-muted-foreground!">
          Publish the available summaries for “{shareTarget.title}”. The private captured
          source text is never included.
        </p>
        {#if shareError}
          <p class="share-error text-destructive!" role="alert">{shareError}</p>
        {/if}
        {#if shareBusy}
          <p class="share-status text-muted-foreground!"><LoaderCircle class="spin" /> Loading…</p>
        {:else if shareLink.shared && shareLink.url}
          <input
            class="share-url border-input! bg-background! text-foreground! rounded-lg! border"
            aria-label="Share URL"
            value={shareLink.url}
            readonly
          />
          <div class="panel-actions">
            <button class="primary-button border-primary! bg-primary! text-primary-foreground! rounded-lg! border shadow-sm!" onclick={copyShareLink}>
              <Clipboard /> Copy link
            </button>
            <button class="secondary-button border-border! bg-secondary! text-secondary-foreground! rounded-lg! border shadow-sm!" onclick={stopSharing}>
              <Trash2 /> Stop sharing
            </button>
          </div>
        {:else if shareLink.shared}
          <p class="share-status text-muted-foreground!">
            <LoaderCircle class="spin" /> The shareable reader is being prepared.
          </p>
        {:else}
          <button class="primary-button border-primary! bg-primary! text-primary-foreground! rounded-lg! border shadow-sm!" onclick={saveSharing}>
            <Share2 /> Create share link
          </button>
        {/if}
      </div>
    </aside>
  </div>
{/if}
