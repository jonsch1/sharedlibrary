<script lang="ts">
	import { onMount } from 'svelte';
	import ArchiveIcon from '@lucide/svelte/icons/archive';
	import ArrowUpRightIcon from '@lucide/svelte/icons/arrow-up-right';
	import BookOpenIcon from '@lucide/svelte/icons/book-open';
	import CheckIcon from '@lucide/svelte/icons/check';
	import ChevronLeftIcon from '@lucide/svelte/icons/chevron-left';
	import Clock3Icon from '@lucide/svelte/icons/clock-3';
	import CloudIcon from '@lucide/svelte/icons/cloud';
	import FileUpIcon from '@lucide/svelte/icons/file-up';
	import HeadphonesIcon from '@lucide/svelte/icons/headphones';
	import LibraryBigIcon from '@lucide/svelte/icons/library-big';
	import ListMusicIcon from '@lucide/svelte/icons/list-music';
	import LoaderCircleIcon from '@lucide/svelte/icons/loader-circle';
	import LogOutIcon from '@lucide/svelte/icons/log-out';
	import PauseIcon from '@lucide/svelte/icons/pause';
	import PlayIcon from '@lucide/svelte/icons/play';
	import PlusIcon from '@lucide/svelte/icons/plus';
	import SearchIcon from '@lucide/svelte/icons/search';
	import ShieldCheckIcon from '@lucide/svelte/icons/shield-check';
	import SkipForwardIcon from '@lucide/svelte/icons/skip-forward';
	import SquareIcon from '@lucide/svelte/icons/square';
	import Trash2Icon from '@lucide/svelte/icons/trash-2';
	import Volume2Icon from '@lucide/svelte/icons/volume-2';
	import XIcon from '@lucide/svelte/icons/x';
	import MarkdownText from '$lib/MarkdownText.svelte';
	import { Badge } from '$lib/components/ui/badge/index.js';
	import { Button } from '$lib/components/ui/button/index.js';
	import { Input } from '$lib/components/ui/input/index.js';
	import * as NativeSelect from '$lib/components/ui/native-select/index.js';
	import { Separator } from '$lib/components/ui/separator/index.js';
	import { Slider } from '$lib/components/ui/slider/index.js';
	import {
		demoProjection,
		libraryVariants,
		loadLibraryProjection,
		parseLibraryProjection,
		preferredVariant,
		readingMinutes,
		saveLibraryProjection,
		textFor,
		type LibraryEntry,
		type LibraryOrigin,
		type LibraryProjection,
		type LibraryVariant
	} from '$lib/library.js';
	import {
		beginOpenRouterConnection,
		clearOpenRouterAudioCache,
		completeOpenRouterConnection,
		disconnectOpenRouter,
		loadOpenRouterCredential,
		loadVoicePreference,
		openRouterVoices,
		saveVoicePreference,
		type OpenRouterCredential,
		type OpenRouterVoice
	} from '$lib/openrouter.js';
	import { SpeechPlayer } from '$lib/speech-player.svelte.js';

	type OriginFilter = 'all' | LibraryOrigin;

	const variantNames: Record<LibraryVariant, string> = {
		brief: 'Brief',
		concise: 'Concise',
		detailed: 'Detailed',
		comprehensive: 'Comprehensive',
		source: 'Original'
	};

	let projection = $state<LibraryProjection | null>(null);
	let selectedEntryID = $state<string | null>(null);
	let selectedVariant = $state<LibraryVariant>('concise');
	let query = $state('');
	let originFilter = $state<OriginFilter>('all');
	let topicFilter = $state('all');
	let loading = $state(true);
	let importMessage = $state('');
	let isDemo = $state(false);
	let mobileReaderVisible = $state(false);
	let queueVisible = $state(false);
	let audioSettingsVisible = $state(false);
	let fileInput = $state<HTMLInputElement>();
	let playbackRate = $state(1);
	let openRouterCredential = $state<OpenRouterCredential | null>(null);
	let openRouterVoice = $state<OpenRouterVoice>('eve');
	let openRouterBusy = $state(false);
	let audioMessage = $state('');
	const player = new SpeechPlayer();

	let entries = $derived(projection?.entries ?? []);
	let selectedEntry = $derived(
		entries.find((entry) => entry.id === selectedEntryID) ?? entries[0] ?? null
	);
	let topics = $derived(
		Array.from(new Set(entries.flatMap((entry) => entry.topicNames))).sort((a, b) =>
			a.localeCompare(b)
		)
	);
	let normalizedQuery = $derived(query.trim().toLocaleLowerCase());
	let filteredEntries = $derived(
		entries.filter((entry) => {
			if (originFilter !== 'all' && entry.origin !== originFilter) return false;
			if (topicFilter !== 'all' && !entry.topicNames.includes(topicFilter)) return false;
			if (!normalizedQuery) return true;
			const searchable = [
				entry.title,
				entry.excerpt,
				...entry.topicNames,
				...entry.tags,
				entry.sharedByDisplayName ?? ''
			]
				.join(' ')
				.toLocaleLowerCase();
			return searchable.includes(normalizedQuery);
		})
	);
	let selectedText = $derived(
		selectedEntry ? (textFor(selectedEntry, selectedVariant)?.text ?? '') : ''
	);
	let availableVariants = $derived(
		selectedEntry
			? libraryVariants.filter((variant) => textFor(selectedEntry as LibraryEntry, variant))
			: []
	);
	let currentVoiceName = $derived(
		openRouterVoices.find((voice) => voice.id === openRouterVoice)?.name ?? 'Eve'
	);
	let toastMessage = $derived(audioMessage || player.notice || importMessage);

	$effect(() => {
		if (selectedEntry && !textFor(selectedEntry, selectedVariant)) {
			selectedVariant = preferredVariant(selectedEntry);
		}
	});

	onMount(() => {
		let active = true;
		openRouterVoice = loadVoicePreference();
		void initializeOpenRouter(() => active);
		loadLibraryProjection()
			.then((saved) => {
				if (!active || !saved) return;
				setProjection(saved, false);
			})
			.catch((error) => {
				importMessage = error instanceof Error ? error.message : 'Could not open the offline library.';
			})
			.finally(() => {
				loading = false;
			});
		return () => {
			active = false;
			player.dispose();
		};
	});

	async function initializeOpenRouter(isActive: () => boolean): Promise<void> {
		try {
			const connected = await completeOpenRouterConnection();
			const credential = connected ?? (await loadOpenRouterCredential());
			if (!isActive()) return;
			openRouterCredential = credential;
			player.configureOpenRouter(credential, openRouterVoice);
			if (connected) {
				audioMessage = `OpenRouter connected. ${currentVoiceName} is ready.`;
				audioSettingsVisible = true;
			}
		} catch (error) {
			if (!isActive()) return;
			audioMessage =
				error instanceof Error ? error.message : 'OpenRouter sign-in could not be completed.';
			audioSettingsVisible = true;
		}
	}

	function setProjection(nextProjection: LibraryProjection, demo: boolean): void {
		projection = nextProjection;
		isDemo = demo;
		const firstEntry = nextProjection.entries[0] ?? null;
		selectedEntryID = firstEntry?.id ?? null;
		selectedVariant = firstEntry ? preferredVariant(firstEntry) : 'concise';
		query = '';
		originFilter = 'all';
		topicFilter = 'all';
		mobileReaderVisible = false;
	}

	async function importSnapshot(event: Event): Promise<void> {
		const input = event.currentTarget as HTMLInputElement;
		const file = input.files?.[0];
		if (!file) return;
		importMessage = '';
		try {
			const parsed = parseLibraryProjection(JSON.parse(await file.text()));
			await saveLibraryProjection(parsed);
			setProjection(parsed, false);
			importMessage = `Imported ${parsed.entries.length} ${parsed.entries.length === 1 ? 'item' : 'items'} for offline use.`;
		} catch (error) {
			importMessage = error instanceof Error ? error.message : 'The snapshot could not be imported.';
		} finally {
			input.value = '';
		}
	}

	function showDemo(): void {
		setProjection(demoProjection, true);
		importMessage = 'This is sample content. Import your snapshot when you are ready.';
	}

	function selectEntry(entry: LibraryEntry): void {
		selectedEntryID = entry.id;
		selectedVariant = preferredVariant(entry);
		mobileReaderVisible = true;
	}

	function listen(): void {
		if (!selectedEntry) return;
		player.configureOpenRouter(openRouterCredential, openRouterVoice);
		player.play(selectedEntry, selectedVariant);
	}

	function updateRate(rate: number): void {
		playbackRate = rate;
		player.setRate(rate);
	}

	async function connectOpenRouter(): Promise<void> {
		openRouterBusy = true;
		audioMessage = '';
		try {
			await beginOpenRouterConnection();
		} catch (error) {
			openRouterBusy = false;
			audioMessage =
				error instanceof Error ? error.message : 'Could not start OpenRouter sign-in.';
		}
	}

	async function removeOpenRouterConnection(): Promise<void> {
		openRouterBusy = true;
		try {
			await disconnectOpenRouter();
			openRouterCredential = null;
			player.configureOpenRouter(null, openRouterVoice);
			audioMessage = 'OpenRouter disconnected. Device speech remains available.';
		} catch (error) {
			audioMessage =
				error instanceof Error ? error.message : 'Could not disconnect OpenRouter.';
		} finally {
			openRouterBusy = false;
		}
	}

	function updateVoice(event: Event): void {
		const selected = (event.currentTarget as HTMLSelectElement).value as OpenRouterVoice;
		if (!openRouterVoices.some((voice) => voice.id === selected)) return;
		openRouterVoice = selected;
		saveVoicePreference(selected);
		player.configureOpenRouter(openRouterCredential, selected);
		audioMessage = `${openRouterVoices.find((voice) => voice.id === selected)?.name ?? 'Voice'} selected.`;
	}

	async function clearAudioCache(): Promise<void> {
		try {
			await clearOpenRouterAudioCache();
			audioMessage = 'Generated audio cache cleared from this device.';
		} catch {
			audioMessage = 'The generated audio cache could not be cleared.';
		}
	}

	function toggleAudioSettings(): void {
		audioSettingsVisible = !audioSettingsVisible;
		queueVisible = false;
	}

	function dismissToast(): void {
		importMessage = '';
		audioMessage = '';
		player.notice = '';
	}

	function formatDate(value?: string): string {
		if (!value) return '';
		return new Intl.DateTimeFormat(undefined, {
			day: 'numeric',
			month: 'short',
			year: 'numeric'
		}).format(new Date(value));
	}

	function formatGeneratedAt(value: string): string {
		return new Intl.DateTimeFormat(undefined, {
			day: 'numeric',
			month: 'short',
			hour: 'numeric',
			minute: '2-digit'
		}).format(new Date(value));
	}
</script>

<svelte:head>
	<title>Shared Library</title>
	<meta
		name="description"
		content="A private, offline-friendly reader for your Shared Library snapshots."
	/>
	<meta property="og:type" content="website" />
	<meta property="og:title" content="Shared Library" />
	<meta
		property="og:description"
		content="Read, search, and listen to your private Shared Library snapshot anywhere."
	/>
	<meta property="og:image" content="/og.png" />
	<meta name="twitter:card" content="summary_large_image" />
	<meta name="twitter:title" content="Shared Library" />
	<meta
		name="twitter:description"
		content="Read, search, and listen to your private Shared Library snapshot anywhere."
	/>
	<meta name="twitter:image" content="/og.png" />
</svelte:head>

<input
	bind:this={fileInput}
	class="sr-only"
	type="file"
	accept=".json,application/json"
	onchange={importSnapshot}
/>

<div class="app-shell">
	<header class="app-header">
		<div class="brand">
			<div class="brand-mark" aria-hidden="true"><LibraryBigIcon /></div>
			<div>
				<p class="brand-name">Shared Library</p>
				<p class="brand-subtitle">Private reader</p>
			</div>
		</div>

		<div class="header-status">
			{#if projection}
				<div class="snapshot-status">
					<span class="status-dot" aria-hidden="true"></span>
					<span>{isDemo ? 'Sample library' : 'Available offline'}</span>
					<span class="status-time">Updated {formatGeneratedAt(projection.generatedAt)}</span>
				</div>
			{/if}
			<Button
				variant={audioSettingsVisible ? 'secondary' : 'outline'}
				aria-label="Audio settings"
				onclick={toggleAudioSettings}
			>
				<HeadphonesIcon data-icon="inline-start" />
				<span class="desktop-label">Audio</span>
				{#if openRouterCredential}
					<span class="connection-dot" title="OpenRouter connected" aria-label="OpenRouter connected"
					></span>
				{/if}
			</Button>
			<Button variant="outline" onclick={() => fileInput?.click()}>
				<FileUpIcon data-icon="inline-start" />
				<span class="desktop-label">Import snapshot</span>
				<span class="mobile-label">Import</span>
			</Button>
		</div>
	</header>

	{#if loading}
		<main class="center-stage" aria-live="polite">
			<div class="loading-mark"><BookOpenIcon /></div>
			<p>Opening your offline library…</p>
		</main>
	{:else if !projection}
		<main class="center-stage">
			<div class="empty-card">
				<div class="empty-illustration">
					<CloudIcon />
					<span class="empty-check"><CheckIcon /></span>
				</div>
				<p class="eyebrow">Your library, on this device</p>
				<h1>Bring in your Shared Library snapshot</h1>
				<p class="empty-copy">
					In the Mac app, open Settings → Mobile and export the web snapshot to iCloud
					Drive. Then choose that JSON file here. It stays in this browser for offline
					reading.
				</p>
				<div class="empty-actions">
					<Button size="lg" onclick={() => fileInput?.click()}>
						<FileUpIcon data-icon="inline-start" />
						Choose snapshot
					</Button>
					<Button size="lg" variant="ghost" onclick={showDemo}>
						<BookOpenIcon data-icon="inline-start" />
						Explore a sample
					</Button>
				</div>
				<div class="privacy-note">
					<CheckIcon />
					<span>Your snapshot stays on this device. OpenRouter speech is optional.</span>
				</div>
				{#if importMessage}<p class="import-message error">{importMessage}</p>{/if}
			</div>
		</main>
	{:else}
		<div class="workspace" class:reader-open={mobileReaderVisible}>
			<aside class="library-pane">
				<div class="library-toolbar">
					<div class="search-field">
						<SearchIcon aria-hidden="true" />
						<Input bind:value={query} aria-label="Search library" placeholder="Search your library" />
					</div>

					<div class="filter-row" aria-label="Library filters">
						{#each ['all', 'personal', 'shared'] as filter}
							<button
								class:active={originFilter === filter}
								class="filter-chip"
								onclick={() => (originFilter = filter as OriginFilter)}
							>
								{filter === 'all' ? 'All' : filter === 'personal' ? 'Mine' : 'Shared with me'}
							</button>
						{/each}
					</div>

					<div class="topic-row">
						<NativeSelect.Root bind:value={topicFilter} class="w-full">
							<NativeSelect.Option value="all">All topics</NativeSelect.Option>
							{#each topics as topic}
								<NativeSelect.Option value={topic}>{topic}</NativeSelect.Option>
							{/each}
						</NativeSelect.Root>
						<span class="result-count">{filteredEntries.length} items</span>
					</div>
				</div>

				<div class="entry-list">
					{#if filteredEntries.length === 0}
						<div class="no-results">
							<ArchiveIcon />
							<p>No matching documents</p>
							<button
								onclick={() => {
									query = '';
									originFilter = 'all';
									topicFilter = 'all';
								}}>Clear filters</button
							>
						</div>
					{:else}
						{#each filteredEntries as entry (entry.id)}
							<button
								class="entry-row"
								class:selected={selectedEntry?.id === entry.id}
								onclick={() => selectEntry(entry)}
							>
								<div class="entry-topline">
									{#if entry.origin === 'shared'}
										<Badge variant="outline" class="shared-badge">Shared</Badge>
									{:else}
										<span class="personal-kicker">Personal</span>
									{/if}
									{#if entry.createdAt}<span>{formatDate(entry.createdAt)}</span>{/if}
								</div>
								<h2>{entry.title}</h2>
								<p>{entry.excerpt}</p>
								<div class="entry-footer">
									<span>{entry.topicNames[0] ?? 'Library'}</span>
									{#if entry.origin === 'shared' && entry.sharedByDisplayName}
										<span>From {entry.sharedByDisplayName}</span>
									{/if}
								</div>
							</button>
						{/each}
					{/if}
				</div>
			</aside>

			<main class="reader-pane">
				{#if selectedEntry}
					<div class="reader-inner">
						<div class="mobile-reader-bar">
							<Button
								variant="ghost"
								size="sm"
								onclick={() => (mobileReaderVisible = false)}
							>
								<ChevronLeftIcon data-icon="inline-start" />
								Library
							</Button>
						</div>

						<header class="document-header">
							<div class="document-kicker">
								{#if selectedEntry.origin === 'shared'}
									<Badge variant="outline" class="shared-badge">Shared with me</Badge>
									{#if selectedEntry.sharedByDisplayName}
										<span>From {selectedEntry.sharedByDisplayName}</span>
									{/if}
								{:else}
									<Badge variant="secondary">Personal library</Badge>
								{/if}
								{#if selectedEntry.createdAt}
									<span>{formatDate(selectedEntry.createdAt)}</span>
								{/if}
							</div>
							<h1>{selectedEntry.title}</h1>
							<p class="document-excerpt">{selectedEntry.excerpt}</p>
							<div class="topic-badges">
								{#each selectedEntry.topicNames as topic}
									<Badge variant="outline">{topic}</Badge>
								{/each}
								{#each selectedEntry.tags.slice(0, 3) as tag}
									<Badge variant="ghost">#{tag}</Badge>
								{/each}
							</div>
						</header>

						<div class="reading-controls">
							<div class="variant-tabs" role="tablist" aria-label="Document version">
								{#each availableVariants as variant}
									<button
										role="tab"
										aria-selected={selectedVariant === variant}
										class:active={selectedVariant === variant}
										onclick={() => (selectedVariant = variant)}
									>
										{variantNames[variant]}
									</button>
								{/each}
							</div>

							<div class="document-actions">
								<span class="reading-time">
									<Clock3Icon />
									{readingMinutes(selectedText, playbackRate)} min
								</span>
								<Button variant="outline" onclick={() => player.enqueue(selectedEntry as LibraryEntry)}>
									<PlusIcon data-icon="inline-start" />
									Queue
								</Button>
								<Button onclick={listen}>
									<Volume2Icon data-icon="inline-start" />
									Listen
								</Button>
							</div>
						</div>

						<Separator />

						<article class="document-body">
							{#if selectedText}
								<MarkdownText text={selectedText} />
							{:else}
								<p class="missing-text">This version is not available in the imported snapshot.</p>
							{/if}
						</article>

						{#if selectedEntry.sourceURL}
							<footer class="source-footer">
								<span>Original source</span>
								<a href={selectedEntry.sourceURL} target="_blank" rel="noreferrer">
									Open link <ArrowUpRightIcon />
								</a>
							</footer>
						{/if}
					</div>
				{/if}
			</main>
		</div>

		{#if toastMessage}
			<div
				class="toast"
				class:error={toastMessage.includes('failed') ||
					toastMessage.includes('could not') ||
					toastMessage.includes('unavailable')}
			>
				{toastMessage}
				<button aria-label="Dismiss message" onclick={dismissToast}><XIcon /></button>
			</div>
		{/if}
	{/if}

	{#if player.currentEntry || projection}
		<footer class="player-bar">
			<div class="now-playing">
				<div class="audio-mark"><Volume2Icon /></div>
				<div class="now-playing-copy">
					<span>
						{#if player.state === 'loading'}
							Generating with {currentVoiceName}
						{:else if player.provider === 'openrouter'}
							Grok voice · {currentVoiceName}
						{:else if player.provider === 'device'}
							Device voice
						{:else}
							Ready to listen
						{/if}
					</span>
					<strong>{player.currentEntry?.title ?? 'Choose a document'}</strong>
				</div>
			</div>

			<div class="transport">
				<Button
					variant="ghost"
					size="icon"
					aria-label="Stop"
					disabled={!player.currentEntry}
					onclick={() => player.stop()}
				>
					<SquareIcon />
				</Button>
				<Button
					size="icon-lg"
					class="play-button"
					aria-label={player.state === 'loading'
						? 'Cancel audio generation'
						: player.state === 'playing'
							? 'Pause'
							: 'Play'}
					disabled={!player.currentEntry}
					onclick={() => player.toggle()}
				>
					{#if player.state === 'loading'}
						<LoaderCircleIcon class="spin" />
					{:else if player.state === 'playing'}
						<PauseIcon />
					{:else}
						<PlayIcon />
					{/if}
				</Button>
				<Button
					variant="ghost"
					size="icon"
					aria-label="Play next"
					disabled={player.queue.length === 0}
					onclick={() => player.playNext()}
				>
					<SkipForwardIcon />
				</Button>
			</div>

			<div class="player-options">
				<div class="rate-control">
					<span>{playbackRate.toFixed(1)}×</span>
					<Slider
						type="single"
						value={playbackRate}
						min={0.7}
						max={1.5}
						step={0.1}
						aria-label="Speech rate"
						onValueCommit={updateRate}
					/>
				</div>
				<Button
					variant={queueVisible ? 'secondary' : 'ghost'}
					onclick={() => {
						queueVisible = !queueVisible;
						audioSettingsVisible = false;
					}}
				>
					<ListMusicIcon data-icon="inline-start" />
					Queue
					{#if player.queue.length}<span class="queue-count">{player.queue.length}</span>{/if}
				</Button>
			</div>
			<div class="player-progress" style={`--progress: ${player.progress * 100}%`}></div>
		</footer>
	{/if}

	{#if audioSettingsVisible}
		<div
			class="audio-backdrop"
			role="presentation"
			onclick={() => (audioSettingsVisible = false)}
		></div>
		<aside class="audio-panel" aria-label="Audio settings">
			<div class="audio-header">
				<div>
					<p class="eyebrow">Narration</p>
					<h2>Audio settings</h2>
				</div>
				<Button
					variant="ghost"
					size="icon"
					aria-label="Close audio settings"
					onclick={() => (audioSettingsVisible = false)}
				>
					<XIcon />
				</Button>
			</div>

			<div class="audio-content">
				<section class="audio-connection" class:connected={openRouterCredential}>
					<div class="audio-connection-heading">
						<div class="provider-mark"><HeadphonesIcon /></div>
						<div>
							<div class="provider-title">
								<h3>OpenRouter</h3>
								<Badge variant={openRouterCredential ? 'secondary' : 'outline'}>
									{openRouterCredential ? 'Connected' : 'Optional'}
								</Badge>
							</div>
							<p>Natural Grok narration, generated when you press Listen.</p>
						</div>
					</div>

					{#if player.requiresReconnect}
						<p class="reconnect-warning">
							Your OpenRouter connection needs to be renewed.
						</p>
					{/if}

					{#if openRouterCredential && !player.requiresReconnect}
						<Button
							variant="outline"
							disabled={openRouterBusy}
							onclick={removeOpenRouterConnection}
						>
							<LogOutIcon data-icon="inline-start" />
							Disconnect
						</Button>
					{:else}
						<Button disabled={openRouterBusy} onclick={connectOpenRouter}>
							<ArrowUpRightIcon data-icon="inline-start" />
							{openRouterBusy ? 'Opening OpenRouter…' : 'Connect OpenRouter'}
						</Button>
					{/if}
				</section>

				<section class="audio-section">
					<div class="audio-section-heading">
						<div>
							<h3>Narrator</h3>
							<p>Used for newly generated audio.</p>
						</div>
						<NativeSelect.Root
							value={openRouterVoice}
							disabled={!openRouterCredential}
							aria-label="OpenRouter narrator"
							onchange={updateVoice}
						>
							{#each openRouterVoices as voice}
								<NativeSelect.Option value={voice.id}>{voice.name}</NativeSelect.Option>
							{/each}
						</NativeSelect.Root>
					</div>
					{#if openRouterCredential}
						<p class="voice-description">
							{openRouterVoices.find((voice) => voice.id === openRouterVoice)?.description}
						</p>
					{/if}
				</section>

				<section class="audio-section audio-cache-section">
					<div>
						<h3>Offline audio</h3>
						<p>Generated speech is cached only in this browser for replay.</p>
					</div>
					<Button variant="ghost" size="sm" onclick={clearAudioCache}>
						<Trash2Icon data-icon="inline-start" />
						Clear cache
					</Button>
				</section>

				<div class="audio-privacy">
					<ShieldCheckIcon />
					<div>
						<strong>Your key is device-local</strong>
						<p>
							OpenRouter creates a connection for this browser. The key is never added to
							your snapshot or repository. Text is sent to OpenRouter and xAI only when
							you request narration.
						</p>
					</div>
				</div>

				<p class="device-fallback">
					Without a connection—or while offline—Shared Library uses the speech voice built
					into this device.
				</p>
			</div>
		</aside>
	{/if}

	{#if queueVisible}
		<div class="queue-backdrop" role="presentation" onclick={() => (queueVisible = false)}></div>
		<aside class="queue-panel" aria-label="Listening queue">
			<div class="queue-header">
				<div>
					<p class="eyebrow">Up next</p>
					<h2>Listening queue</h2>
				</div>
				<Button
					variant="ghost"
					size="icon"
					aria-label="Close queue"
					onclick={() => (queueVisible = false)}
				>
					<XIcon />
				</Button>
			</div>
			{#if player.queue.length === 0}
				<div class="queue-empty">
					<ListMusicIcon />
					<p>Your queue is empty.</p>
					<span>Add documents while browsing the library.</span>
				</div>
			{:else}
				<div class="queue-list">
					{#each player.queue as entry, index (entry.id)}
						<div class="queue-item">
							<span class="queue-index">{String(index + 1).padStart(2, '0')}</span>
							<div>
								<strong>{entry.title}</strong>
								<span>{entry.topicNames[0] ?? 'Library'}</span>
							</div>
							<Button
								variant="ghost"
								size="icon-sm"
								aria-label={`Remove ${entry.title}`}
								onclick={() => player.removeFromQueue(entry.id)}
							>
								<XIcon />
							</Button>
						</div>
					{/each}
				</div>
			{/if}
		</aside>
	{/if}
</div>
