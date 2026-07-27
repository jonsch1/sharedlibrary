<script lang="ts">
	import { onMount } from 'svelte';
	import BookmarkIcon from '@lucide/svelte/icons/bookmark';
	import BookOpenIcon from '@lucide/svelte/icons/book-open';
	import LoaderCircleIcon from '@lucide/svelte/icons/loader-circle';
	import PauseIcon from '@lucide/svelte/icons/pause';
	import PlayIcon from '@lucide/svelte/icons/play';
	import DepthControl from '$lib/DepthControl.svelte';
	import MarkdownText from '$lib/MarkdownText.svelte';
	import {
		importPublicShare,
		loadPublicShare,
		type PublicShareDocument
	} from '$lib/share-links.js';
	import { libraryVariants, type LibraryVariant } from '$lib/library.js';

	let { token }: { token: string } = $props();

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
			if (error instanceof Error && error.message.startsWith('Opening ')) return;
			errorMessage =
				error instanceof Error ? error.message : 'The document could not be added.';
		} finally {
			importBusy = false;
		}
	}
</script>

<svelte:head>
	<title>{document?.title ?? 'Shared document'} · Briefly</title>
	<meta
		name="description"
		content={document?.excerpt ?? 'A document shared with you through Briefly.'}
	/>
	<meta name="robots" content="noindex, nofollow, noarchive" />
	<meta name="referrer" content="no-referrer" />
</svelte:head>

<audio bind:this={audio} class="narration-engine" preload="none"></audio>

<div class="public-share-shell">
	<nav class="public-share-legal" aria-label="Legal">
		<a href="/privacy">Privacy</a>
		<a href="/terms">Terms</a>
		<a href="/imprint">Imprint</a>
	</nav>
	{#if loading || preparing}
		<main class="public-share-state" aria-live="polite">
			<LoaderCircleIcon class="spin" />
			<p>{preparing ? 'Preparing document…' : 'Opening document…'}</p>
		</main>
	{:else if errorMessage && !document}
		<main class="public-share-state error">
			<BookOpenIcon />
			<h1>Share link unavailable</h1>
			<p>{errorMessage}</p>
		</main>
	{:else if document}
		<main class="public-share-reader">
			<article class="public-share-body">
				<MarkdownText text={selectedText} plain={selectedVariant === 'source'} />
			</article>
		</main>

		<footer class="public-share-player" aria-label="Document controls">
			<DepthControl
				variants={availableVariants}
				selected={selectedVariant}
				onselect={selectVariant}
				presentation="showcase"
			/>

			<span class="public-share-divider" aria-hidden="true"></span>

			<button
				class="public-share-play"
				class:loading={audioState === 'loading'}
				aria-label={audioState === 'loading'
					? 'Loading narration'
					: audioState === 'playing'
						? 'Pause narration'
						: 'Play narration'}
				onclick={toggleAudio}
			>
				{#if audioState === 'loading'}
					<span class="public-share-loading-wave" aria-hidden="true">
						<span></span><span></span><span></span>
					</span>
				{:else if audioState === 'playing'}
					<PauseIcon />
				{:else}
					<PlayIcon />
				{/if}
			</button>

			<button
				class="public-share-add"
				class:saved
				disabled={importBusy || saved}
				aria-label={importBusy
					? 'Adding to Library'
					: saved
						? 'Added to Library'
						: 'Add to Library'}
				title={saved ? 'Added to Library' : 'Add to Library'}
				onclick={addToLibrary}
			>
				{#if importBusy}
					<LoaderCircleIcon class="spin" />
				{:else}
					<BookmarkIcon />
				{/if}
			</button>
		</footer>

		{#if errorMessage}
			<div class="public-share-toast" role="alert">{errorMessage}</div>
		{/if}
	{/if}
</div>
