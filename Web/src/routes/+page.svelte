<script lang="ts">
	import { onMount } from 'svelte';
	import ArrowUpRightIcon from '@lucide/svelte/icons/arrow-up-right';
	import BookOpenIcon from '@lucide/svelte/icons/book-open';
	import CheckIcon from '@lucide/svelte/icons/check';
	import ChevronLeftIcon from '@lucide/svelte/icons/chevron-left';
	import CloudIcon from '@lucide/svelte/icons/cloud';
	import CreditCardIcon from '@lucide/svelte/icons/credit-card';
	import FileTextIcon from '@lucide/svelte/icons/file-text';
	import LoaderCircleIcon from '@lucide/svelte/icons/loader-circle';
	import PaletteIcon from '@lucide/svelte/icons/palette';
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
		hasSameLibraryContent,
		libraryVariants,
		loadLibraryProjection,
		loadLibraryText,
		loadRawLibraryText,
		preferredVariant,
		textFor,
		type LibraryEntry,
		type LibraryProjection,
		type LibraryVariant
	} from '$lib/library.js';
	import {
		consumeGoogleDriveConnectionResult,
		loadGoogleDriveConnection,
		syncGoogleDriveLibrary,
		type GoogleDriveConnection
	} from '$lib/google-drive.js';
	import {
		emptyICloudLibraryMessage,
		fetchICloudLibraryFile,
		iCloudIdentity,
		syncICloudLibrary,
		type SyncProvider
	} from '$lib/icloud.js';
	import {
		loadShareLinkStatus,
		publishShareLink,
		revokeShareLink,
		type ShareLinkSource,
		type ShareLinkStatus
	} from '$lib/share-links.js';
	import {
		beginBrieflyPlusCheckout,
		consumeBillingResult,
		formatMonthlyPrice,
		loadBillingStatus,
		openBillingPortal,
		type BillingStatus
	} from '$lib/billing.js';
	import {
		readThemePreference,
		setThemePreference,
		themeModeOptions,
		themeOptions,
		type ThemeMode,
		type ThemeName
	} from '../../../Shared/themes';

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
	let themePreference = $state(readThemePreference());
	let googleSyncCompleted = $state(0);
	let googleSyncTotal = $state(0);
	let textRevision = $state(0);
	let loadingText = $state(false);
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
	let toastMessage = $derived(connectionMessage || importMessage);
	let currentBillingTier = $derived(
		billing?.tiers.find((tier) => tier.current) ?? billing?.tiers.at(-1) ?? null
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
		let active = true;
		let lastAutomaticSync = 0;
		let reloadingForServiceWorker = false;
		const activateLatestVersion = (): void => {
			if (reloadingForServiceWorker) return;
			reloadingForServiceWorker = true;
			window.location.reload();
		};
		navigator.serviceWorker?.addEventListener('controllerchange', activateLatestVersion);
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
			window.removeEventListener('online', automaticallySync);
			window.removeEventListener('focus', automaticallySync);
			document.removeEventListener('visibilitychange', automaticallySync);
			navigator.serviceWorker?.removeEventListener('controllerchange', activateLatestVersion);
		};
	});

	async function initializeConnections(isActive: () => boolean): Promise<void> {
		try {
			const googleResult = consumeGoogleDriveConnectionResult();
			const resultURL = new URL(window.location.href);
			const appleResult = resultURL.searchParams.get('apple');
			const iCloudResult = resultURL.searchParams.get('icloud');
			if (appleResult || iCloudResult) {
				resultURL.searchParams.delete('apple');
				resultURL.searchParams.delete('icloud');
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
			if (iCloudResult === 'connected') {
				connectionMessage = 'iCloud is authorized for this browser.';
			} else if (iCloudResult === 'empty') {
				connectionMessage = emptyICloudLibraryMessage;
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
		if (projection && hasSameLibraryContent(projection, nextProjection)) return;
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
		googleSyncCompleted = 0;
		googleSyncTotal = 0;
		try {
			const syncLibrary =
				syncProvider === 'icloud' ? syncICloudLibrary : syncGoogleDriveLibrary;
			const syncedProjection = await syncLibrary(
				(personalProjection) => {
					applySyncedProjection(personalProjection);
				},
				(completed, total) => {
					googleSyncCompleted = completed;
					googleSyncTotal = total;
				}
			);
			if (!syncedProjection) {
				connectionMessage = emptyICloudLibraryMessage;
				connectionsVisible = true;
				return;
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
			return `Saving ${googleSyncCompleted} of ${googleSyncTotal} files locally…`;
		}
		return `Checking ${syncProvider === 'icloud' ? 'iCloud' : 'Google Drive'}…`;
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

	function toggleConnections(): void {
		connectionsVisible = !connectionsVisible;
		sharingVisible = false;
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
		shareBusy = true;
		shareError = '';
		try {
			const captureID = target.captureID ?? target.id;
			const source =
				syncProvider === 'icloud' ? await shareSourceFromICloud(target) : undefined;
			const result = await publishShareLink(captureID, source);
			shareLink = result;
			if (result.url) {
				await navigator.clipboard.writeText(result.url);
				connectionMessage = 'Share link copied. The document is being prepared.';
			}
			void watchShareLink(captureID);
		} catch (error) {
			shareError =
				error instanceof Error ? error.message : 'The share link could not be created.';
		} finally {
			shareBusy = false;
		}
	}

	async function shareSourceFromICloud(target: LibraryEntry): Promise<ShareLinkSource> {
		const texts = await Promise.all(
			target.texts
				.filter(
					(reference): reference is typeof reference & { variant: LibraryVariant } =>
						libraryVariants.includes(reference.variant)
				)
				.map(async (reference) => ({
					variant: reference.variant,
					markdown: await loadRawLibraryText(reference, fetchICloudLibraryFile)
				}))
		);
		const filename =
			target.texts
				.find((reference) => reference.variant === 'source')
				?.path?.split('/')
				.at(-1) ?? `${target.captureID ?? target.id}.md`;
		return {
			filename,
			title: target.title,
			excerpt: target.excerpt,
			topicIDs: target.topicIDs,
			topicNames: target.topicNames,
			tags: target.tags,
			sourceURL: target.sourceURL,
			createdAt: target.createdAt,
			updatedAt: target.updatedAt,
			texts
		};
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

	function dismissToast(): void {
		importMessage = '';
		connectionMessage = '';
	}

	function updateTheme(theme?: ThemeName, mode?: ThemeMode): void {
		themePreference = {
			theme: theme ?? themePreference.theme,
			mode: mode ?? themePreference.mode
		};
		setThemePreference(themePreference);
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
		content="Read and search your private library anywhere."
	/>
	<meta property="og:image" content="https://www.readbriefly.fyi/og.png" />
	<meta name="twitter:card" content="summary_large_image" />
	<meta name="twitter:title" content="Briefly" />
	<meta
		name="twitter:description"
		content="Read and search your private library anywhere."
	/>
	<meta name="twitter:image" content="https://www.readbriefly.fyi/og.png" />
</svelte:head>

{#if publicShareToken}
	<PublicShareReader token={publicShareToken} />
{:else}
	<div class="app-shell bg-background! bg-none! text-foreground! font-sans!">

	{#if loading}
		<main class="center-stage text-foreground!" aria-live="polite">
			<div class="launch-sequence">
				<div class="loading-mark" aria-hidden="true">
					<span class="loading-halo"></span>
					<img src="/icons/icon-192.png" alt="" />
				</div>
				<p class="loading-title text-foreground!">Opening your library</p>
				<p class="loading-copy text-muted-foreground!">Preparing the offline collection</p>
				<div class="loading-dots [&_span]:bg-muted-foreground!" aria-hidden="true"><span></span><span></span><span></span></div>
			</div>
		</main>
	{:else if !projection}
		<main class="center-stage text-foreground!">
			<section class="empty-card border-border! bg-card! bg-none! text-card-foreground! rounded-xl! border shadow-sm!">
				<div class="empty-illustration bg-muted! bg-none! text-muted-foreground!">
					<CloudIcon />
					<span class="empty-check bg-primary! bg-none! text-primary-foreground!"><CheckIcon /></span>
				</div>
				<p class="eyebrow text-muted-foreground!">Briefly</p>
				{#if syncProvider && googleSyncing}
					<h1>Making your library available</h1>
					<p class="empty-copy text-muted-foreground!">{syncDescription()}</p>
				{:else if syncProvider && billing?.configured && !billing.entitled}
					<h1>Take your library everywhere</h1>
					<p class="empty-copy text-muted-foreground!">
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
				{:else if syncProvider === 'icloud' && !iCloudConnection.connected}
					<h1>Authorize iCloud on this browser</h1>
					<p class="empty-copy text-muted-foreground!">
						Each browser needs its own permission to read your private iCloud library.
					</p>
					<div class="empty-actions">
						<Button size="lg" href="/icloud?return_to=%2F">
							<CloudIcon data-icon="inline-start" />
							Authorize iCloud
						</Button>
						<Button size="lg" variant="ghost" onclick={showDemo}>
							<BookOpenIcon data-icon="inline-start" />
							Explore a sample
						</Button>
					</div>
				{:else if !account.authenticated}
					<h1>Sign in to Briefly</h1>
					<p class="empty-copy text-muted-foreground!">
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
					<p class="empty-copy text-muted-foreground!">
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
				<p class="empty-legal text-muted-foreground! [&_a]:text-primary!">
					By signing in or subscribing, you agree to the <a href="/terms">Terms</a>. See how
					Briefly handles data in the <a href="/privacy">Privacy Notice</a>. Provider details
					are in the <a href="/imprint">Imprint</a>.
				</p>
			</section>
		</main>
	{:else}
		<div class="native-workspace" class:reader-open={mobileReaderVisible}>
			<aside class="native-library-pane border-sidebar-border! bg-sidebar! bg-none! text-sidebar-foreground! rounded-xl! border shadow-sm!">
				<div class="native-library-toolbar">
					<div class="native-search-field">
						<SearchIcon class="text-muted-foreground!" aria-hidden="true" />
						<Input bind:value={query} aria-label="Search library" placeholder="Search" />
						{#if query}
							<button class="clear-search text-muted-foreground! hover:bg-accent! hover:text-accent-foreground!" aria-label="Clear search" onclick={() => (query = '')}>
								<XIcon />
							</button>
						{/if}
					</div>

					<div class="topic-strip" aria-label="Topic filter">
						<button
							class="topic-chip border-border! bg-secondary! bg-none! text-secondary-foreground! rounded-lg! border shadow-sm! hover:bg-secondary/80! [&.active]:border-primary! [&.active]:bg-primary! [&.active]:text-primary-foreground!"
							class:active={topicFilter === 'all' && originFilter === 'all'}
							onclick={() => {
								selectTopic('all');
								selectOrigin('all');
							}}>All</button
						>
						{#each topics as topic}
							<button
								class="topic-chip border-border! bg-secondary! bg-none! text-secondary-foreground! rounded-lg! border shadow-sm! hover:bg-secondary/80! [&.active]:border-primary! [&.active]:bg-primary! [&.active]:text-primary-foreground!"
								class:active={topicFilter === topic}
								onclick={() => selectTopic(topic)}>{topic}</button
							>
						{/each}
					</div>
				</div>

				<div class="native-entry-list">
					{#if filteredEntries.length === 0}
						<div class="native-no-results text-muted-foreground!">
							<FileTextIcon />
							<p>No matching documents</p>
							<button
								class="text-primary!"
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
								class="native-entry-row text-sidebar-foreground! rounded-lg! hover:bg-sidebar-accent/60! [&.selected]:bg-sidebar-accent! [&.selected]:text-sidebar-accent-foreground!"
								class:selected={selectedEntry?.id === entry.id}
								onclick={() => selectEntry(entry)}
							>
								<FileTextIcon class="text-sidebar-foreground/70!" aria-hidden="true" />
								<span>{entry.title}</span>
							</button>
						{/each}
					{/if}
				</div>

			</aside>

			<main class="native-reader-pane border-border! bg-card! bg-none! text-card-foreground! rounded-xl! border shadow-sm!">
				{#if selectedEntry}
					<div class="native-mobile-reader-bar border-border! bg-card! bg-none! text-card-foreground!">
						<button class="text-card-foreground! hover:bg-accent! hover:text-accent-foreground!" onclick={() => (mobileReaderVisible = false)}>
							<ChevronLeftIcon />
							<span>Library</span>
						</button>
					</div>

					<div class="native-document-scroll">
						<article class="native-document-body text-card-foreground! font-serif!" aria-busy={loadingText}>
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

					<footer class="native-document-footer border-border! bg-popover! bg-none! text-popover-foreground! rounded-xl! border shadow-sm!">
						<div class="footer-stat text-muted-foreground!">{selectedWordCount.toLocaleString()} words</div>

						<DepthControl
							variants={availableVariants}
							selected={selectedVariant}
							onselect={(variant) => (selectedVariant = variant)}
						/>

						<div class="native-footer-actions">
							{#if selectedEntry.sourceURL}
								<a
									class="native-icon-button border-border! bg-secondary! bg-none! text-secondary-foreground! rounded-lg! border shadow-sm! hover:bg-secondary/80!"
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
									class="native-icon-button border-border! bg-secondary! bg-none! text-secondary-foreground! rounded-lg! border shadow-sm! hover:bg-secondary/80! [&.active]:bg-accent! [&.active]:text-accent-foreground!"
									class:active={sharingVisible && shareTarget?.id === selectedEntry.id}
									aria-label="Share document"
									title="Create share link"
									onclick={() => openSharing()}
								>
									<Share2Icon />
								</button>
							{/if}

							<button
								class="native-icon-button border-border! bg-secondary! bg-none! text-secondary-foreground! rounded-lg! border shadow-sm! hover:bg-secondary/80! [&.active]:bg-accent! [&.active]:text-accent-foreground!"
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
				class="toast border-border! bg-popover! bg-none! text-popover-foreground! rounded-xl! border shadow-sm! [&.error]:border-destructive! [&.error]:bg-destructive/10! [&.error]:text-destructive!"
				class:error={toastMessage.includes('failed') ||
					toastMessage.includes('could not') ||
					toastMessage.includes('unavailable')}
				role="status"
				aria-live="polite"
			>
				{toastMessage}
				<button class="text-muted-foreground! hover:text-foreground!" aria-label="Dismiss message" onclick={dismissToast}><XIcon /></button>
			</div>
		{/if}
	{/if}

	{#if connectionsVisible}
		<div
			class="audio-backdrop bg-foreground/20! bg-none!"
			role="presentation"
			onclick={() => (connectionsVisible = false)}
		></div>
		<aside class="audio-panel connections-panel border-border! bg-popover! bg-none! text-popover-foreground! rounded-xl! border shadow-sm! font-sans!" aria-label="Connections">
			<div class="audio-header">
				<div>
					<p class="eyebrow text-muted-foreground!">Storage</p>
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
				<section class="audio-connection border-border! bg-card! bg-none! text-card-foreground! rounded-xl! border shadow-sm!">
					<div class="audio-connection-heading [&_p]:text-muted-foreground!">
						<div class="provider-mark bg-muted! bg-none! text-foreground! rounded-lg!"><PaletteIcon /></div>
						<div>
							<div class="provider-title"><h3>Appearance</h3></div>
							<p>Choose from Briefly and every built-in TweakCN theme.</p>
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
									updateTheme(
										undefined,
										(event.currentTarget as HTMLSelectElement).value as ThemeMode
									)}
							>
								{#each themeModeOptions as option}
									<option value={option.value}>{option.label}</option>
								{/each}
							</select>
						</label>
					</div>
				</section>

				<section class="audio-connection billing-connection border-border! bg-card! bg-none! text-card-foreground! rounded-xl! border shadow-sm!" class:connected={billing?.entitled}>
					<div class="audio-connection-heading [&_p]:text-muted-foreground!">
						<div class="provider-mark bg-muted! bg-none! text-foreground! rounded-lg!"><CreditCardIcon /></div>
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
					class="audio-connection border-border! bg-card! bg-none! text-card-foreground! rounded-xl! border shadow-sm!"
					class:connected={Boolean(syncProvider)}
				>
					<div class="audio-connection-heading [&_p]:text-muted-foreground!">
						<div class="provider-mark bg-muted! bg-none! text-foreground! rounded-lg!"><CloudIcon /></div>
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

				<section class="audio-connection connected border-border! bg-card! bg-none! text-card-foreground! rounded-xl! border shadow-sm!">
					<div class="audio-connection-heading [&_p]:text-muted-foreground!">
						<div class="provider-mark bg-muted! bg-none! text-foreground! rounded-lg!"><Share2Icon /></div>
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

				<div class="audio-privacy border-border! bg-muted! bg-none! text-foreground! rounded-xl! border [&>svg]:text-primary! [&_p]:text-muted-foreground!">
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
				<nav class="connections-legal [&_a]:text-muted-foreground! [&_a:hover]:text-primary!" aria-label="Legal">
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
			class="audio-backdrop bg-foreground/20! bg-none!"
			role="presentation"
			onclick={() => (sharingVisible = false)}
		></div>
		<aside class="audio-panel share-panel border-border! bg-popover! bg-none! text-popover-foreground! rounded-xl! border shadow-sm! font-sans!" aria-label="Share document">
			<div class="audio-header">
				<div>
					<p class="eyebrow text-muted-foreground!">Shareable reader</p>
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
				<div class="share-document border-border! bg-muted! bg-none! text-foreground! rounded-xl! border shadow-sm! [&>svg]:text-muted-foreground! [&_span]:text-muted-foreground!">
					<FileTextIcon />
					<div>
						<span>Document</span>
						<strong>{shareTarget.title}</strong>
					</div>
				</div>

				{#if shareError}
					<div class="share-sync-state error border-destructive/40! bg-destructive/10! bg-none! text-destructive!" role="alert">
						<TriangleAlertIcon />
						<div>
							<strong>Share link needs attention</strong>
							<span>{shareError}</span>
						</div>
					</div>
				{/if}

				{#if shareBusy && !shareLink.shared}
					<div class="share-loading text-muted-foreground!">
						<LoaderCircleIcon class="spin" />
						<span>Checking for an existing link…</span>
					</div>
				{:else if shareLink.shared && shareLink.url}
					<div class="share-link-card border-border! bg-card! bg-none! text-card-foreground! rounded-xl! border shadow-sm!">
						<div class="share-link-status [&>svg]:text-primary! [&_small]:text-muted-foreground!">
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
						<div class="share-link-value [&>span]:border-border! [&>span]:bg-background! [&>span]:bg-none! [&>span]:text-foreground!">
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
					<div class="share-empty text-muted-foreground!">
						<Share2Icon />
						<p>Publish this document as an unguessable, forwardable link.</p>
						<span>The reader includes every available summary level.</span>
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
