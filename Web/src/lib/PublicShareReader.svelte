<script lang="ts">
	import { onMount } from 'svelte';
	import ArrowUpRightIcon from '@lucide/svelte/icons/arrow-up-right';
	import BookOpenIcon from '@lucide/svelte/icons/book-open';
	import FlagIcon from '@lucide/svelte/icons/flag';
	import LoaderCircleIcon from '@lucide/svelte/icons/loader-circle';
	import PauseIcon from '@lucide/svelte/icons/pause';
	import PlayIcon from '@lucide/svelte/icons/play';
	import DepthControl from '../../../Shared/DepthControl.svelte';
	import MarkdownText from '../../../Shared/MarkdownView.svelte';
	import {
		loadPublicShare,
		submitContentReport,
		type ContentReportCategory,
		type PublicShareDocument
	} from '$lib/share-links.js';
	import { readingDepths, type LibraryVariant } from '$lib/library.js';

	let { token }: { token: string } = $props();

	let document = $state<PublicShareDocument | null>(null);
	let selectedVariant = $state<LibraryVariant>('concise');
	let loading = $state(true);
	let preparing = $state(false);
	let errorMessage = $state('');
	let reportDialog = $state<HTMLDialogElement>();
	let reportCategory = $state<ContentReportCategory>('copyright');
	let reporterName = $state('');
	let reporterEmail = $state('');
	let workDescription = $state('');
	let reportExplanation = $state('');
	let reportGoodFaith = $state(false);
	let reportBusy = $state(false);
	let reportError = $state('');
	let reportID = $state('');
	let isSpeaking = $state(false);
	let isSpeechPaused = $state(false);
	let audioMessage = $state('');
	let speechSession = 0;
	let speechChunks: string[] = [];
	let speechChunkIndex = 0;

	let availableVariants = $derived(
		readingDepths.filter((variant) =>
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
			stopAudio();
		};
	});

	async function refreshUntilReady(isActive: () => boolean): Promise<void> {
		for (let attempt = 0; attempt < 15; attempt += 1) {
			try {
				const result = await loadPublicShare(token);
				if (!isActive()) return;
				if (result.status === 'ready') {
					document = result;
					selectedVariant =
						readingDepths.find((variant) =>
							result.texts.some((text) => text.variant === variant)
						) ?? 'concise';
					loading = false;
					preparing = false;
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
		selectedVariant = variant;
	}

	function narrationText(markdown: string): string {
		return markdown
			.replace(/```[\s\S]*?```/g, ' ')
			.replace(/!\[[^\]]*\]\([^)]*\)/g, ' ')
			.replace(/\[([^\]]+)\]\([^)]*\)/g, '$1')
			.replace(/^#{1,6}\s+/gm, '')
			.replace(/[*_>`~|-]/g, ' ')
			.replace(/\s+/g, ' ')
			.trim();
	}

	function narrationChunks(text: string): string[] {
		const sentences = text.match(/[^.!?]+(?:[.!?]+|$)/g) ?? [text];
		const chunks: string[] = [];
		let current = '';
		for (const sentence of sentences) {
			const next = `${current} ${sentence}`.trim();
			if (current && next.length > 700) {
				chunks.push(current);
				current = sentence.trim();
			} else {
				current = next;
			}
		}
		if (current) chunks.push(current);
		return chunks;
	}

	function speakNextChunk(session: number): void {
		if (session !== speechSession) return;
		const text = speechChunks[speechChunkIndex];
		if (!text) {
			finishAudio();
			return;
		}
		const utterance = new SpeechSynthesisUtterance(text);
		utterance.rate = 0.96;
		utterance.pitch = 1;
		utterance.onend = () => {
			if (session !== speechSession) return;
			speechChunkIndex += 1;
			speakNextChunk(session);
		};
		utterance.onerror = () => {
			if (session !== speechSession) return;
			finishAudio();
			audioMessage = 'Audio narration stopped unexpectedly.';
		};
		window.speechSynthesis.speak(utterance);
	}

	function toggleAudio(): void {
		if (!('speechSynthesis' in window)) {
			audioMessage = 'Audio narration is not available in this browser.';
			return;
		}
		if (isSpeaking && isSpeechPaused) {
			window.speechSynthesis.resume();
			isSpeechPaused = false;
			return;
		}
		if (isSpeaking) {
			window.speechSynthesis.pause();
			isSpeechPaused = true;
			return;
		}
		const text = narrationText(selectedText);
		if (!text) return;
		window.speechSynthesis.cancel();
		const session = ++speechSession;
		speechChunks = narrationChunks(text);
		speechChunkIndex = 0;
		audioMessage = '';
		isSpeaking = true;
		isSpeechPaused = false;
		speakNextChunk(session);
	}

	function finishAudio(): void {
		isSpeaking = false;
		isSpeechPaused = false;
	}

	function stopAudio(): void {
		speechSession += 1;
		if (typeof window !== 'undefined') window.speechSynthesis?.cancel();
		finishAudio();
	}

	async function submitReport(event: SubmitEvent): Promise<void> {
		event.preventDefault();
		if (reportBusy) return;
		reportBusy = true;
		reportError = '';
		try {
			const result = await submitContentReport(token, {
				category: reportCategory,
				variant: document ? selectedVariant : undefined,
				reporterName: reporterName.trim() || undefined,
				reporterEmail: reporterEmail.trim() || undefined,
				workDescription: workDescription.trim() || undefined,
				explanation: reportExplanation.trim(),
				goodFaith: reportGoodFaith
			});
			reportID = result.id;
		} catch (error) {
			reportError = error instanceof Error ? error.message : 'The report could not be submitted.';
		} finally {
			reportBusy = false;
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
		<a class="public-share-cta" href="/landing">Try Briefly</a>

		<main class="public-share-reader">
			<article class="public-share-body text-foreground! font-serif!">
				<MarkdownText text={selectedText} />
			</article>
			<footer class="public-share-meta">
				{#if document.sourceURL}
					<a href={document.sourceURL} target="_blank" rel="noreferrer">
						Open original <ArrowUpRightIcon />
					</a>
				{/if}
				<button type="button" onclick={() => reportDialog?.showModal()}>
					<FlagIcon /> Report this share
				</button>
			</footer>
		</main>

		{#if availableVariants.length > 0}
			<footer class="public-share-action-bar" aria-label="Document and audio controls">
				<button
					class="public-share-play"
					type="button"
					onclick={toggleAudio}
					aria-label={isSpeaking && !isSpeechPaused ? 'Pause audio' : 'Play audio'}
				>
					{#if isSpeaking && !isSpeechPaused}<PauseIcon />{:else}<PlayIcon />{/if}
				</button>
				<div class="public-share-depth-divider"></div>
				<DepthControl
					variants={availableVariants}
					selected={selectedVariant}
					onselect={selectVariant}
				/>
				<span class="public-share-audio-status" aria-live="polite">{audioMessage}</span>
			</footer>
		{/if}
	{/if}

	<dialog bind:this={reportDialog} class="content-report-dialog" aria-labelledby="report-title">
		{#if reportID}
			<div class="report-received">
				<FlagIcon />
				<h2 id="report-title">Report received</h2>
				<p>We will review the reported share. Reference: <code>{reportID}</code></p>
				<button type="button" onclick={() => reportDialog?.close()}>Close</button>
			</div>
		{:else}
			<form onsubmit={submitReport}>
				<header>
					<div>
						<p>Notice and action</p>
						<h2 id="report-title">Report illegal content</h2>
					</div>
					<button type="button" class="report-close" onclick={() => reportDialog?.close()}>
						Close
					</button>
				</header>

				<label>
					<span>Reason</span>
					<select bind:value={reportCategory}>
						<option value="copyright">Copyright infringement</option>
						<option value="privacy">Privacy or confidential information</option>
						<option value="child-safety">Child sexual abuse or exploitation</option>
						<option value="other">Other illegal content</option>
					</select>
				</label>

				{#if reportCategory === 'copyright'}
					<label>
						<span>Copyrighted work</span>
						<textarea
							bind:value={workDescription}
							maxlength="2000"
							rows="3"
							required
							placeholder="Identify the work and, if available, its original URL."
						></textarea>
					</label>
				{/if}

				<div class="report-contact-fields">
					<label>
						<span>Name{reportCategory === 'child-safety' ? ' (optional)' : ''}</span>
						<input
							bind:value={reporterName}
							maxlength="200"
							required={reportCategory !== 'child-safety'}
						/>
					</label>
					<label>
						<span>Email{reportCategory === 'child-safety' ? ' (optional)' : ''}</span>
						<input
							type="email"
							bind:value={reporterEmail}
							maxlength="254"
							required={reportCategory !== 'child-safety'}
						/>
					</label>
				</div>

				<label>
					<span>Why this content is illegal</span>
					<textarea
						bind:value={reportExplanation}
						maxlength="5000"
						rows="6"
						required
						placeholder="Explain the legal issue precisely enough for us to assess it."
					></textarea>
				</label>

				<label class="report-confirmation">
					<input type="checkbox" bind:checked={reportGoodFaith} required />
					<span>
						{reportCategory === 'copyright'
							? 'I believe in good faith that the disputed use is not authorized by the owner, its agent, or law, and state under penalty of perjury that this report is accurate and I am authorized to act for the owner.'
							: 'I believe in good faith that this report is accurate and complete.'}
					</span>
				</label>

				{#if reportError}<p class="report-error" role="alert">{reportError}</p>{/if}
				<footer>
					<button type="button" class="secondary" onclick={() => reportDialog?.close()}>Cancel</button>
					<button type="submit" disabled={reportBusy}>
						{reportBusy ? 'Submitting…' : 'Submit report'}
					</button>
				</footer>
			</form>
		{/if}
	</dialog>
</div>

<style>
	.content-report-dialog {
		width: min(620px, calc(100% - 28px));
		max-height: min(760px, calc(100dvh - 28px));
		padding: 0;
		overflow: auto;
		border: 1px solid var(--border);
		border-radius: 0;
		background: var(--background);
		color: var(--foreground);
		box-shadow: 0 30px 100px color-mix(in srgb, var(--foreground) 28%, transparent);
	}

	.content-report-dialog::backdrop {
		background: color-mix(in srgb, var(--foreground) 42%, transparent);
		backdrop-filter: blur(3px);
	}

	.content-report-dialog form,
	.report-received {
		display: grid;
		gap: 18px;
		padding: clamp(22px, 5vw, 36px);
	}

	.content-report-dialog header {
		display: flex;
		align-items: start;
		justify-content: space-between;
		gap: 16px;
	}

	.content-report-dialog header p {
		margin: 0 0 5px;
		color: var(--muted-foreground);
		font-size: 10px;
		font-weight: 700;
		letter-spacing: 0.09em;
		text-transform: uppercase;
	}

	.content-report-dialog h2 {
		margin: 0;
		font-family: 'New York', 'Iowan Old Style', Georgia, serif;
		font-size: 28px;
	}

	.content-report-dialog label {
		display: grid;
		gap: 7px;
		font-size: 12px;
		font-weight: 650;
	}

	.content-report-dialog input,
	.content-report-dialog select,
	.content-report-dialog textarea {
		width: 100%;
		box-sizing: border-box;
		padding: 11px 12px;
		border: 1px solid var(--border);
		border-radius: 0;
		background: var(--background);
		color: inherit;
		font: inherit;
		font-size: 14px;
	}

	.content-report-dialog textarea {
		resize: vertical;
		line-height: 1.45;
	}

	.report-contact-fields {
		display: grid;
		grid-template-columns: 1fr 1fr;
		gap: 12px;
	}

	.content-report-dialog .report-confirmation {
		display: flex;
		align-items: start;
		gap: 10px;
		font-weight: 500;
		line-height: 1.45;
	}

	.report-confirmation input {
		width: 16px;
		margin-top: 2px;
	}

	.content-report-dialog footer {
		display: flex;
		justify-content: end;
		gap: 8px;
	}

	.content-report-dialog button {
		min-height: 40px;
		padding: 0 16px;
		border: 0;
		border-radius: 0;
		background: var(--primary);
		color: var(--primary-foreground);
		font: inherit;
		font-size: 12px;
		font-weight: 700;
		cursor: pointer;
	}

	.content-report-dialog button.secondary,
	.content-report-dialog .report-close {
		background: transparent;
		color: var(--muted-foreground);
	}

	.content-report-dialog button:disabled {
		cursor: wait;
		opacity: 0.6;
	}

	.report-error {
		margin: 0;
		color: var(--destructive);
		font-size: 13px;
	}

	.report-received {
		justify-items: center;
		padding-block: 48px;
		text-align: center;
	}

	.report-received :global(svg) {
		width: 28px;
		height: 28px;
	}

	.report-received p {
		margin: 0;
		color: var(--muted-foreground);
		line-height: 1.5;
	}

	@media (max-width: 560px) {
		.report-contact-fields {
			grid-template-columns: 1fr;
		}
	}
</style>
