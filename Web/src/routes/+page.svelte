<script lang="ts">
	import { onMount } from 'svelte';
	import ArrowUpRightIcon from '@lucide/svelte/icons/arrow-up-right';
	import BookOpenIcon from '@lucide/svelte/icons/book-open';
	import CheckIcon from '@lucide/svelte/icons/check';
	import ChevronLeftIcon from '@lucide/svelte/icons/chevron-left';
	import CloudIcon from '@lucide/svelte/icons/cloud';
	import CreditCardIcon from '@lucide/svelte/icons/credit-card';
	import FileTextIcon from '@lucide/svelte/icons/file-text';
	import HeadphonesIcon from '@lucide/svelte/icons/headphones';
	import LoaderCircleIcon from '@lucide/svelte/icons/loader-circle';
	import PauseIcon from '@lucide/svelte/icons/pause';
	import PlayIcon from '@lucide/svelte/icons/play';
	import SearchIcon from '@lucide/svelte/icons/search';
	import Settings2Icon from '@lucide/svelte/icons/settings-2';
	import Share2Icon from '@lucide/svelte/icons/share-2';
	import ShieldCheckIcon from '@lucide/svelte/icons/shield-check';
	import TriangleAlertIcon from '@lucide/svelte/icons/triangle-alert';
	import XIcon from '@lucide/svelte/icons/x';
	import MarkdownText from '$lib/MarkdownText.svelte';
	import DepthControl from '$lib/DepthControl.svelte';
	import PublicShareReader from '$lib/PublicShareReader.svelte';
	import { Badge } from '$lib/components/ui/badge/index.js';
	import { Button } from '$lib/components/ui/button/index.js';
	import { Input } from '$lib/components/ui/input/index.js';
	import {
		demoProjection,
		libraryVariants,
		loadLibraryProjection,
		loadLibraryText,
		preferredVariant,
		textFor,
		type LibraryEntry,
		type LibraryProjection,
		type LibraryVariant
	} from '$lib/library.js';
	import {
		beginManagedTTSTopUp,
		consumeManagedTTSResult,
		defaultOpenRouterModel,
		formatTTSMicros,
		loadManagedTTSStatus,
		loadOpenRouterPreferences,
		normalizeOpenRouterModel,
		normalizeOpenRouterVoice,
		openRouterTTSOptions,
		recommendedVoiceForModel,
		saveModelPreference,
		saveVoicePreference,
		setDurableAudioProvider,
		synchronizeOpenRouterAudioCache,
		voiceName,
		voicesForModel,
		type ManagedTTSStatus,
		type OpenRouterCredential,
		type OpenRouterTTSModel,
		type OpenRouterVoice
	} from '$lib/openrouter.js';
	import {
		consumeGoogleDriveConnectionResult,
		loadGoogleDriveConnection,
		syncGoogleDriveLibrary,
		type GoogleDriveConnection
	} from '$lib/google-drive.js';
	import {
		iCloudIdentity,
		syncICloudLibrary,
		type SyncProvider
	} from '$lib/icloud.js';
	import {
		loadShareLinkStatus,
		publishShareLink,
		revokeShareLink,
		type ShareLinkStatus
	} from '$lib/share-links.js';
	import { SpeechPlayer } from '$lib/speech-player.svelte.js';
	import {
		beginBrieflyPlusCheckout,
		consumeBillingResult,
		formatMonthlyPrice,
		loadBillingStatus,
		openBillingPortal,
		type BillingStatus
	} from '$lib/billing.js';

	type GoogleSyncPhase = 'checking' | 'library' | 'audio';
	type OriginFilter = 'all' | 'personal';
	type AccountStatus = {
		authenticated: boolean;
		email?: string;
		syncProvider?: SyncProvider | null;
		providers?: { google?: boolean; apple?: boolean };
		icloud?: { configured?: boolean; connected?: boolean };
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
	let managedTTS = $state<ManagedTTSStatus | null>(null);
	let openRouterVoice = $state<OpenRouterVoice>('af_heart');
	let openRouterModel = $state<OpenRouterTTSModel>(defaultOpenRouterModel);
	let managedTTSBusy = $state(false);
	let audioMessage = $state('');
	let connectionMessage = $state('');
	let googleConnection = $state<GoogleDriveConnection>({
		configured: false,
		connected: false
	});
	let account = $state<AccountStatus>({ authenticated: false });
	let syncProvider = $state<SyncProvider | null>(null);
	let iCloudConnection = $state({ configured: false, connected: false });
	let googleSyncing = $state(false);
	let billing = $state<BillingStatus | null>(null);
	let billingBusy = $state(false);
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
	let selectedWordCount = $derived(
		selectedText.trim() ? selectedText.trim().split(/\s+/).length : 0
	);
	let currentTTSOption = $derived(
		openRouterTTSOptions.find((option) => option.model === openRouterModel) ??
			openRouterTTSOptions[0]
	);
	let selectedAudioActive = $derived(
		player.currentEntry?.id === selectedEntry?.id &&
			player.currentVariant === selectedVariant
	);
	let selectedAudioLoadingLabel = $derived(
		player.loadingPhase === 'generating'
			? 'Generating voice'
			: player.loadingPhase === 'downloading'
				? 'Downloading audio'
				: 'Checking audio'
	);
	let toastMessage = $derived(audioMessage || player.notice || connectionMessage || importMessage);
	let currentBillingTier = $derived(
		billing?.tiers.find((tier) => tier.current) ?? billing?.tiers.at(-1) ?? null
	);
	let managedTTSAccess = $derived<OpenRouterCredential | null>(
		managedTTS?.configured && managedTTS.authenticated ? { connected: true } : null
	);

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
		const ttsResult = consumeManagedTTSResult();
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
		const narrationPreferences = loadOpenRouterPreferences();
		openRouterVoice = narrationPreferences.voice;
		openRouterModel = narrationPreferences.model;
		saveVoicePreference(openRouterVoice);
		saveModelPreference(openRouterModel);
		void initializeManagedTTS(() => active, ttsResult);
		const updateTTSBalance = (event: Event): void => {
			const balanceMicros = (event as CustomEvent<number>).detail;
			if (managedTTS && Number.isSafeInteger(balanceMicros) && balanceMicros >= 0) {
				managedTTS = { ...managedTTS, balanceMicros };
			}
		};
		window.addEventListener('briefly:tts-balance', updateTTSBalance);
		loadLibraryProjection()
			.then((saved) => {
				if (!active || !saved) return;
				setProjection(saved);
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
			void syncFromProvider(false);
		};
		const syncInterval = window.setInterval(automaticallySync, 30_000);
		window.addEventListener('online', automaticallySync);
		window.addEventListener('focus', automaticallySync);
		document.addEventListener('visibilitychange', automaticallySync);
		return () => {
			active = false;
			window.clearInterval(syncInterval);
			window.removeEventListener('briefly:tts-balance', updateTTSBalance);
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
			const resultURL = new URL(window.location.href);
			const appleResult = resultURL.searchParams.get('apple');
			if (appleResult) {
				resultURL.searchParams.delete('apple');
				window.history.replaceState(
					{},
					'',
					`${resultURL.pathname}${resultURL.search}${resultURL.hash}`
				);
			}
			const billingResult = consumeBillingResult();
			const checkoutURL = new URL(window.location.href);
			const continueCheckout = checkoutURL.searchParams.get('checkout') === 'plus';
			if (continueCheckout) {
				checkoutURL.searchParams.delete('checkout');
				window.history.replaceState(
					{},
					'',
					`${checkoutURL.pathname}${checkoutURL.search}${checkoutURL.hash}`
				);
			}
			const [accountResponse, google, initialBilling] = await Promise.all([
				fetch('/api/auth/status', { cache: 'no-store' }),
				loadGoogleDriveConnection(),
				loadBillingStatus()
			]);
			if (!isActive()) return;
			account = (await accountResponse.json()) as AccountStatus;
			googleConnection = google;
			billing = initialBilling;
			syncProvider = account.syncProvider ?? null;
			setDurableAudioProvider(syncProvider);
			iCloudConnection = {
				configured: account.icloud?.configured === true,
				connected:
					syncProvider === 'icloud' &&
					Boolean((await iCloudIdentity().catch(() => null))?.userRecordName)
			};
			if (continueCheckout && billing.authenticated) {
				await startBrieflyPlus();
				return;
			}
			if (billingResult === 'success') {
				for (let attempt = 0; attempt < 5 && billing.configured && !billing.entitled; attempt += 1) {
					await new Promise((resolve) => window.setTimeout(resolve, 800));
					if (!isActive()) return;
					billing = await loadBillingStatus();
				}
				connectionMessage = billing.entitled
					? 'Briefly Plus is active. Your joined price is locked while you stay subscribed.'
					: 'Payment completed. Briefly Plus is still being activated.';
				connectionsVisible = true;
			}
			if (googleResult === 'signed-in') {
				connectionMessage = 'Signed in. Choose iCloud or Google Drive for library sync.';
				connectionsVisible = true;
			} else if (googleResult) {
				connectionMessage = 'Google could not be connected. Check the callback URL.';
				connectionsVisible = true;
			}
			if (appleResult === 'signed-in') {
				connectionMessage = 'Signed in. Choose iCloud or Google Drive for library sync.';
				connectionsVisible = true;
			} else if (appleResult) {
				connectionMessage = 'Apple sign-in could not be completed.';
				connectionsVisible = true;
			}
			if (syncProvider && billing.entitled) {
				void requestPersistentOfflineStorage();
				await syncFromProvider(false);
			}
		} catch (error) {
			if (!isActive()) return;
			connectionMessage =
				error instanceof Error ? error.message : 'Connections could not be loaded.';
		}
	}

	async function initializeManagedTTS(
		isActive: () => boolean,
		result: string | null = null
	): Promise<void> {
		try {
			let status = await loadManagedTTSStatus();
			if (result === 'success') {
				for (let attempt = 0; attempt < 5 && status.balanceMicros === 0; attempt += 1) {
					await new Promise((resolve) => window.setTimeout(resolve, 800));
					if (!isActive()) return;
					status = await loadManagedTTSStatus();
				}
			}
			if (!isActive()) return;
			managedTTS = status;
			player.configureOpenRouter(
				status.configured && status.authenticated ? { connected: true } : null,
				openRouterVoice,
				openRouterModel
			);
			if (result === 'success') {
				audioMessage = `${formatTTSMicros(status.balanceMicros)} of AI voice credit is ready.`;
				connectionsVisible = true;
			} else if (result === 'cancelled') {
				audioMessage = 'The AI voice top-up was cancelled.';
				connectionsVisible = true;
			}
		} catch (error) {
			if (!isActive()) return;
			audioMessage =
				error instanceof Error ? error.message : 'The AI voice balance could not be loaded.';
			connectionsVisible = true;
		}
	}

	function setProjection(nextProjection: LibraryProjection): void {
		projection = nextProjection;
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

	async function syncFromProvider(showError = true): Promise<void> {
		if (
			!syncProvider ||
			googleSyncing ||
			(syncProvider === 'google' && !googleConnection.connected) ||
			(syncProvider === 'icloud' && !iCloudConnection.connected)
		) {
			return;
		}
		if (billing?.configured && !billing.entitled) {
			connectionMessage = 'Briefly Plus is required to synchronize your library.';
			connectionsVisible = true;
			return;
		}
		googleSyncing = true;
		googleSyncPhase = 'checking';
		googleSyncCompleted = 0;
		googleSyncTotal = 0;
		try {
			const syncLibrary =
				syncProvider === 'icloud' ? syncICloudLibrary : syncGoogleDriveLibrary;
			await syncLibrary(
				(personalProjection) => {
					applySyncedProjection(personalProjection);
					googleSyncPhase = 'library';
				},
				(completed, total) => {
					googleSyncCompleted = completed;
					googleSyncTotal = total;
				}
			);
			if (syncProvider === 'google') {
				googleSyncPhase = 'audio';
				googleSyncCompleted = 0;
				googleSyncTotal = 0;
				await synchronizeOpenRouterAudioCache((completed, total) => {
					googleSyncCompleted = completed;
					googleSyncTotal = total;
				});
			}
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
						: 'The library could not be synchronized.';
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

	function syncDescription(): string {
		if (!googleSyncing) return '';
		if (googleSyncTotal > 0) {
			const noun = googleSyncPhase === 'audio' ? 'audio files' : 'files';
			return `Saving ${googleSyncCompleted} of ${googleSyncTotal} ${noun} locally…`;
		}
		return googleSyncPhase === 'audio'
			? 'Checking offline audio…'
			: `Checking ${syncProvider === 'icloud' ? 'iCloud' : 'Google Drive'}…`;
	}

	function showDemo(): void {
		setProjection(demoProjection);
		importMessage = 'This is sample content. Choose a sync provider when you are ready.';
	}

	function signIn(provider: 'google' | 'apple'): void {
		window.location.assign(`/api/auth/${provider}/start`);
	}

	async function startBrieflyPlus(): Promise<void> {
		if (billingBusy) return;
		billingBusy = true;
		connectionMessage = '';
		try {
			await beginBrieflyPlusCheckout();
		} catch (error) {
			const checkoutError = error as Error & { code?: string };
			if (checkoutError.code === 'authentication_required') {
				connectionMessage = 'Sign in with Apple or Google before choosing Briefly Plus.';
				connectionsVisible = true;
				return;
			}
			connectionMessage = checkoutError.message;
		} finally {
			billingBusy = false;
		}
	}

	async function manageBilling(): Promise<void> {
		if (billingBusy) return;
		billingBusy = true;
		connectionMessage = '';
		try {
			await openBillingPortal();
		} catch (error) {
			connectionMessage =
				error instanceof Error ? error.message : 'The billing portal could not be opened.';
		} finally {
			billingBusy = false;
		}
	}

	async function toggleConnections(): Promise<void> {
		connectionsVisible = !connectionsVisible;
		sharingVisible = false;
		if (!connectionsVisible) return;
		try {
			managedTTS = await loadManagedTTSStatus();
		} catch (error) {
			audioMessage =
				error instanceof Error ? error.message : 'The AI voice balance could not be refreshed.';
		}
	}

	async function openSharing(entry: LibraryEntry | null = selectedEntry): Promise<void> {
		if (!entry || entry.origin !== 'personal') return;
		if (billing?.configured && !billing.entitled) {
			connectionMessage = 'Briefly Plus is required to create share links.';
			connectionsVisible = true;
			sharingVisible = false;
			return;
		}
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
		if (syncProvider === 'icloud') {
			shareError =
				'Creating new public links from iCloud libraries is not available yet. Existing links can still be managed here.';
			return;
		}
		shareBusy = true;
		shareError = '';
		try {
			const captureID = target.captureID ?? target.id;
			const result = await publishShareLink(captureID, openRouterVoice, openRouterModel);
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
				'Apple currently blocks audio in installed iPhone web apps. Delete this Home Screen icon, reopen Briefly in Safari, then add it again with “Open as Web App” turned off.';
			connectionsVisible = true;
			return;
		}
		if (selectedAudioActive && player.state !== 'idle') {
			player.toggle();
			return;
		}
		if (!(await ensureTextLoaded(selectedEntry, selectedVariant, true))) return;
		player.configureOpenRouter(managedTTSAccess, openRouterVoice, openRouterModel);
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

	async function topUpManagedTTS(amountCents: number): Promise<void> {
		if (managedTTSBusy) return;
		managedTTSBusy = true;
		audioMessage = '';
		try {
			await beginManagedTTSTopUp(amountCents);
		} catch (error) {
			audioMessage =
				error instanceof Error ? error.message : 'Could not open the AI voice top-up.';
			managedTTSBusy = false;
		}
	}

	function updateVoice(event: Event): void {
		const input = event.currentTarget as HTMLSelectElement;
		const selected = normalizeOpenRouterVoice(input.value);
		if (!selected || !voicesForModel(openRouterModel).includes(selected)) {
			input.value = openRouterVoice;
			audioMessage = 'Choose a voice supported by the selected quality.';
			return;
		}
		openRouterVoice = selected;
		input.value = selected;
		saveVoicePreference(selected);
		player.configureOpenRouter(managedTTSAccess, selected, openRouterModel);
		audioMessage = `${voiceName(selected)} selected.`;
	}

	function updateOpenRouterModel(event: Event): void {
		const input = event.currentTarget as HTMLSelectElement;
		const nextModel = normalizeOpenRouterModel(input.value);
		if (!nextModel) {
			input.value = openRouterModel;
			audioMessage = 'Choose Low, Medium, or High narration quality.';
			return;
		}
		const changed = nextModel !== openRouterModel;
		openRouterModel = nextModel;
		saveModelPreference(nextModel);
		const recommendedVoice = changed ? recommendedVoiceForModel(nextModel) : openRouterVoice;
		if (changed) {
			openRouterVoice = recommendedVoice;
			saveVoicePreference(recommendedVoice);
		}
		player.configureOpenRouter(managedTTSAccess, openRouterVoice, nextModel);
		const option = openRouterTTSOptions.find((candidate) => candidate.model === nextModel);
		audioMessage = `${option?.quality ?? 'Selected'} quality selected for new narration.`;
	}

	function dismissToast(): void {
		importMessage = '';
		audioMessage = '';
		connectionMessage = '';
		player.notice = '';
	}

</script>

<svelte:head>
	<title>Briefly</title>
	<meta
		name="description"
		content="A private, offline-friendly reader synchronized through your iCloud or Google Drive."
	/>
	<meta property="og:type" content="website" />
	<meta property="og:title" content="Briefly" />
	<meta
		property="og:description"
		content="Read, search, and listen to your private library anywhere."
	/>
	<meta property="og:image" content="https://www.readbriefly.fyi/og.png" />
	<meta name="twitter:card" content="summary_large_image" />
	<meta name="twitter:title" content="Briefly" />
	<meta
		name="twitter:description"
		content="Read, search, and listen to your private library anywhere."
	/>
	<meta name="twitter:image" content="https://www.readbriefly.fyi/og.png" />
</svelte:head>

{#if publicShareToken}
	<PublicShareReader token={publicShareToken} />
{:else}
	<audio bind:this={narrationAudio} class="narration-engine" preload="none"></audio>

	<div class="app-shell">

	{#if loading}
		<main class="center-stage" aria-live="polite">
			<div class="launch-sequence">
				<div class="loading-mark" aria-hidden="true">
					<span class="loading-halo"></span>
					<img src="/icons/icon-192.png" alt="" />
				</div>
				<p class="loading-title">Opening your library</p>
				<p class="loading-copy">Preparing the offline collection</p>
				<div class="loading-dots" aria-hidden="true"><span></span><span></span><span></span></div>
			</div>
		</main>
	{:else if !projection}
		<main class="center-stage">
			<section class="empty-card">
				<div class="empty-illustration">
					<CloudIcon />
					<span class="empty-check"><CheckIcon /></span>
				</div>
				<p class="eyebrow">Briefly</p>
				{#if syncProvider && googleSyncing}
					<h1>Making your library available</h1>
					<p class="empty-copy">{syncDescription()}</p>
				{:else if syncProvider && billing?.configured && !billing.entitled}
					<h1>Take your library everywhere</h1>
					<p class="empty-copy">
						Briefly Plus adds private cloud synchronization and deliberate share links.
						Your local desktop files remain on your device.
					</p>
					<div class="empty-actions">
						<Button size="lg" disabled={billingBusy} onclick={startBrieflyPlus}>
							<CreditCardIcon data-icon="inline-start" />
							{billingBusy
								? 'Opening checkout…'
								: currentBillingTier
									? `Get Plus · ${formatMonthlyPrice(currentBillingTier.amount)}/mo`
									: 'Get Briefly Plus'}
						</Button>
						<Button size="lg" variant="ghost" onclick={showDemo}>
							<BookOpenIcon data-icon="inline-start" />
							Explore a sample
						</Button>
					</div>
				{:else if !account.authenticated}
					<h1>Sign in to Briefly</h1>
					<p class="empty-copy">
						Your account keeps membership and sync settings together. Choose Apple or Google.
					</p>
					<div class="empty-actions">
						<Button
							size="lg"
							disabled={account.providers?.apple === false}
							onclick={() => signIn('apple')}
						>
							Sign in with Apple
						</Button>
						<Button
							size="lg"
							variant="outline"
							disabled={account.providers?.google === false}
							onclick={() => signIn('google')}
						>
							Sign in with Google
						</Button>
						<Button size="lg" variant="ghost" onclick={showDemo}>
							<BookOpenIcon data-icon="inline-start" />
							Explore a sample
						</Button>
					</div>
				{:else}
					<h1>Set up library sync</h1>
					<p class="empty-copy">
						Choose iCloud or Google Drive from your account page.
					</p>
					<div class="empty-actions">
						<Button size="lg" href="/account#sync">
							<CloudIcon data-icon="inline-start" />
							Open sync settings
						</Button>
						<Button size="lg" variant="ghost" onclick={showDemo}>
							<BookOpenIcon data-icon="inline-start" />
							Explore a sample
						</Button>
					</div>
				{/if}
				<p class="empty-legal">
					By signing in or subscribing, you agree to the <a href="/terms">Terms</a>. See how
					Briefly handles data in the <a href="/privacy">Privacy Notice</a>. Provider details
					are in the <a href="/imprint">Imprint</a>.
				</p>
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
						<article class="native-document-body" aria-busy={loadingText}>
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
								<MarkdownText text={selectedText} plain={selectedVariant === 'source'} />
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

						<DepthControl
							variants={availableVariants}
							selected={selectedVariant}
							onselect={(variant) => (selectedVariant = variant)}
						/>

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
								class:loading={player.state === 'loading' && selectedAudioActive}
								aria-label={player.state === 'loading' && selectedAudioActive
									? `Cancel ${selectedAudioLoadingLabel.toLowerCase()}`
									: player.state === 'playing' && selectedAudioActive
										? 'Pause'
										: 'Play'}
								title={player.state === 'loading' && selectedAudioActive
									? selectedAudioLoadingLabel
									: player.state === 'playing' && selectedAudioActive
										? 'Pause'
										: 'Play'}
								onclick={listen}
							>
								{#if player.state === 'loading' && selectedAudioActive}
									<span class="narration-loading-wave" aria-hidden="true">
										<span></span><span></span><span></span><span></span>
									</span>
									<span class="narration-loading-label">{selectedAudioLoadingLabel}</span>
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
				role="status"
				aria-live="polite"
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
				<section class="audio-connection billing-connection" class:connected={billing?.entitled}>
					<div class="audio-connection-heading">
						<div class="provider-mark"><CreditCardIcon /></div>
						<div>
							<div class="provider-title">
								<h3>Briefly Plus</h3>
								<Badge variant={billing?.entitled ? 'secondary' : 'outline'}>
									{billing?.entitled
										? billing.subscription?.cancelAtPeriodEnd
											? 'Cancels soon'
											: 'Active'
										: billing?.subscription
											? 'Inactive'
											: 'Optional'}
								</Badge>
							</div>
							<p>Cross-device library sync and deliberate share links.</p>
						</div>
					</div>

					{#if billing?.entitled && billing.subscription}
						<div class="billing-summary">
							<strong>
								{formatMonthlyPrice(
									billing.subscription.amount,
									billing.subscription.currency
								)}/month
							</strong>
							<span>{billing.subscription.tierName} price · kept while subscribed</span>
						</div>
						<Button variant="outline" disabled={billingBusy} onclick={manageBilling}>
							<ArrowUpRightIcon data-icon="inline-start" />
							{billingBusy ? 'Opening billing…' : 'Manage billing'}
						</Button>
					{:else if billing?.entitled}
						<p class="connection-help">Complimentary Plus access for this account.</p>
					{:else if billing?.configured}
						<Button disabled={billingBusy} onclick={startBrieflyPlus}>
							<CreditCardIcon data-icon="inline-start" />
							{billingBusy
								? 'Opening checkout…'
								: currentBillingTier
									? `Get Plus · ${formatMonthlyPrice(currentBillingTier.amount)}/mo`
									: 'Get Briefly Plus'}
						</Button>
						<p class="connection-help">
							The current launch price is locked while you remain subscribed. Cancel anytime.
						</p>
					{:else}
						<p class="connection-help">
							Stripe checkout is ready in the app but has not been configured for this deployment.
						</p>
					{/if}
					<Button variant="outline" onclick={() => window.location.assign('/account')}>
						<ArrowUpRightIcon data-icon="inline-start" />
						Account and app downloads
					</Button>
				</section>

				<section
					class="audio-connection"
					class:connected={Boolean(syncProvider)}
				>
					<div class="audio-connection-heading">
						<div class="provider-mark"><CloudIcon /></div>
						<div>
							<div class="provider-title">
								<h3>Library sync</h3>
								<Badge variant={syncProvider ? 'secondary' : 'outline'}>
									{syncProvider === 'icloud'
										? 'iCloud'
										: syncProvider === 'google'
											? 'Google Drive'
											: 'Not set'}
								</Badge>
							</div>
							<p>
								{syncProvider === 'icloud'
									? iCloudConnection.connected
										? 'This browser is authorized to synchronize your private CloudKit library.'
										: 'Authorize iCloud for this browser from your account page.'
									: syncProvider === 'google'
										? 'Your private library synchronizes through the connected Google Drive.'
										: 'Choose iCloud or Google Drive from your account page.'}
							</p>
						</div>
					</div>
					<Button href="/account#sync">
						<ArrowUpRightIcon data-icon="inline-start" />
						Manage sync
					</Button>
				</section>

				{#if installedAppleWebApp}
					<section class="ios-audio-warning">
						<TriangleAlertIcon />
						<div>
							<strong>Listening needs Safari on this iPhone</strong>
							<p>
								Apple has an audio bug in installed Home Screen web apps. Delete this
								icon, open Briefly in Safari, then add it again. If shown, turn
								off “Open as Web App.”
							</p>
						</div>
					</section>
				{/if}

				<section class="audio-connection" class:connected={managedTTS?.configured}>
					<div class="audio-connection-heading">
						<div class="provider-mark"><HeadphonesIcon /></div>
						<div>
							<div class="provider-title">
								<h3>Briefly AI voice</h3>
								<Badge variant={managedTTS?.configured ? 'secondary' : 'outline'}>
									{managedTTS?.configured ? 'Managed' : 'Unavailable'}
								</Badge>
							</div>
							<p>
								Your first paid month of Plus is matched in AI voice credit. Top up after that;
								device speech remains available without AI credit.
							</p>
						</div>
					</div>

					{#if managedTTS}
						<div class="billing-summary">
							<strong>{formatTTSMicros(managedTTS.balanceMicros)}</strong>
							<span>AI voice credit · successful generations only</span>
						</div>
						{#if managedTTS.checkoutConfigured && managedTTS.authenticated}
							<div class="tts-topups" aria-label="Top up AI voice credit">
								{#each managedTTS.topUpAmounts as amount}
									<Button
										variant="outline"
										disabled={managedTTSBusy}
										onclick={() => topUpManagedTTS(amount)}
									>
										Pay {formatMonthlyPrice(amount)}
									</Button>
								{/each}
							</div>
						{:else if managedTTS.configured}
							<p class="connection-help">
								{managedTTS.authenticated
									? 'Top-ups have not been configured for this deployment.'
									: 'Sign in to buy and use AI voice credit.'}
							</p>
						{/if}
						<p class="connection-help">
							Payment includes applicable VAT; the added credit excludes VAT. AI voice
							credit is non-refundable except where required by law.
						</p>
					{:else}
						<p class="connection-help">Loading AI voice credit…</p>
					{/if}
				</section>

				<section class="audio-section">
					<div class="audio-section-heading">
						<div>
							<h3>Narrator</h3>
							<p>Used for newly generated audio.</p>
						</div>
						<select
							class="audio-voice-input"
							value={openRouterVoice}
							disabled={!managedTTSAccess}
							aria-label="AI voice narrator"
							onchange={updateVoice}
						>
							{#each voicesForModel(openRouterModel) as voice}
								<option value={voice}>{voiceName(voice)}</option>
							{/each}
						</select>
					</div>
					<label class="audio-model-field">
						<span>Quality</span>
						<select
							value={openRouterModel}
							aria-label="Narration quality"
							onchange={updateOpenRouterModel}
						>
							{#each openRouterTTSOptions as option}
								<option value={option.model}>
									{option.quality} · {option.name} · ≈{option.hoursPerEuro}
									{option.hoursPerEuro === 1 ? 'hour' : 'hours'}/€
								</option>
							{/each}
						</select>
					</label>
					<p class="voice-description">
						{currentTTSOption.description} Audio starts as bytes arrive.
					</p>
					{#if managedTTS?.usage.length}
						<div class="tts-usage">
							<strong>Recent usage</strong>
							{#each managedTTS.usage.slice(0, 5) as entry}
								<span>
									{entry.characterCount.toLocaleString()} characters ·
									{formatTTSMicros(entry.amountMicros)}
								</span>
							{/each}
						</div>
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
							<strong>Your selected storage remains the source of truth</strong>
							<p>
								Your private library stays in iCloud or Google Drive. Google credentials
								are encrypted per signed-in account; iCloud content goes directly between
								this device and Apple. Only documents you deliberately publish are copied
								to the sharing service.
						</p>
					</div>
				</div>
				<nav class="connections-legal" aria-label="Legal">
					<a href="/feedback">Feedback</a>
					<a href="/privacy">Privacy</a>
					<a href="/terms">Terms</a>
					<a href="/cookies">Cookies & storage</a>
					<a href="/imprint">Imprint</a>
				</nav>
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
