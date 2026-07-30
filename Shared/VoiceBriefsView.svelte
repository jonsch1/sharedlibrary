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
    type VoiceBriefDefinition,
    type VoiceBriefDraft,
    type VoiceBriefSnapshot,
    type SharedLibraryDesktopAPI
  } from './contracts';

  let {
    api,
    voiceBriefID,
    creating = false,
    onselected,
    onmessage
  }: {
    api: SharedLibraryDesktopAPI;
    voiceBriefID: string;
    creating?: boolean;
    onselected: (voiceBriefID: string) => void;
    onmessage: (message: string) => void;
  } = $props();

  let snapshot = $state<VoiceBriefSnapshot | null>(null);
  let selectedID = $state('');
  let draft = $state<VoiceBriefDraft>(emptyDraft());
  let busy = $state(false);
  let dirty = $state(false);
  let revision = $state(0);
  let saveTimer: ReturnType<typeof setTimeout> | null = null;

  let selected = $derived(
    snapshot?.voiceBriefs.find((voiceBrief) => voiceBrief.id === selectedID) ?? null
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
      selectedID = voiceBriefID;
      dirty = creating;
      applySnapshot(await api.getVoiceBriefs());
      const remove = api.onVoiceBriefsChanged((next) => {
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
      onmessage(error instanceof Error ? error.message : 'Voice briefs could not be loaded.');
    }
  }

  function applySnapshot(next: VoiceBriefSnapshot, refreshDraft = true): void {
    snapshot = next;
    const voiceBrief = next.voiceBriefs.find((candidate) => candidate.id === selectedID);
    if (refreshDraft && voiceBrief) loadDraft(voiceBrief);
  }

  function loadDraft(voiceBrief: VoiceBriefDefinition): void {
    draft = {
      id: voiceBrief.id,
      title: voiceBrief.title,
      prompt: voiceBrief.prompt,
      prioritizeForMe: voiceBrief.prioritizeForMe,
      schedule: voiceBrief.schedule,
      length: '',
      sources: [...voiceBrief.sources]
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
    const knownIDs = new Set(snapshot?.voiceBriefs.map((voiceBrief) => voiceBrief.id) ?? []);
    busy = true;
    try {
      const next = await api.saveVoiceBrief({
        ...draft,
        title,
        prompt,
        sources: [...draft.sources]
      });
      snapshot = next;
      const saved =
        next.voiceBriefs.find((voiceBrief) => voiceBrief.id === draft.id) ??
        next.voiceBriefs.find((voiceBrief) => !knownIDs.has(voiceBrief.id)) ??
        next.voiceBriefs.find((voiceBrief) => voiceBrief.title === title);
      if (saved) {
        selectedID = saved.id;
        onselected(saved.id);
        if (revision === savingRevision) loadDraft(saved);
      }
    } catch (error) {
      onmessage(error instanceof Error ? error.message : 'The voice brief could not be saved.');
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
      applySnapshot(await api.runVoiceBrief(selected.id));
      onmessage(
        snapshot?.voiceBriefs.find((voiceBrief) => voiceBrief.id === selected.id)?.message ??
          'Voice brief generation finished.'
      );
    } catch (error) {
      onmessage(error instanceof Error ? error.message : 'The voice brief could not be generated.');
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
      applySnapshot(await api.removeVoiceBrief(selected.id));
      onselected('');
      onmessage('Voice brief moved to Trash.');
    } catch (error) {
      onmessage(error instanceof Error ? error.message : 'The voice brief could not be removed.');
    } finally {
      busy = false;
    }
  }

  function emptyDraft(): VoiceBriefDraft {
    return {
      title: 'New voice brief',
      prompt: 'Connect the most important updates into one concise, conversational briefing.',
      prioritizeForMe: false,
      schedule: 'manual',
      length: '',
      sources: []
    };
  }
</script>

<div class="voice-brief-document-workspace bg-background! bg-none! text-foreground! font-sans!">
  <header class="voice-brief-document-toolbar border-border!">
    <div class="voice-brief-document-actions">
      <span class="voice-brief-save-status text-muted-foreground!">
        {#if !dirty}<Check />{/if}{saveStatus}
      </span>
      {#if selected}
        <button
          class="secondary-button border-border! bg-secondary! bg-none! text-secondary-foreground! rounded-lg! border shadow-sm! hover:bg-secondary/80!"
          onclick={() => api.revealVoiceBrief(selected!.id)}
        ><FileText /> File</button>
      {/if}
      <button
        class="primary-button border-primary! bg-primary! bg-none! text-primary-foreground! rounded-lg! border shadow-sm! hover:bg-primary/80!"
        disabled={busy || !selected || !gatheredItems.length}
        onclick={generateNow}
      >
        {#if busy}<LoaderCircle class="spin" />{:else}<Sparkles />{/if}
        Generate voice brief
      </button>
    </div>
  </header>

  <div class="voice-brief-document-scroll">
    <section class="voice-brief-document">
      <input
        class="voice-brief-document-title text-foreground! placeholder:text-muted-foreground!"
        aria-label="Voice brief title"
        bind:value={draft.title}
        oninput={markDirty}
        placeholder="Voice brief title"
      />
      <section class="brief-editor-section" aria-labelledby="brief-direction-title">
        <header>
          <h2 id="brief-direction-title">Editorial direction</h2>
          <p class="text-muted-foreground!">
            Tell Briefly what to prioritize, connect, or leave out.
          </p>
        </header>
        <textarea
          class="voice-brief-prompt border-input! bg-background! text-foreground! placeholder:text-muted-foreground! rounded-lg! border focus:border-ring focus:ring-2 focus:ring-ring/20"
          aria-label="Voice brief instructions"
          bind:value={draft.prompt}
          oninput={markDirty}
          placeholder="Describe the voice brief you want Briefly to make."
        ></textarea>
      </section>

      <section class="brief-editor-section" aria-labelledby="brief-personalization-title">
        <header>
          <h2 id="brief-personalization-title">Personalization</h2>
          <p class="text-muted-foreground!">
            Use your personal context to decide which updates deserve the most attention.
          </p>
        </header>
        <label class="brief-personalization border-border! bg-muted/40! rounded-lg! border">
          <input
            type="checkbox"
            checked={draft.prioritizeForMe}
            onchange={(event) => {
              draft.prioritizeForMe =
                (event.currentTarget as HTMLInputElement).checked;
              markDirty();
            }}
          />
          <span>
            <strong>Prioritize for me</strong>
            <small class="text-muted-foreground!">
              Uses “About you” from Settings while retaining materially important updates.
            </small>
          </span>
        </label>
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

      <section class="brief-compact-settings" aria-label="Voice brief timing">
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
        <footer class="voice-brief-document-footer border-border!">
          <button
            class="voice-brief-delete text-destructive!"
            onclick={remove}
            disabled={busy}
          ><Trash2 /> Delete voice brief</button>
        </footer>
      {/if}
    </section>
  </div>
</div>
