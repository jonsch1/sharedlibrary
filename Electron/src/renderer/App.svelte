<script lang="ts">
  import {
    Archive,
    ArrowUpRight,
    Check,
    Clipboard,
    FileText,
    FolderOpen,
    LibraryBig,
    LoaderCircle,
    Pencil,
    RefreshCw,
    Search,
    Settings2,
    Trash2,
    X
  } from '@lucide/svelte';
  import MarkdownView from './MarkdownView.svelte';
  import {
    libraryVariants,
    type DesktopLibraryEntry,
    type DesktopLibrarySnapshot,
    type LibraryVariant
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
  let editing = $state(false);
  let editorText = $state('');
  let settingsOpen = $state(false);
  let busy = $state(false);
  let message = $state('');

  let entries = $derived(snapshot?.entries ?? []);
  let selectedEntry = $derived(
    entries.find((entry) => entry.id === selectedID) ?? entries[0] ?? null
  );
  let normalizedQuery = $derived(query.trim().toLowerCase());
  let filteredEntries = $derived(
    entries.filter((entry) => {
      if (selectedTopic !== 'all' && !entry.topicNames.includes(selectedTopic)) return false;
      if (!normalizedQuery) return true;
      return [
        entry.title,
        entry.excerpt,
        ...entry.topicNames,
        ...entry.tags
      ]
        .join(' ')
        .toLowerCase()
        .includes(normalizedQuery);
    })
  );
  let wordCount = $derived(selectedText.trim() ? selectedText.trim().split(/\s+/).length : 0);

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
      const removeLibraryListener = window.sharedLibrary.onLibraryChanged(applySnapshot);
      const removeWorkspaceListener =
        window.sharedLibraryDesktopEvents.onChooseWorkspace(() => void chooseWorkspace());
      const removeMessageListener =
        window.sharedLibraryDesktopEvents.onOperationMessage((result) => {
          message = result.message ?? '';
          if (result.selectedEntryID) selectedID = result.selectedEntryID;
        });
      window.addEventListener(
        'beforeunload',
        () => {
          removeLibraryListener();
          removeWorkspaceListener();
          removeMessageListener();
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
    selectedID = entry.id;
    selectedVariant = entry.availableVariants.includes('concise')
      ? 'concise'
      : (entry.availableVariants[0] ?? 'source');
    editing = false;
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
      if (result.selectedEntryID) selectedID = result.selectedEntryID;
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
      message = result.message;
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
  <title>{selectedEntry?.title ?? 'Shared Library'}</title>
</svelte:head>

<div class="app-shell">
  <header class="app-header">
    <div class="brand">
      <span class="brand-mark"><LibraryBig /></span>
      <div>
        <strong>Shared Library</strong>
        <small>Electron preview</small>
      </div>
    </div>
    <div class="header-actions">
      <button class="secondary-button" onclick={refresh} disabled={busy}>
        <RefreshCw class={busy ? 'spin' : ''} />
        Refresh
      </button>
      <button class="primary-button" onclick={captureClipboard} disabled={busy}>
        <Clipboard />
        Capture
      </button>
      <button
        class="icon-button"
        aria-label="Settings"
        title="Settings"
        onclick={() => (settingsOpen = true)}
      >
        <Settings2 />
      </button>
    </div>
  </header>

  {#if loading}
    <main class="state-view">
      <LoaderCircle class="spin" />
      <h1>Opening your library</h1>
    </main>
  {:else if entries.length === 0}
    <main class="state-view">
      <Archive />
      <h1>Your library is ready</h1>
      <p>Capture clipboard text or choose an existing Shared Library workspace.</p>
      <div class="state-actions">
        <button class="primary-button" onclick={captureClipboard}><Clipboard /> Capture</button>
        <button class="secondary-button" onclick={chooseWorkspace}><FolderOpen /> Choose folder</button>
      </div>
    </main>
  {:else}
    <main class="workspace">
      <aside class="library-pane">
        <div class="library-toolbar">
          <label class="search-field">
            <Search />
            <input bind:value={query} placeholder="Search" aria-label="Search library" />
            {#if query}
              <button aria-label="Clear search" onclick={() => (query = '')}><X /></button>
            {/if}
          </label>
          <div class="topic-strip" aria-label="Topic filter">
            <button
              class:active={selectedTopic === 'all'}
              onclick={() => (selectedTopic = 'all')}
            >All</button>
            {#each snapshot?.topics ?? [] as topic}
              <button
                class:active={selectedTopic === topic}
                onclick={() => (selectedTopic = topic)}
              >{topic}</button>
            {/each}
          </div>
        </div>
        <div class="entry-list">
          {#if filteredEntries.length === 0}
            <div class="list-empty">
              <FileText />
              <span>No matching documents</span>
            </div>
          {:else}
            {#each filteredEntries as entry (entry.id)}
              <button
                class="entry-row"
                class:selected={entry.id === selectedEntry?.id}
                onclick={() => selectEntry(entry)}
              >
                <FileText />
                <span>{entry.title}</span>
              </button>
            {/each}
          {/if}
        </div>
      </aside>

      <section class="reader-pane">
        {#if selectedEntry}
          <div class="document-scroll">
            <article class="document">
              <header class="document-header">
                <div class="document-kicker">
                  {#each selectedEntry.topicNames as topic}
                    <span>{topic}</span>
                  {/each}
                </div>
                <h1>{selectedEntry.title}</h1>
                {#if selectedEntry.excerpt}<p>{selectedEntry.excerpt}</p>{/if}
              </header>
              {#if loadingText}
                <div class="document-loading"><LoaderCircle class="spin" /></div>
              {:else if editing}
                <textarea class="document-editor" bind:value={editorText}></textarea>
              {:else}
                <MarkdownView text={selectedText} />
              {/if}
            </article>
          </div>

          <footer class="reader-footer">
            <div class="footer-stat">{wordCount.toLocaleString()} words</div>
            <div class="variant-control" aria-label="Document version">
              {#each selectedEntry.availableVariants as variant}
                <button
                  class:active={selectedVariant === variant}
                  onclick={() => {
                    selectedVariant = variant;
                    editing = false;
                  }}
                >{variantNames[variant]}</button>
              {/each}
            </div>
            <div class="footer-actions">
              {#if editing}
                <button class="secondary-button" onclick={() => {
                  editing = false;
                  editorText = selectedText;
                }}>Cancel</button>
                <button class="primary-button" onclick={save} disabled={busy}>
                  <Check /> Save
                </button>
              {:else}
                {#if selectedEntry.sourceURL}
                  <button
                    class="icon-button"
                    title="Open original"
                    aria-label="Open original"
                    onclick={() => window.sharedLibrary.openExternal(selectedEntry!.sourceURL!)}
                  ><ArrowUpRight /></button>
                {/if}
                <button
                  class="icon-button"
                  title="Reveal in folder"
                  aria-label="Reveal in folder"
                  onclick={() => window.sharedLibrary.revealEntry(selectedEntry!.id)}
                ><FolderOpen /></button>
                <button
                  class="icon-button"
                  title="Edit"
                  aria-label="Edit"
                  onclick={() => {
                    editorText = selectedText;
                    editing = true;
                  }}
                ><Pencil /></button>
                <button
                  class="icon-button danger"
                  title="Move to Trash"
                  aria-label="Move to Trash"
                  onclick={trashSelected}
                ><Trash2 /></button>
              {/if}
            </div>
          </footer>
        {/if}
      </section>
    </main>
  {/if}
</div>

{#if settingsOpen}
  <div class="modal-backdrop" role="presentation" onclick={() => (settingsOpen = false)}></div>
  <aside class="settings-panel" aria-label="Settings">
    <header>
      <div>
        <small>Desktop</small>
        <h2>Settings</h2>
      </div>
      <button class="icon-button" aria-label="Close settings" onclick={() => (settingsOpen = false)}>
        <X />
      </button>
    </header>
    <section>
      <h3>Library workspace</h3>
      <p>All clients use the same Markdown folder structure. No conversion is required.</p>
      <code>{snapshot?.workspacePath}</code>
      <button class="secondary-button" onclick={chooseWorkspace}>
        <FolderOpen /> Choose another folder
      </button>
    </section>
    <section>
      <h3>Cross-platform baseline</h3>
      <p>
        Browsing, editing, capture, summaries, and coordinated Trash are active.
        Google Drive, extraction, processing, narration, and share links will be
        connected in the next migration phases.
      </p>
    </section>
  </aside>
{/if}

{#if message}
  <button class="toast" onclick={() => (message = '')}>{message}</button>
{/if}
