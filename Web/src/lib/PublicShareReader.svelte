<script lang="ts">
	import { onMount } from 'svelte';
	import BookmarkIcon from '@lucide/svelte/icons/bookmark';
	import BookOpenIcon from '@lucide/svelte/icons/book-open';
	import LoaderCircleIcon from '@lucide/svelte/icons/loader-circle';
	import DepthControl from '../../../Shared/DepthControl.svelte';
	import MarkdownText from '../../../Shared/MarkdownView.svelte';
	import {
		importPublicShare,
		loadPublicShare,
		type PublicShareDocument
	} from '$lib/share-links.js';
	import {
		libraryVariants,
		shouldRenderSourceAsPlainText,
		type LibraryVariant
	} from '$lib/library.js';

	let { token }: { token: string } = $props();

	let document = $state<PublicShareDocument | null>(null);
	let selectedVariant = $state<LibraryVariant>('concise');
	let loading = $state(true);
	let preparing = $state(false);
	let errorMessage = $state('');
	let importBusy = $state(false);
	let saved = $state(false);

	let availableVariants = $derived(
		libraryVariants.filter((variant) =>
			document?.texts.some((text) => text.variant === variant)
		)
	);
	let selectedText = $derived(
		document?.texts.find((text) => text.variant === selectedVariant)?.markdown ?? ''
	);
	onMount(() => {
		let active = true;
		void refreshUntilReady(() => active);
		return () => {
			active = false;
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
		selectedVariant = variant;
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

<div class="public-share-shell bg-background! bg-none! text-foreground! font-sans!">
	<nav class="public-share-legal [&_a]:text-muted-foreground! [&_a:hover]:text-primary!" aria-label="Legal">
		<a href="/privacy">Privacy</a>
		<a href="/terms">Terms</a>
		<a href="/imprint">Imprint</a>
	</nav>
	{#if loading || preparing}
		<main class="public-share-state text-muted-foreground!" aria-live="polite">
			<LoaderCircleIcon class="spin" />
			<p>{preparing ? 'Preparing document…' : 'Opening document…'}</p>
		</main>
	{:else if errorMessage && !document}
		<main class="public-share-state error text-destructive!">
			<BookOpenIcon />
			<h1>Share link unavailable</h1>
			<p>{errorMessage}</p>
		</main>
	{:else if document}
		<main class="public-share-reader">
			<article class="public-share-body text-foreground! font-serif!">
				<MarkdownText
					text={selectedText}
					plain={shouldRenderSourceAsPlainText(selectedVariant, document.sourceURL)}
				/>
			</article>
		</main>

		<footer class="public-share-player border-border! bg-popover! bg-none! text-popover-foreground! rounded-xl! border shadow-sm!" aria-label="Document controls">
			<DepthControl
				variants={availableVariants}
				selected={selectedVariant}
				onselect={selectVariant}
				presentation="showcase"
			/>

			<button
				class="public-share-add border-border! bg-secondary! bg-none! text-secondary-foreground! rounded-lg! border shadow-sm! hover:bg-secondary/80! [&.saved]:bg-accent! [&.saved]:text-accent-foreground!"
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
			<div class="public-share-toast border-destructive! bg-destructive/10! bg-none! text-destructive! rounded-xl! border shadow-sm!" role="alert">{errorMessage}</div>
		{/if}
	{/if}
</div>
