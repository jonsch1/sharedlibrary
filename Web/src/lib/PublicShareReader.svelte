<script lang="ts">
	import { onMount } from 'svelte';
	import ArrowUpRightIcon from '@lucide/svelte/icons/arrow-up-right';
	import BookOpenIcon from '@lucide/svelte/icons/book-open';
	import CheckIcon from '@lucide/svelte/icons/check';
	import Clock3Icon from '@lucide/svelte/icons/clock-3';
	import LibraryBigIcon from '@lucide/svelte/icons/library-big';
	import LoaderCircleIcon from '@lucide/svelte/icons/loader-circle';
	import PauseIcon from '@lucide/svelte/icons/pause';
	import PlayIcon from '@lucide/svelte/icons/play';
	import PlusIcon from '@lucide/svelte/icons/plus';
	import Volume2Icon from '@lucide/svelte/icons/volume-2';
	import MarkdownText from '$lib/MarkdownText.svelte';
	import { Badge } from '$lib/components/ui/badge/index.js';
	import { Button } from '$lib/components/ui/button/index.js';
	import {
		importPublicShare,
		loadPublicShare,
		type PublicShareDocument
	} from '$lib/share-links.js';
	import { libraryVariants, type LibraryVariant } from '$lib/library.js';

	let { token }: { token: string } = $props();

	const variantNames: Record<LibraryVariant, string> = {
		brief: 'Brief',
		concise: 'Concise',
		detailed: 'Detailed',
		comprehensive: 'Comprehensive',
		source: 'Original'
	};

	let document = $state<PublicShareDocument | null>(null);
	let selectedVariant = $state<LibraryVariant>('concise');
	let loading = $state(true);
	let preparing = $state(false);
	let errorMessage = $state('');
	let importBusy = $state(false);
	let saved = $state(false);
	let audio = $state<HTMLAudioElement>();
	let audioState = $state<'idle' | 'loading' | 'playing' | 'paused'>('idle');
	let audioSegmentIndex = 0;

	let availableVariants = $derived(
		libraryVariants.filter((variant) =>
			document?.texts.some((text) => text.variant === variant)
		)
	);
	let selectedText = $derived(
		document?.texts.find((text) => text.variant === selectedVariant)?.markdown ?? ''
	);
	let selectedWordCount = $derived(
		document?.texts.find((text) => text.variant === selectedVariant)?.wordCount ?? 0
	);
	let selectedAudio = $derived(
		document?.audio
			.filter((segment) => segment.variant === selectedVariant)
			.sort((a, b) => a.index - b.index) ?? []
	);

	onMount(() => {
		let active = true;
		void refreshUntilReady(() => active);
		return () => {
			active = false;
			stopAudio();
			window.speechSynthesis?.cancel();
		};
	});

	async function refreshUntilReady(isActive: () => boolean): Promise<void> {
		for (let attempt = 0; attempt < 15; attempt += 1) {
			try {
				const result = await loadPublicShare(token);
				if (!isActive()) return;
				if (result.status === 'ready') {
					document = result;
					selectedVariant = result.texts.some((text) => text.variant === 'concise')
						? 'concise'
						: result.texts[0]?.variant ?? 'source';
					loading = false;
					preparing = false;
					if (new URL(window.location.href).searchParams.get('import') === '1') {
						void addToLibrary();
					}
					return;
				}
				if (result.status === 'failed') {
					throw new Error(result.error || 'This share link could not be prepared.');
				}
				preparing = true;
				loading = false;
			} catch (error) {
				if (!isActive()) return;
				errorMessage =
					error instanceof Error ? error.message : 'This share link is unavailable.';
				loading = false;
				preparing = false;
				return;
			}
			await new Promise((resolve) => window.setTimeout(resolve, 2_000));
		}
		if (isActive()) {
			errorMessage = 'This shared document is taking longer than expected. Reload to try again.';
			preparing = false;
		}
	}

	function selectVariant(variant: LibraryVariant): void {
		stopAudio();
		window.speechSynthesis?.cancel();
		selectedVariant = variant;
	}

	function toggleAudio(): void {
		if (audioState === 'playing') {
			if (selectedAudio.length > 0 && audio) {
				audio.pause();
			} else {
				speechSynthesis.pause();
			}
			audioState = 'paused';
			return;
		}
		if (audioState === 'paused') {
			if (selectedAudio.length > 0 && audio) {
				void audio.play().then(() => (audioState = 'playing'));
			} else {
				speechSynthesis.resume();
				audioState = 'playing';
			}
			return;
		}
		if (selectedAudio.length > 0) {
			audioSegmentIndex = 0;
			void playAudioSegment();
			return;
		}
		playDeviceSpeech();
	}

	async function playAudioSegment(): Promise<void> {
		const segment = selectedAudio[audioSegmentIndex];
		if (!segment || !audio) {
			audioState = 'idle';
			return;
		}
		audioState = 'loading';
		audio.src = segment.url;
		audio.onended = () => {
			audioSegmentIndex += 1;
			void playAudioSegment();
		};
		audio.onerror = () => {
			errorMessage = 'The shared narration could not be played.';
			audioState = 'idle';
		};
		try {
			await audio.play();
			audioState = 'playing';
		} catch {
			audioState = 'paused';
		}
	}

	function playDeviceSpeech(): void {
		if (!('speechSynthesis' in window)) {
			errorMessage = 'Speech playback is unavailable on this device.';
			return;
		}
		const cleanText = selectedText
			.replace(/```[\s\S]*?```/g, ' ')
			.replace(/[#*_~`>\[\]()!-]/g, ' ')
			.replace(/\s+/g, ' ')
			.trim();
		if (!cleanText) return;
		const utterance = new SpeechSynthesisUtterance(cleanText);
		utterance.onend = () => (audioState = 'idle');
		utterance.onerror = () => (audioState = 'idle');
		audioState = 'playing';
		speechSynthesis.cancel();
		speechSynthesis.speak(utterance);
	}

	function stopAudio(): void {
		if (audio) {
			audio.pause();
			audio.removeAttribute('src');
			audio.load();
		}
		audioState = 'idle';
		audioSegmentIndex = 0;
	}

	async function addToLibrary(): Promise<void> {
		if (importBusy || saved) return;
		importBusy = true;
		errorMessage = '';
		try {
			await importPublicShare(token);
			saved = true;
			const url = new URL(window.location.href);
			url.searchParams.delete('import');
			window.history.replaceState({}, '', `${url.pathname}${url.search}${url.hash}`);
		} catch (error) {
			errorMessage =
				error instanceof Error ? error.message : 'The document could not be added.';
		} finally {
			importBusy = false;
		}
	}
</script>

<svelte:head>
	<title>{document?.title ?? 'Shared document'} · Shared Library</title>
	<meta
		name="description"
		content={document?.excerpt ?? 'A document shared with you through Shared Library.'}
	/>
	<meta name="robots" content="noindex, nofollow, noarchive" />
	<meta name="referrer" content="no-referrer" />
</svelte:head>

<audio bind:this={audio} class="narration-engine" preload="none"></audio>

<div class="public-share-shell">
	<header class="public-share-header">
		<a class="public-share-brand" href="/" aria-label="Shared Library home">
			<span><LibraryBigIcon /></span>
			<strong>Shared Library</strong>
		</a>
		{#if document}
			<Button onclick={addToLibrary} disabled={importBusy || saved}>
				{#if importBusy}
					<LoaderCircleIcon class="spin" data-icon="inline-start" />
					Adding…
				{:else if saved}
					<CheckIcon data-icon="inline-start" />
					Added
				{:else}
					<PlusIcon data-icon="inline-start" />
					Add to my library
				{/if}
			</Button>
		{/if}
	</header>

	{#if loading || preparing}
		<main class="public-share-state" aria-live="polite">
			<LoaderCircleIcon class="spin" />
			<h1>{preparing ? 'Preparing your shared document' : 'Opening shared document'}</h1>
			<p>
				{preparing
					? 'The text and any existing narration are being published now.'
					: 'One moment…'}
			</p>
		</main>
	{:else if errorMessage && !document}
		<main class="public-share-state error">
			<BookOpenIcon />
			<h1>Share link unavailable</h1>
			<p>{errorMessage}</p>
		</main>
	{:else if document}
		<main class="public-share-reader">
			<header class="public-share-document-header">
				<div class="public-share-kicker">
					<Badge variant="secondary">Shared document</Badge>
					{#if document.createdAt}
						<span>{new Date(document.createdAt).toLocaleDateString()}</span>
					{/if}
				</div>
				<h1>{document.title}</h1>
				<p>{document.excerpt}</p>
				<div class="topic-badges">
					{#each document.topicNames as topic}
						<Badge variant="outline">{topic}</Badge>
					{/each}
					{#each document.tags.slice(0, 3) as tag}
						<Badge variant="ghost">#{tag}</Badge>
					{/each}
				</div>
			</header>

			<div class="public-share-controls">
				<div class="public-share-variants" role="tablist" aria-label="Document version">
					{#each availableVariants as variant}
						<button
							role="tab"
							aria-selected={selectedVariant === variant}
							class:active={selectedVariant === variant}
							onclick={() => selectVariant(variant)}
						>
							{variantNames[variant]}
						</button>
					{/each}
				</div>
				<div class="public-share-listen">
					<span><Clock3Icon /> {Math.max(1, Math.ceil(selectedWordCount / 180))} min</span>
					<Button onclick={toggleAudio}>
						{#if audioState === 'loading'}
							<LoaderCircleIcon class="spin" data-icon="inline-start" />
							Loading
						{:else if audioState === 'playing'}
							<PauseIcon data-icon="inline-start" />
							Pause
						{:else}
							<Volume2Icon data-icon="inline-start" />
							{selectedAudio.length > 0 ? 'Play narration' : 'Listen'}
						{/if}
					</Button>
				</div>
			</div>

			<article class="public-share-body">
				<MarkdownText text={selectedText} />
			</article>

			{#if document.sourceURL}
				<footer class="public-share-source">
					<span>Original source</span>
					<a href={document.sourceURL} target="_blank" rel="noreferrer">
						Open link <ArrowUpRightIcon />
					</a>
				</footer>
			{/if}
		</main>

		{#if errorMessage}
			<div class="public-share-toast" role="alert">{errorMessage}</div>
		{/if}

		{#if saved}
			<div class="public-share-saved">
				<div>
					<CheckIcon />
					<span>
						<strong>Saved to your library</strong>
						<small>The document, summaries, and available narration are syncing locally.</small>
					</span>
				</div>
				<Button variant="outline" onclick={() => window.location.assign('/')}>
					Open my library
				</Button>
			</div>
		{/if}
	{/if}
</div>
