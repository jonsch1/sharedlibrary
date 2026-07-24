<script lang="ts">
	import { onMount } from 'svelte';
	import ArchiveIcon from '@lucide/svelte/icons/archive';
	import ArrowUpRightIcon from '@lucide/svelte/icons/arrow-up-right';
	import BookOpenIcon from '@lucide/svelte/icons/book-open';
	import CheckIcon from '@lucide/svelte/icons/check';
	import ChevronLeftIcon from '@lucide/svelte/icons/chevron-left';
	import CloudIcon from '@lucide/svelte/icons/cloud';
	import FileTextIcon from '@lucide/svelte/icons/file-text';
	import HeadphonesIcon from '@lucide/svelte/icons/headphones';
	import LoaderCircleIcon from '@lucide/svelte/icons/loader-circle';
	import LogOutIcon from '@lucide/svelte/icons/log-out';
	import PauseIcon from '@lucide/svelte/icons/pause';
	import PlayIcon from '@lucide/svelte/icons/play';
	import SearchIcon from '@lucide/svelte/icons/search';
	import Settings2Icon from '@lucide/svelte/icons/settings-2';
	import Share2Icon from '@lucide/svelte/icons/share-2';
	import ShieldCheckIcon from '@lucide/svelte/icons/shield-check';
	import TriangleAlertIcon from '@lucide/svelte/icons/triangle-alert';
	import XIcon from '@lucide/svelte/icons/x';
	import MarkdownText from '$lib/MarkdownText.svelte';
	import PublicShareReader from '$lib/PublicShareReader.svelte';
	import { Badge } from '$lib/components/ui/badge/index.js';
	import { Button } from '$lib/components/ui/button/index.js';
	import { Input } from '$lib/components/ui/input/index.js';
	import * as NativeSelect from '$lib/components/ui/native-select/index.js';
	import {
		demoProjection,
		libraryVariants,
		loadLibraryProjection,
		loadLibraryText,
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
		completeOpenRouterConnection,
		disconnectOpenRouter,
		loadOpenRouterCredential,
		loadVoicePreference,
		openRouterVoices,
		saveVoicePreference,
		synchronizeOpenRouterAudioCache,
		type OpenRouterCredential,
		type OpenRouterVoice
	} from '$lib/openrouter.js';
	import {
		beginGoogleDriveConnection,
		consumeGoogleDriveConnectionResult,
		disconnectGoogleDrive,
		loadGoogleDriveConnection,
		syncGoogleDriveLibrary,
		type GoogleDriveConnection
	} from '$lib/google-drive.js';
	import {
		loadShareLinkStatus,
		publishShareLink,
		revokeShareLink,
		type ShareLinkStatus
	} from '$lib/share-links.js';
	import { SpeechPlayer } from '$lib/speech-player.svelte.js';

	type GoogleSyncPhase = 'checking' | 'library' | 'audio';
	type OriginFilter = 'all' | 'personal';

	const variantNames: Record<LibraryVariant, string> = {
		brief: 'Brief',
		concise: 'Concise',
		detailed: 'Detailed',
		comprehensive: 'Comprehensive',
		source: 'Original'
	};

	let projection = $state<LibraryProjection | null>(null);
	let publicShareToken = $state('');
	let selectedEntryID = $state<string | null>(null);
	let selectedVariant = $state<LibraryVariant>('concise');
	let query = $state('');
	let topicFilter = $state('all');
	let originFilter = $state<OriginFilter>('all');
	let loading = $state(true);
	let importMessage = $state('');
	let isDemo = $state(false);
	let mobileReaderVisible = $state(false);
	let connectionsVisible = $state(false);
	let sharingVisible = $state(false);
	let shareTarget = $state<LibraryEntry | null>(null);
	let shareBusy = $state(false);
	let shareLink = $state<ShareLinkStatus>({ shared: false });
	let shareError = $state('');
	const sharingWatchTokens = new Map<string, string>();
	let narrationAudio = $state<HTMLAudioElement>();
	let playbackRate = $state(1);
	let openRouterCredential = $state<OpenRouterCredential | null>(null);
	let openRouterVoice = $state<OpenRouterVoice>('eve');
	let openRouterBusy = $state(false);
	let audioMessage = $state('');
	let connectionMessage = $state('');
	let googleConnection = $state<GoogleDriveConnection>({
		configured: false,
		connected: false
	});
	let googleBusy = $state(false);
	let googleSyncing = $state(false);
	let googleSyncPhase = $state<GoogleSyncPhase>('checking');
	let googleSyncCompleted = $state(0);
	let googleSyncTotal = $state(0);
	let textRevision = $state(0);
	let loadingText = $state(false);
	let installedAppleWebApp = $state(false);
	const player = new SpeechPlayer();
	const textLoads = new Map<string, Promise<string>>();

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
				entry.sharedByUsername ?? ''
			]
				.join(' ')
				.toLocaleLowerCase();
			return searchable.includes(normalizedQuery);
		})
	);
	let selectedText = $derived.by(() => {
		void textRevision;
		return selectedEntry ? (textFor(selectedEntry, selectedVariant)?.text ?? '') : '';
	});
	let availableVariants = $derived(
		selectedEntry
			? libraryVariants.filter((variant) => textFor(selectedEntry as LibraryEntry, variant))
			: []
	);
	let selectedVariantIndex = $derived(Math.max(0, availableVariants.indexOf(selectedVariant)));
	let selectedWordCount = $derived(
		selectedText.trim() ? selectedText.trim().split(/\s+/).length : 0
	);
	let currentVoiceName = $derived(
		openRouterVoices.find((voice) => voice.id === openRouterVoice)?.name ?? 'Eve'
	);
	let selectedAudioActive = $derived(
		player.currentEntry?.id === selectedEntry?.id &&
			player.currentVariant === selectedVariant
	);
	let toastMessage = $derived(audioMessage || player.notice || connectionMessage || importMessage);

	$effect(() => {
		if (selectedEntry && !textFor(selectedEntry, selectedVariant)) {
			selectedVariant = preferredVariant(selectedEntry);
		}
	});

	$effect(() => {
		if (topicFilter !== 'all' && !topics.includes(topicFilter)) {
			topicFilter = 'all';
		}
	});

	$effect(() => {
		const entry = selectedEntry;
		const variant = selectedVariant;
		if (entry) void ensureTextLoaded(entry, variant, true);
	});

	$effect(() => {
		const currentMessage = toastMessage;
		if (!currentMessage) return;
		const timeout = window.setTimeout(() => {
			if (toastMessage === currentMessage) dismissToast();
		}, 6_000);
		return () => window.clearTimeout(timeout);
	});

	onMount(() => {
		const sharedToken = new URL(window.location.href).searchParams.get('shared') ?? '';
		if (/^[A-Za-z0-9_-]{32}$/.test(sharedToken)) {
			publicShareToken = sharedToken;
			loading = false;
			return;
		}
		let active = true;
		let lastAutomaticSync = 0;
		let reloadingForServiceWorker = false;
		const activateLatestVersion = (): void => {
			if (reloadingForServiceWorker) return;
			reloadingForServiceWorker = true;
			window.location.reload();
		};
		navigator.serviceWorker?.addEventListener('controllerchange', activateLatestVersion);
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
			if (!navigator.onLine || Date.now() - lastAutomaticSync < 30_000) return;
			lastAutomaticSync = Date.now();
			void syncFromGoogleDrive(false);
		};
		const syncInterval = window.setInterval(automaticallySync, 5 * 60 * 1000);
		window.addEventListener('online', automaticallySync);
		window.addEventListener('focus', automaticallySync);
		document.addEventListener('visibilitychange', automaticallySync);
		return () => {
			active = false;
			window.clearInterval(syncInterval);
			window.removeEventListener('online', automaticallySync);
			window.removeEventListener('focus', automaticallySync);
			document.removeEventListener('visibilitychange', automaticallySync);
			navigator.serviceWorker?.removeEventListener('controllerchange', activateLatestVersion);
			player.dispose();
		};
	});

	async function initializeConnections(isActive: () => boolean): Promise<void> {
		try {
			const googleResult = consumeGoogleDriveConnectionResult();
			const google = await loadGoogleDriveConnection();
			if (!isActive()) return;
			googleConnection = google;
			if (googleResult === 'connected') {
				connectionMessage =
					'Google Drive connected. The complete library and existing narration are being saved on this device.';
				connectionsVisible = true;
			} else if (googleResult) {
				connectionMessage = 'Google Drive sign-in could not be completed. Check the callback URL.';
				connectionsVisible = true;
			}
			if (google.connected) {
				void requestPersistentOfflineStorage();
				await syncFromGoogleDrive(false);
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
				connectionsVisible = true;
			}
		} catch (error) {
			if (!isActive()) return;
			audioMessage =
				error instanceof Error ? error.message : 'OpenRouter sign-in could not be completed.';
			connectionsVisible = true;
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
		const savedTopic =
			typeof localStorage === 'undefined'
				? null
				: localStorage.getItem('shared-library-selected-topic');
		topicFilter =
			savedTopic && nextProjection.entries.some((entry) => entry.topicNames.includes(savedTopic))
				? savedTopic
				: 'all';
		mobileReaderVisible = false;
		openRequestedShare(nextProjection.entries);
	}

	function applySyncedProjection(nextProjection: LibraryProjection): void {
		const previousSelection = selectedEntryID;
		projection = nextProjection;
		isDemo = false;
		selectedEntryID =
			nextProjection.entries.some((entry) => entry.id === previousSelection)
				? previousSelection
				: (nextProjection.entries[0]?.id ?? null);
		openRequestedShare(nextProjection.entries);
	}

	function openRequestedShare(availableEntries: LibraryEntry[]): void {
		const url = new URL(window.location.href);
		const captureID = url.searchParams.get('publish');
		if (!captureID) return;
		const entry = availableEntries.find(
			(candidate) =>
				candidate.origin === 'personal' &&
				(candidate.captureID === captureID || candidate.id === captureID)
		);
		if (!entry) return;
		url.searchParams.delete('publish');
		window.history.replaceState({}, '', `${url.pathname}${url.search}${url.hash}`);
		selectedEntryID = entry.id;
		queueMicrotask(() => void openSharing(entry));
	}

	async function syncFromGoogleDrive(showError = true): Promise<void> {
		if (!googleConnection.connected || googleSyncing) return;
		googleSyncing = true;
		googleSyncPhase = 'checking';
		googleSyncCompleted = 0;
		googleSyncTotal = 0;
		try {
			const personalProjection = await syncGoogleDriveLibrary((completed, total) => {
				googleSyncPhase = 'library';
				googleSyncCompleted = completed;
				googleSyncTotal = total;
			});
			await saveLibraryProjection(personalProjection);
			applySyncedProjection(personalProjection);
			googleSyncPhase = 'audio';
			googleSyncCompleted = 0;
			googleSyncTotal = 0;
			await synchronizeOpenRouterAudioCache((completed, total) => {
				googleSyncCompleted = completed;
				googleSyncTotal = total;
			});
			connectionMessage = showError
				? `Everything is available offline and synchronized as of ${new Intl.DateTimeFormat(undefined, {
						hour: 'numeric',
						minute: '2-digit'
					}).format(new Date())}.`
				: '';
		} catch (error) {
			if (showError || !projection) {
				connectionMessage =
					error instanceof Error
						? error.message
						: 'The library could not be synced from Google Drive.';
			}
		} finally {
			googleSyncing = false;
			loading = false;
		}
	}

	async function requestPersistentOfflineStorage(): Promise<void> {
		try {
			await navigator.storage?.persist?.();
		} catch {
			// The offline mirror still works when the browser does not grant persistent storage.
		}
	}

	function googleSyncDescription(): string {
		if (!googleSyncing) return '';
		if (googleSyncTotal > 0) {
			const noun = googleSyncPhase === 'audio' ? 'audio files' : 'files';
			return `Saving ${googleSyncCompleted} of ${googleSyncTotal} ${noun} locally…`;
		}
		return googleSyncPhase === 'audio'
			? 'Checking offline audio…'
			: 'Checking Google Drive…';
	}

	function showDemo(): void {
		setProjection(demoProjection, true);
		importMessage = 'This is sample content. Connect Google Drive when you are ready.';
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
			connectionMessage = 'Google Drive disconnected. The downloaded library and audio remain on this device.';
		} catch (error) {
			connectionMessage =
				error instanceof Error ? error.message : 'Could not disconnect Google Drive.';
		} finally {
			googleBusy = false;
		}
	}

	function toggleConnections(): void {
		connectionsVisible = !connectionsVisible;
		sharingVisible = false;
	}

	async function openSharing(entry: LibraryEntry | null = selectedEntry): Promise<void> {
		if (!entry || entry.origin !== 'personal') return;
		shareTarget = entry;
		shareLink = { shared: false };
		shareError = '';
		shareBusy = true;
		sharingVisible = true;
		connectionsVisible = false;
		try {
			const status = await loadShareLinkStatus(entry.captureID ?? entry.id);
			if (shareTarget?.id !== entry.id) return;
			shareLink = status;
		} catch (error) {
			shareError =
				error instanceof Error ? error.message : 'The share link could not be loaded.';
		} finally {
			shareBusy = false;
		}
	}

	async function saveSharing(): Promise<void> {
		const target = shareTarget;
		if (!target) return;
		shareBusy = true;
		shareError = '';
		try {
			const captureID = target.captureID ?? target.id;
			const result = await publishShareLink(captureID, openRouterVoice);
			shareLink = result;
			if (result.url) {
				await navigator.clipboard.writeText(result.url);
				connectionMessage =
					'Share link copied. The document and existing narration are being prepared.';
			}
			void watchShareLink(captureID);
		} catch (error) {
			shareError =
				error instanceof Error ? error.message : 'The share link could not be created.';
		} finally {
			shareBusy = false;
		}
	}

	async function watchShareLink(captureID: string): Promise<void> {
		const token = crypto.randomUUID();
		sharingWatchTokens.set(captureID, token);
		const delays = [1_500, 2_500, 4_000, 6_000, 8_000];
		for (const delay of delays) {
			await new Promise((resolve) => window.setTimeout(resolve, delay));
			if (sharingWatchTokens.get(captureID) !== token) return;
			try {
				const status = await loadShareLinkStatus(captureID);
				if (sharingWatchTokens.get(captureID) !== token) return;
				shareLink = status;
				if (status.status === 'failed') {
					shareError = status.error ?? 'The share link could not be prepared.';
					return;
				}
				if (status.status === 'ready') {
					connectionMessage = 'Share link ready.';
					return;
				}
			} catch {
				// The link remains locally available; a later check can still complete it.
			}
		}
	}

	async function copyShareLink(): Promise<void> {
		if (!shareLink.url) return;
		await navigator.clipboard.writeText(shareLink.url);
		connectionMessage = 'Share link copied.';
	}

	async function stopSharing(): Promise<void> {
		if (!shareLink.token) return;
		shareBusy = true;
		shareError = '';
		try {
			await revokeShareLink(shareLink.token);
			shareLink = { shared: false };
			sharingVisible = false;
			connectionMessage = 'Share link revoked. Saved library copies remain.';
		} catch (error) {
			shareError =
				error instanceof Error ? error.message : 'The share link could not be revoked.';
		} finally {
			shareBusy = false;
		}
	}

	function selectEntry(entry: LibraryEntry): void {
		selectedEntryID = entry.id;
		selectedVariant = preferredVariant(entry);
		mobileReaderVisible = true;
	}

	function selectTopic(topic: string): void {
		topicFilter = topic;
		if (topic !== 'all') originFilter = 'all';
		if (typeof localStorage !== 'undefined') {
			localStorage.setItem('shared-library-selected-topic', topic);
		}
	}

	function selectOrigin(origin: OriginFilter): void {
		originFilter = origin;
		if (origin !== 'all') topicFilter = 'all';
	}

	function selectVariantFromSlider(event: Event): void {
		const index = Number((event.currentTarget as HTMLInputElement).value);
		const variant = availableVariants[index];
		if (variant) selectedVariant = variant;
	}

	async function ensureTextLoaded(
		entry: LibraryEntry,
		variant: LibraryVariant,
		showLoading = false
	): Promise<string> {
		const reference = textFor(entry, variant);
		if (!reference) return '';
		if (typeof reference.text === 'string') return reference.text;
		const key = `${reference.contentHash ?? ''}:${reference.path ?? ''}`;
		let pending = textLoads.get(key);
		if (!pending) {
			pending = loadLibraryText(reference);
			textLoads.set(key, pending);
		}
		if (showLoading) loadingText = true;
		try {
			const text = await pending;
			reference.text = text;
			textRevision += 1;
			return text;
		} catch (error) {
			connectionMessage =
				error instanceof Error ? error.message : 'The document could not be opened.';
			return '';
		} finally {
			textLoads.delete(key);
			if (showLoading) loadingText = false;
		}
	}

	async function listen(): Promise<void> {
		if (!selectedEntry) return;
		if (installedAppleWebApp) {
			audioMessage =
				'Apple currently blocks audio in installed iPhone web apps. Delete this Home Screen icon, reopen Shared Library in Safari, then add it again with “Open as Web App” turned off.';
			connectionsVisible = true;
			return;
		}
		if (selectedAudioActive && player.state !== 'idle') {
			player.toggle();
			return;
		}
		if (!(await ensureTextLoaded(selectedEntry, selectedVariant, true))) return;
		player.configureOpenRouter(openRouterCredential, openRouterVoice);
		player.play(selectedEntry, selectedVariant);
	}

	function updateRate(rate: number): void {
		playbackRate = rate;
		player.setRate(rate);
	}

	function cyclePlaybackRate(): void {
		const rates = [1, 1.2, 1.5, 0.8];
		const currentIndex = rates.findIndex((rate) => rate === playbackRate);
		updateRate(rates[(currentIndex + 1) % rates.length]);
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

	function dismissToast(): void {
		importMessage = '';
		audioMessage = '';
		connectionMessage = '';
		player.notice = '';
	}

</script>

<svelte:head>
	<title>Shared Library</title>
	<meta
		name="description"
		content="A private, offline-friendly reader synchronized through your Google Drive."
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

{#if publicShareToken}
	<PublicShareReader token={publicShareToken} />
{:else}
	<audio bind:this={narrationAudio} class="narration-engine" preload="none"></audio>

	<div class="app-shell">

	{#if loading}
		<main class="center-stage" aria-live="polite">
			<div class="loading-mark"><BookOpenIcon /></div>
			<p>Opening your offline library…</p>
		</main>
	{:else if !projection}
		<main class="center-stage">
			<section class="empty-card">
				<div class="empty-illustration">
					<CloudIcon />
					<span class="empty-check"><CheckIcon /></span>
				</div>
				<p class="eyebrow">Shared Library</p>
				{#if googleConnection.connected && googleSyncing}
					<h1>Making your library available</h1>
					<p class="empty-copy">{googleSyncDescription()}</p>
				{:else}
					<h1>Sign in with Google</h1>
					<p class="empty-copy">
						Configure one personal Drive location for the account, then mirror the complete
						local-first library on every client.
					</p>
					<div class="empty-actions">
						<Button size="lg" onclick={() => (connectionsVisible = true)}>
							<CloudIcon data-icon="inline-start" />
							Sign in with Google
						</Button>
						<Button size="lg" variant="ghost" onclick={showDemo}>
							<BookOpenIcon data-icon="inline-start" />
							Explore a sample
						</Button>
					</div>
				{/if}
			</section>
		</main>
	{:else}
		<div class="native-workspace" class:reader-open={mobileReaderVisible}>
			<aside class="native-library-pane">
				<div class="native-library-toolbar">
					<div class="native-search-field">
						<SearchIcon aria-hidden="true" />
						<Input bind:value={query} aria-label="Search library" placeholder="Search" />
						{#if query}
							<button class="clear-search" aria-label="Clear search" onclick={() => (query = '')}>
								<XIcon />
							</button>
						{/if}
					</div>

					<div class="topic-strip" aria-label="Topic filter">
						<button
							class="topic-chip"
							class:active={topicFilter === 'all' && originFilter === 'all'}
							onclick={() => {
								selectTopic('all');
								selectOrigin('all');
							}}>All</button
						>
						{#each topics as topic}
							<button
								class="topic-chip"
								class:active={topicFilter === topic}
								onclick={() => selectTopic(topic)}>{topic}</button
							>
						{/each}
					</div>
				</div>

				<div class="native-entry-list">
					{#if filteredEntries.length === 0}
						<div class="native-no-results">
							<FileTextIcon />
							<p>No matching documents</p>
							<button
								onclick={() => {
									query = '';
									selectTopic('all');
									selectOrigin('all');
								}}>Clear filters</button
							>
						</div>
					{:else}
						{#each filteredEntries as entry (entry.id)}
							<button
								class="native-entry-row"
								class:selected={selectedEntry?.id === entry.id}
								onclick={() => selectEntry(entry)}
							>
								<FileTextIcon aria-hidden="true" />
								<span>{entry.title}</span>
							</button>
						{/each}
					{/if}
				</div>

			</aside>

			<main class="native-reader-pane">
				{#if selectedEntry}
					<div class="native-mobile-reader-bar">
						<button onclick={() => (mobileReaderVisible = false)}>
							<ChevronLeftIcon />
							<span>Library</span>
						</button>
					</div>

					<div class="native-document-scroll">
						<article class="native-document-body">
							{#if selectedText}
								<MarkdownText text={selectedText} />
							{:else if loadingText}
								<p class="missing-text">Loading document from Google Drive…</p>
							{:else}
								<p class="missing-text">This version is not available.</p>
							{/if}
						</article>
					</div>

					<footer class="native-document-footer">
						<div
							class="native-player-progress"
							class:visible={selectedAudioActive}
							style={`--progress: ${player.progress * 100}%`}
						></div>

						<div class="footer-stat">{selectedWordCount.toLocaleString()} words</div>

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
								<a
									class="native-icon-button"
									href={selectedEntry.sourceURL}
									target="_blank"
									rel="noreferrer"
									aria-label="Open original source"
									title="Open original source"
								>
									<ArrowUpRightIcon />
								</a>
							{/if}

							{#if selectedEntry.origin === 'personal'}
								<button
									class="native-icon-button"
									class:active={sharingVisible && shareTarget?.id === selectedEntry.id}
									aria-label="Share document"
									title="Create share link"
									onclick={() => openSharing()}
								>
									<Share2Icon />
								</button>
							{/if}

							<button
								class="native-play-button"
								aria-label={player.state === 'loading' && selectedAudioActive
									? 'Cancel audio generation'
									: player.state === 'playing' && selectedAudioActive
										? 'Pause'
										: 'Play'}
								title={player.state === 'loading' && selectedAudioActive
									? 'Preparing audio'
									: player.state === 'playing' && selectedAudioActive
										? 'Pause'
										: 'Play'}
								onclick={listen}
							>
								{#if player.state === 'loading' && selectedAudioActive}
									<LoaderCircleIcon class="spin" />
								{:else if player.state === 'playing' && selectedAudioActive}
									<PauseIcon />
								{:else}
									<PlayIcon />
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
								class:active={connectionsVisible}
								aria-label="Connections"
								title="Connections"
								onclick={toggleConnections}
							>
								<Settings2Icon />
							</button>
						</div>
					</footer>
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
				<section class="audio-connection" class:connected={googleConnection.connected}>
					<div class="audio-connection-heading">
						<div class="provider-mark"><CloudIcon /></div>
						<div>
							<div class="provider-title">
								<h3>Google Drive</h3>
								<Badge variant={googleConnection.connected ? 'secondary' : 'outline'}>
									{googleConnection.connected ? 'Connected' : 'Required'}
								</Badge>
							</div>
							<p>Your complete Markdown library and generated audio, mirrored locally on every device.</p>
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
							{googleBusy ? 'Opening Google…' : 'Sign in with Google'}
						</Button>
						<p class="connection-help">
							{#if googleConnection.configured}
								Shared Library remembers one personal folder for this Google account.
								The narrow <code>drive.file</code> permission limits access to the
								library and audio files the app creates or you explicitly select.
							{:else}
								This deployment has not been configured with Google OAuth yet. The site
								administrator needs to add it once—users never paste a client secret.
							{/if}
						</p>
					{/if}
				</section>

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

				<section class="audio-connection connected">
					<div class="audio-connection-heading">
						<div class="provider-mark"><Share2Icon /></div>
						<div>
							<div class="provider-title">
								<h3>Share links</h3>
								<Badge variant="secondary">Built in</Badge>
							</div>
							<p>
								Publish individual documents as hard-to-guess, forwardable links. No
								shared Drive folder is required.
							</p>
						</div>
					</div>
				</section>

				<div class="audio-privacy">
					<ShieldCheckIcon />
					<div>
						<strong>Your Drive remains the source of truth</strong>
						<p>
							OAuth app credentials are configured once for the deployment. Your account
							tokens are encrypted per signed-in account. Your private library stays in
							your Drive; only documents you deliberately publish are copied to the
							sharing service until you stop sharing them.
						</p>
					</div>
				</div>
			</div>
		</aside>
	{/if}

	{#if sharingVisible && shareTarget}
		<div
			class="audio-backdrop"
			role="presentation"
			onclick={() => (sharingVisible = false)}
		></div>
		<aside class="audio-panel share-panel" aria-label="Share document">
			<div class="audio-header">
				<div>
					<p class="eyebrow">Shareable reader</p>
					<h2>Share link</h2>
				</div>
				<Button
					variant="ghost"
					size="icon"
					aria-label="Close sharing"
					onclick={() => (sharingVisible = false)}
				>
					<XIcon />
				</Button>
			</div>

			<div class="share-content">
				<div class="share-document">
					<FileTextIcon />
					<div>
						<span>Document</span>
						<strong>{shareTarget.title}</strong>
					</div>
				</div>

				{#if shareError}
					<div class="share-sync-state error" role="alert">
						<TriangleAlertIcon />
						<div>
							<strong>Share link needs attention</strong>
							<span>{shareError}</span>
						</div>
					</div>
				{/if}

				{#if shareBusy && !shareLink.shared}
					<div class="share-loading">
						<LoaderCircleIcon class="spin" />
						<span>Checking for an existing link…</span>
					</div>
				{:else if shareLink.shared && shareLink.url}
					<div class="share-link-card">
						<div class="share-link-status">
							{#if shareLink.status === 'ready'}
								<CheckIcon />
								<span>
									<strong>Ready to open</strong>
									<small>Anyone with this link can read and forward it.</small>
								</span>
							{:else if shareLink.status === 'failed'}
								<TriangleAlertIcon />
								<span>
									<strong>Preparation failed</strong>
									<small>{shareLink.error ?? 'Create the link again to retry.'}</small>
								</span>
							{:else}
								<LoaderCircleIcon class="spin" />
								<span>
									<strong>Preparing in the background</strong>
									<small>The link already works and will update automatically.</small>
								</span>
							{/if}
						</div>
						<div class="share-link-value">
							<span>{shareLink.url}</span>
							<Button variant="outline" onclick={copyShareLink}>Copy</Button>
						</div>
						{#if shareLink.status === 'ready'}
							<a href={shareLink.url} target="_blank" rel="noreferrer">
								Open reader <ArrowUpRightIcon />
							</a>
						{/if}
					</div>
				{:else}
					<div class="share-empty">
						<Share2Icon />
						<p>Publish this document as an unguessable, forwardable link.</p>
						<span>
							The reader includes every summary level and complete narration that has
							already been generated.
						</span>
					</div>
				{/if}
			</div>

			<div class="share-actions">
				<div class="share-link-actions">
					{#if shareLink.shared}
						<Button
							variant="outline"
							disabled={shareBusy}
							onclick={stopSharing}
						>
							Stop sharing
						</Button>
					{/if}
					<Button disabled={shareBusy} onclick={saveSharing}>
						{#if shareBusy}
							<LoaderCircleIcon class="spin" data-icon="inline-start" />
							Preparing…
						{:else}
							<Share2Icon data-icon="inline-start" />
							{shareLink.shared ? 'Update link' : 'Create share link'}
						{/if}
					</Button>
				</div>
				<p>
					Updating republishes the current snapshot. Revoking prevents future access;
					copies already saved to another library remain independent.
				</p>
			</div>
		</aside>
	{/if}

	</div>
{/if}
