<script lang="ts">
	import { onMount } from 'svelte';
	import ArchiveIcon from '@lucide/svelte/icons/archive';
	import ArrowUpRightIcon from '@lucide/svelte/icons/arrow-up-right';
	import BookOpenIcon from '@lucide/svelte/icons/book-open';
	import CheckIcon from '@lucide/svelte/icons/check';
	import ChevronLeftIcon from '@lucide/svelte/icons/chevron-left';
	import Clock3Icon from '@lucide/svelte/icons/clock-3';
	import CloudIcon from '@lucide/svelte/icons/cloud';
	import GitBranchIcon from '@lucide/svelte/icons/git-branch';
	import HeadphonesIcon from '@lucide/svelte/icons/headphones';
	import LibraryBigIcon from '@lucide/svelte/icons/library-big';
	import ListMusicIcon from '@lucide/svelte/icons/list-music';
	import LoaderCircleIcon from '@lucide/svelte/icons/loader-circle';
	import LogOutIcon from '@lucide/svelte/icons/log-out';
	import PauseIcon from '@lucide/svelte/icons/pause';
	import PlayIcon from '@lucide/svelte/icons/play';
	import PlusIcon from '@lucide/svelte/icons/plus';
	import SearchIcon from '@lucide/svelte/icons/search';
	import Settings2Icon from '@lucide/svelte/icons/settings-2';
	import ShieldCheckIcon from '@lucide/svelte/icons/shield-check';
	import SkipForwardIcon from '@lucide/svelte/icons/skip-forward';
	import SquareIcon from '@lucide/svelte/icons/square';
	import Trash2Icon from '@lucide/svelte/icons/trash-2';
	import TriangleAlertIcon from '@lucide/svelte/icons/triangle-alert';
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
		preferredVariant,
		readingMinutes,
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
	import {
		beginGitHubConnection,
		configureGitHubRepository,
		disconnectGitHub,
		loadGitHubConnection,
		loadGitHubRepositories,
		pollGitHubConnection,
		syncGitHubLibrary,
		type GitHubConnection,
		type GitHubDeviceAuthorization,
		type GitHubRepository
	} from '$lib/github.js';
	import {
		beginGoogleDriveConnection,
		consumeGoogleDriveConnectionResult,
		disconnectGoogleDrive,
		loadGoogleDriveConnection,
		type GoogleDriveConnection
	} from '$lib/google-drive.js';
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
	let connectionsVisible = $state(false);
	let narrationAudio = $state<HTMLAudioElement>();
	let playbackRate = $state(1);
	let openRouterCredential = $state<OpenRouterCredential | null>(null);
	let openRouterVoice = $state<OpenRouterVoice>('eve');
	let openRouterBusy = $state(false);
	let audioMessage = $state('');
	let connectionMessage = $state('');
	let githubConnection = $state<GitHubConnection>({ configured: false, connected: false });
	let githubRepository = $state('');
	let githubRepositories = $state<GitHubRepository[]>([]);
	let githubDevice = $state<GitHubDeviceAuthorization | null>(null);
	let githubBusy = $state(false);
	let githubSyncing = $state(false);
	let googleConnection = $state<GoogleDriveConnection>({
		configured: false,
		connected: false
	});
	let googleBusy = $state(false);
	let installedAppleWebApp = $state(false);
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
	let selectedAudioReady = $derived(
		player.currentEntry?.id === selectedEntry?.id &&
			player.currentVariant === selectedVariant &&
			player.provider === 'openrouter' &&
			player.state === 'paused'
	);
	let toastMessage = $derived(audioMessage || player.notice || connectionMessage || importMessage);

	$effect(() => {
		if (selectedEntry && !textFor(selectedEntry, selectedVariant)) {
			selectedVariant = preferredVariant(selectedEntry);
		}
	});

	onMount(() => {
		let active = true;
		let lastAutomaticSync = 0;
		if (narrationAudio) player.attachAudioElement(narrationAudio);
		const navigatorWithStandalone = navigator as Navigator & { standalone?: boolean };
		const isAppleMobile =
			/iPad|iPhone|iPod/.test(navigator.userAgent) ||
			(navigator.platform === 'MacIntel' && navigator.maxTouchPoints > 1);
		installedAppleWebApp =
			isAppleMobile &&
			(navigatorWithStandalone.standalone === true ||
				window.matchMedia('(display-mode: standalone)').matches);
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
				void initializeConnections(() => active);
			});
		const automaticallySync = (): void => {
			if (document.visibilityState !== 'visible' || Date.now() - lastAutomaticSync < 30_000) return;
			lastAutomaticSync = Date.now();
			void syncFromGitHub(false);
		};
		window.addEventListener('online', automaticallySync);
		window.addEventListener('focus', automaticallySync);
		document.addEventListener('visibilitychange', automaticallySync);
		return () => {
			active = false;
			window.removeEventListener('online', automaticallySync);
			window.removeEventListener('focus', automaticallySync);
			document.removeEventListener('visibilitychange', automaticallySync);
			player.dispose();
		};
	});

	async function initializeConnections(isActive: () => boolean): Promise<void> {
		try {
			const googleResult = consumeGoogleDriveConnectionResult();
			const [github, google] = await Promise.all([
				loadGitHubConnection(),
				loadGoogleDriveConnection()
			]);
			if (!isActive()) return;
			githubConnection = github;
			githubRepository = github.repository ?? '';
			googleConnection = google;
			if (googleResult === 'connected') {
				connectionMessage = 'Google Drive connected. New narration is backed up automatically.';
				connectionsVisible = true;
			} else if (googleResult) {
				connectionMessage = 'Google Drive sign-in could not be completed. Check the callback URL.';
				connectionsVisible = true;
			}
			if (github.connected) {
				await refreshGitHubRepositories(false);
				if (github.repository) await syncFromGitHub(false);
			}
		} catch (error) {
			if (!isActive()) return;
			connectionMessage =
				error instanceof Error ? error.message : 'Connections could not be loaded.';
		}
	}

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

	function applySyncedProjection(nextProjection: LibraryProjection): void {
		const previousSelection = selectedEntryID;
		projection = nextProjection;
		isDemo = false;
		selectedEntryID =
			nextProjection.entries.some((entry) => entry.id === previousSelection)
				? previousSelection
				: (nextProjection.entries[0]?.id ?? null);
	}

	async function syncFromGitHub(showError = true): Promise<void> {
		if (!githubConnection.connected || !githubConnection.repository || githubSyncing) return;
		githubSyncing = true;
		try {
			const nextProjection = await syncGitHubLibrary();
			applySyncedProjection(nextProjection);
			connectionMessage = showError
				? `Library updated from GitHub at ${new Intl.DateTimeFormat(undefined, {
						hour: 'numeric',
						minute: '2-digit'
					}).format(new Date())}.`
				: '';
		} catch (error) {
			if (showError || !projection) {
				connectionMessage =
					error instanceof Error ? error.message : 'The library could not be synced from GitHub.';
			}
		} finally {
			githubSyncing = false;
			loading = false;
		}
	}

	function showDemo(): void {
		setProjection(demoProjection, true);
		importMessage = 'This is sample content. Connect GitHub when you are ready.';
	}

	async function connectGitHubApp(): Promise<void> {
		githubBusy = true;
		connectionMessage = '';
		try {
			githubDevice = await beginGitHubConnection();
			connectionMessage = `Enter code ${githubDevice.userCode} on GitHub.`;
			void waitForGitHubAuthorization();
		} catch (error) {
			connectionMessage =
				error instanceof Error ? error.message : 'Could not start GitHub authorization.';
			githubBusy = false;
		}
	}

	async function waitForGitHubAuthorization(): Promise<void> {
		const expiresAt = Date.now() + (githubDevice?.expiresIn ?? 900) * 1000;
		let retryAfter = githubDevice?.interval ?? 5;
		while (githubDevice && Date.now() < expiresAt) {
			await new Promise((resolve) => window.setTimeout(resolve, retryAfter * 1000));
			try {
				const result = await pollGitHubConnection();
				if (result.state === 'pending') {
					retryAfter = result.retryAfter ?? retryAfter;
					continue;
				}
				if (result.state === 'connected') {
					githubDevice = null;
					githubConnection = await loadGitHubConnection();
					connectionMessage = `GitHub connected as ${result.login ?? githubConnection.login}.`;
					githubBusy = false;
					await refreshGitHubRepositories(true);
					return;
				}
				break;
			} catch (error) {
				connectionMessage =
					error instanceof Error ? error.message : 'GitHub authorization failed.';
				githubDevice = null;
				githubBusy = false;
				return;
			}
		}
		githubDevice = null;
		githubBusy = false;
		connectionMessage = 'GitHub authorization expired. Start it again.';
	}

	async function refreshGitHubRepositories(autoSelect: boolean): Promise<void> {
		try {
			const result = await loadGitHubRepositories();
			githubRepositories = result.repositories;
			if (!githubConnection.installURL && result.installURL) {
				githubConnection = { ...githubConnection, installURL: result.installURL };
			}
			if (
				autoSelect &&
				!githubConnection.repository &&
				result.repositories.length === 1
			) {
				githubRepository = result.repositories[0].fullName;
				await saveGitHubRepository();
			}
		} catch (error) {
			connectionMessage =
				error instanceof Error ? error.message : 'Could not read the installed repositories.';
		}
	}

	async function saveGitHubRepository(): Promise<void> {
		githubBusy = true;
		connectionMessage = '';
		try {
			const configured = await configureGitHubRepository(githubRepository.trim());
			githubConnection = { ...githubConnection, ...configured, connected: true };
			githubRepository = configured.repository ?? githubRepository.trim();
			await syncFromGitHub(true);
		} catch (error) {
			connectionMessage =
				error instanceof Error ? error.message : 'Could not open the GitHub repository.';
		} finally {
			githubBusy = false;
		}
	}

	async function removeGitHubConnection(): Promise<void> {
		githubBusy = true;
		try {
			await disconnectGitHub();
			githubConnection = {
				configured: githubConnection.configured,
				connected: false,
				installURL: githubConnection.installURL
			};
			githubDevice = null;
			githubRepository = '';
			githubRepositories = [];
			connectionMessage = 'GitHub disconnected. The downloaded library remains available offline.';
		} catch (error) {
			connectionMessage = error instanceof Error ? error.message : 'Could not disconnect GitHub.';
		} finally {
			githubBusy = false;
		}
	}

	async function connectGoogleDrive(): Promise<void> {
		googleBusy = true;
		connectionMessage = '';
		beginGoogleDriveConnection();
	}

	async function removeGoogleDriveConnection(): Promise<void> {
		googleBusy = true;
		try {
			await disconnectGoogleDrive();
			googleConnection = { configured: googleConnection.configured, connected: false };
			connectionMessage = 'Google Drive disconnected. Local audio remains on this device.';
		} catch (error) {
			connectionMessage =
				error instanceof Error ? error.message : 'Could not disconnect Google Drive.';
		} finally {
			googleBusy = false;
		}
	}

	function toggleConnections(): void {
		connectionsVisible = !connectionsVisible;
		audioSettingsVisible = false;
		queueVisible = false;
	}

	function selectEntry(entry: LibraryEntry): void {
		selectedEntryID = entry.id;
		selectedVariant = preferredVariant(entry);
		mobileReaderVisible = true;
	}

	function listen(): void {
		if (!selectedEntry) return;
		if (installedAppleWebApp) {
			audioMessage =
				'Apple currently blocks audio in installed iPhone web apps. Delete this Home Screen icon, reopen Shared Library in Safari, then add it again with “Open as Web App” turned off.';
			audioSettingsVisible = true;
			return;
		}
		if (selectedAudioReady) {
			player.toggle();
			return;
		}
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
		connectionsVisible = false;
		queueVisible = false;
	}

	function dismissToast(): void {
		importMessage = '';
		audioMessage = '';
		connectionMessage = '';
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
		content="A private, offline-friendly reader synced through GitHub with media backed up to Google Drive."
	/>
	<meta property="og:type" content="website" />
	<meta property="og:title" content="Shared Library" />
	<meta
		property="og:description"
		content="Read, search, and listen to your private library anywhere."
	/>
	<meta property="og:image" content="/og-v2.png" />
	<meta name="twitter:card" content="summary_large_image" />
	<meta name="twitter:title" content="Shared Library" />
	<meta
		name="twitter:description"
		content="Read, search, and listen to your private library anywhere."
	/>
	<meta name="twitter:image" content="/og-v2.png" />
</svelte:head>

<audio bind:this={narrationAudio} class="narration-engine" preload="none"></audio>

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
					<span class="status-time">
						{githubSyncing ? 'Fetching from GitHub…' : `Updated ${formatGeneratedAt(projection.generatedAt)}`}
					</span>
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
			<Button
				variant={connectionsVisible ? 'secondary' : 'outline'}
				onclick={toggleConnections}
			>
				<Settings2Icon data-icon="inline-start" />
				<span class="desktop-label">Connections</span>
				<span class="mobile-label">Setup</span>
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
				<p class="eyebrow">Your library, everywhere</p>
				<h1>Connect your personal GitHub repository</h1>
				<p class="empty-copy">
					Shared Library reads the private snapshot written by the Mac app and keeps a copy
					in this browser for offline reading. GitHub credentials never enter your library.
				</p>
				<div class="empty-actions">
					<Button size="lg" onclick={() => (connectionsVisible = true)}>
						<GitBranchIcon data-icon="inline-start" />
						Connect GitHub
					</Button>
					<Button size="lg" variant="ghost" onclick={showDemo}>
						<BookOpenIcon data-icon="inline-start" />
						Explore a sample
					</Button>
				</div>
				<div class="privacy-note">
					<CheckIcon />
					<span>GitHub syncs text. Google Drive stores optional generated media.</span>
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
									{selectedAudioReady ? 'Play' : 'Listen'}
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
							Preparing {currentVoiceName}
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
						connectionsVisible = false;
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

	{#if connectionsVisible}
		<div
			class="audio-backdrop"
			role="presentation"
			onclick={() => (connectionsVisible = false)}
		></div>
		<aside class="audio-panel connections-panel" aria-label="Connections">
			<div class="audio-header">
				<div>
					<p class="eyebrow">Storage</p>
					<h2>Connections</h2>
				</div>
				<Button
					variant="ghost"
					size="icon"
					aria-label="Close connections"
					onclick={() => (connectionsVisible = false)}
				>
					<XIcon />
				</Button>
			</div>

			<div class="audio-content">
				<section class="audio-connection" class:connected={githubConnection.connected}>
					<div class="audio-connection-heading">
						<div class="provider-mark"><GitBranchIcon /></div>
						<div>
							<div class="provider-title">
								<h3>GitHub App</h3>
								<Badge variant={githubConnection.connected ? 'secondary' : 'outline'}>
									{githubConnection.connected ? `@${githubConnection.login}` : 'Required'}
								</Badge>
							</div>
							<p>Private text sync through GitHub Device Flow—no CLI or PEM key.</p>
						</div>
					</div>

					{#if !githubConnection.connected}
						<Button
							disabled={githubBusy || !githubConnection.configured}
							onclick={connectGitHubApp}
						>
							<GitBranchIcon data-icon="inline-start" />
							{githubBusy ? 'Waiting for GitHub…' : 'Connect GitHub'}
						</Button>
						{#if githubDevice}
							<div class="device-code-card">
								<span>Your one-time code</span>
								<strong>{githubDevice.userCode}</strong>
								<a href={githubDevice.verificationURI} target="_blank" rel="noreferrer">
									Open GitHub to authorize <ArrowUpRightIcon />
								</a>
							</div>
						{/if}
						<p class="connection-help">
							{#if githubConnection.configured}
								Create a private repository on GitHub first. Shared Library manages the app
								credentials; when installing it, grant access only to that repository.
							{:else}
								This deployment has not been configured with the Shared Library GitHub App.
								The site administrator needs to add it once—users never paste credentials.
							{/if}
						</p>
					{:else}
						<label class="connection-field">
							<span>Personal repository</span>
							<NativeSelect.Root bind:value={githubRepository} class="w-full">
								<NativeSelect.Option value="">Choose an installed repository</NativeSelect.Option>
								{#each githubRepositories as repository (repository.id)}
									<NativeSelect.Option value={repository.fullName}>
										{repository.fullName}{repository.private ? ' · Private' : ''}
									</NativeSelect.Option>
								{/each}
							</NativeSelect.Root>
						</label>
						<div class="connection-actions">
							<Button
								disabled={githubBusy || !githubRepository.trim()}
								onclick={saveGitHubRepository}
							>
								{githubBusy ? 'Checking…' : 'Use repository'}
							</Button>
							<Button
								variant="outline"
								disabled={githubBusy}
								onclick={() => refreshGitHubRepositories(false)}
							>
								Refresh list
							</Button>
							<Button variant="outline" disabled={githubBusy} onclick={removeGitHubConnection}>
								<LogOutIcon data-icon="inline-start" />
								Disconnect
							</Button>
						</div>
						{#if githubConnection.installURL}
							<p class="connection-help">
								Missing a repository?
								<a href="https://github.com/new" target="_blank" rel="noreferrer">
									Create it on GitHub <ArrowUpRightIcon />
								</a>
								first, then
								<a href={githubConnection.installURL} target="_blank" rel="noreferrer">
									Choose repository access on GitHub <ArrowUpRightIcon />
								</a>
								, then refresh the list.
							</p>
						{/if}
						{#if githubConnection.repository}
							<p class="connection-detail">
								Automatically fetches <code>.shared-library/library.json</code> when the
								app opens or returns online.
							</p>
						{/if}
					{/if}
				</section>

				<section class="audio-connection" class:connected={googleConnection.connected}>
					<div class="audio-connection-heading">
						<div class="provider-mark"><CloudIcon /></div>
						<div>
							<div class="provider-title">
								<h3>Google Drive</h3>
								<Badge variant={googleConnection.connected ? 'secondary' : 'outline'}>
									{googleConnection.connected ? 'Connected' : 'Media backup'}
								</Badge>
							</div>
							<p>Durable generated audio in your own Drive, with a fast cache on each device.</p>
						</div>
					</div>

					{#if googleConnection.connected}
						<Button variant="outline" disabled={googleBusy} onclick={removeGoogleDriveConnection}>
							<LogOutIcon data-icon="inline-start" />
							Disconnect
						</Button>
					{:else}
						<Button
							disabled={googleBusy || !googleConnection.configured}
							onclick={connectGoogleDrive}
						>
							<CloudIcon data-icon="inline-start" />
							{googleBusy ? 'Opening Google…' : 'Connect your Google Drive'}
						</Button>
						<p class="connection-help">
							{#if googleConnection.configured}
								You sign in to your own Google account. Shared Library uses the narrow
								<code>drive.file</code> permission, so it can access only media it creates
								for you—not the rest of your Drive.
							{:else}
								This deployment has not been configured with Google OAuth yet. The site
								administrator needs to add it once—users never paste a client secret.
							{/if}
						</p>
					{/if}
				</section>

				<div class="audio-privacy">
					<ShieldCheckIcon />
					<div>
						<strong>Credentials stay outside the repository</strong>
						<p>
							OAuth app credentials are configured once for the deployment. Your
							account tokens are encrypted per signed-in account. Only library text is
							stored in GitHub; generated audio is content-addressed in your Drive.
						</p>
					</div>
				</div>
			</div>
		</aside>
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
				{#if installedAppleWebApp}
					<section class="ios-audio-warning">
						<TriangleAlertIcon />
						<div>
							<strong>Listening needs Safari on this iPhone</strong>
							<p>
								Apple has an audio bug in installed Home Screen web apps. Delete this
								icon, open Shared Library in Safari, then add it again. If shown, turn
								off “Open as Web App.”
							</p>
						</div>
					</section>
				{/if}
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
						<p>
							Generated segments are cached here and backed up to Google Drive when
							connected.
						</p>
					</div>
					<Button variant="ghost" size="sm" onclick={clearAudioCache}>
						<Trash2Icon data-icon="inline-start" />
						Clear cache
					</Button>
				</section>

				<div class="audio-privacy">
						<ShieldCheckIcon />
					<div>
						<strong>Your key stays encrypted</strong>
						<p>
							OpenRouter creates a user-controlled key that Shared Library stores
							encrypted for your private account. It is never added to your snapshot,
							Google Drive, or repository. Text is sent to OpenRouter and xAI only when
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
