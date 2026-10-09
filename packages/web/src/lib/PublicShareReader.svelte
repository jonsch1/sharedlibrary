<script lang="ts">
	import { onMount } from 'svelte';
	import ArrowUpRightIcon from '@lucide/svelte/icons/arrow-up-right';
	import FlagIcon from '@lucide/svelte/icons/flag';
	import LoaderCircleIcon from '@lucide/svelte/icons/loader-circle';
	import PauseIcon from '@lucide/svelte/icons/pause';
	import PlayIcon from '@lucide/svelte/icons/play';
	import BrieflyWordmark from '$lib/BrieflyWordmark.svelte';
	import DepthControl from '$lib/reader/DepthControl.svelte';
	import MarkdownText from '$lib/reader/MarkdownView.svelte';
	import { shouldRenderSourceAsPlainText } from '$lib/reader/source-text';
	import {
		loadPublicShare,
		submitContentReport,
		type ContentReportCategory,
		type PublicShareDocument
	} from '$lib/share-links.js';
	import { libraryVariants, type LibraryVariant } from '$lib/library.js';

	let { token }: { token: string } = $props();

	let item = $state<PublicShareDocument | null>(null);
	let selectedVariant = $state<LibraryVariant>('concise');
	let loading = $state(true);
	let preparing = $state(false);
	let errorMessage = $state('');
	let errorRetryable = $state(false);
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
		libraryVariants.filter((variant) => item?.texts.some((text) => text.variant === variant))
	);
	let title = $derived(item?.title?.trim() || 'Shared item');
	let selectedText = $derived(
		withoutLeadingTitle(
			item?.texts.find((text) => text.variant === selectedVariant)?.markdown ?? '',
			title
		)
	);
	let sourceHost = $derived(hostName(item?.sourceURL));
	let savedDate = $derived(formattedDate(item?.createdAt ?? item?.updatedAt));
	let isPlaying = $derived(isSpeaking && !isSpeechPaused);

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
					item = result;
					selectedVariant =
						libraryVariants.find((variant) =>
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
			errorMessage = 'This shared item is taking longer than expected. Reload to try again.';
			errorRetryable = true;
			preparing = false;
		}
	}

	function hostName(value?: string): string {
		if (!value) return '';
		try {
			return new URL(value).hostname.replace(/^www\./, '');
		} catch {
			return '';
		}
	}

	function formattedDate(value?: string): string {
		if (!value) return '';
		const date = new Date(value);
		if (Number.isNaN(date.getTime())) return '';
		return new Intl.DateTimeFormat(undefined, { dateStyle: 'medium' }).format(date);
	}

	// Summaries often open with the item's title; the reader heading already shows it.
	function withoutLeadingTitle(markdown: string, heading: string): string {
		const match = /^\s*#\s+(.+?)\s*#*\s*(?:\n|$)/.exec(markdown);
		const normalized = (value: string) => value.toLowerCase().replace(/[^\p{L}\p{N}]+/gu, '');
		if (!match || normalized(match[1]) !== normalized(heading)) return markdown;
		return markdown.slice(match[0].length);
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
			audioMessage = 'Audio stopped unexpectedly.';
		};
		window.speechSynthesis.speak(utterance);
	}

	function toggleAudio(): void {
		if (!('speechSynthesis' in window)) {
			audioMessage = 'Audio isn’t available in this browser.';
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
				variant: item ? selectedVariant : undefined,
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
	<title>{item ? title : 'Shared item'} · Briefly</title>
	<meta name="description" content={item?.excerpt || 'An item shared with you through Briefly.'} />
</svelte:head>

<div class="public-share-shell">
	<header class="share-header">
		<div class="share-column share-header-row">
			<a class="share-brand" href="/landing" aria-label="Briefly">
				<BrieflyWordmark class="share-wordmark" />
			</a>
			<a class="share-cta" href="/landing">Try Briefly</a>
		</div>
	</header>

	{#if loading || preparing}
		<main class="share-state" aria-live="polite" aria-busy="true">
			<LoaderCircleIcon class="spin" aria-hidden="true" />
			<p class="share-state-title">{preparing ? 'Preparing this item…' : 'Opening item…'}</p>
			{#if preparing}<p>The summary will appear here in a moment.</p>{/if}
		</main>
	{:else if errorMessage && !item}
		<main class="share-state">
			<h1>Share link unavailable</h1>
			<p>{errorMessage}</p>
			<div class="share-state-actions">
				{#if errorRetryable}
					<button type="button" class="share-cta" onclick={() => window.location.reload()}>
						Reload
					</button>
				{/if}
				<a class="share-text-link" href="/landing">Discover Briefly</a>
			</div>
		</main>
	{:else if item}
		<main class="share-column share-reader">
			<article>
				<header class="share-heading">
					<h1>{title}</h1>
					{#if sourceHost || savedDate}
						<p class="share-byline">
							{#if sourceHost && item.sourceURL}
								<a href={item.sourceURL} target="_blank" rel="noreferrer">
									{sourceHost}<ArrowUpRightIcon aria-hidden="true" />
								</a>
							{/if}
							{#if sourceHost && savedDate}<span aria-hidden="true">·</span>{/if}
							{#if savedDate}<span>{savedDate}</span>{/if}
						</p>
					{/if}
				</header>
				<div class="share-body">
					<MarkdownText
						text={selectedText}
						plain={shouldRenderSourceAsPlainText(selectedVariant, item.sourceURL)}
					/>
				</div>
			</article>

			<aside class="share-invite" aria-labelledby="share-invite-title">
				<p id="share-invite-title" class="share-invite-title">Shared with Briefly</p>
				<p>
					Save anything worth understanding and read it at the depth you choose, on Mac,
					iPhone, and iPad.
				</p>
				<a class="share-cta" href="/landing">Try Briefly</a>
			</aside>

			<footer class="share-footer">
				{#if item.sourceURL}
					<a href={item.sourceURL} target="_blank" rel="noreferrer">
						Open original <ArrowUpRightIcon aria-hidden="true" />
					</a>
				{/if}
				<button type="button" onclick={() => reportDialog?.showModal()}>
					<FlagIcon aria-hidden="true" /> Report this share
				</button>
			</footer>
		</main>

		{#if availableVariants.length > 0}
			<div class="share-bar" role="group" aria-label="Reading and audio controls">
				<div class="share-column share-bar-row">
					{#if availableVariants.length > 1}
						<DepthControl
							variants={availableVariants}
							selected={selectedVariant}
							onselect={selectVariant}
						/>
					{/if}
					<span class="share-audio-status" aria-live="polite">{audioMessage}</span>
					<button
						class="share-play"
						type="button"
						onclick={toggleAudio}
						aria-label={isPlaying ? 'Pause audio' : 'Play audio'}
					>
						{#if isPlaying}<PauseIcon aria-hidden="true" />{:else}<PlayIcon aria-hidden="true" />{/if}
					</button>
				</div>
			</div>
		{/if}
	{/if}

	<dialog bind:this={reportDialog} class="content-report-dialog" aria-labelledby="report-title">
		{#if reportID}
			<div class="report-received">
				<FlagIcon aria-hidden="true" />
				<h2 id="report-title">Report received</h2>
				<p>We will review the reported share. Reference: <code>{reportID}</code></p>
				<button type="button" class="report-primary" onclick={() => reportDialog?.close()}>
					Close
				</button>
			</div>
		{:else}
			<form onsubmit={submitReport}>
				<header class="report-header">
					<div>
						<p>Notice and action</p>
						<h2 id="report-title">Report illegal content</h2>
					</div>
					<button type="button" class="report-close" onclick={() => reportDialog?.close()}>
						Close
					</button>
				</header>

				<div class="report-fields">
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
								autocomplete="name"
								required={reportCategory !== 'child-safety'}
							/>
						</label>
						<label>
							<span>Email{reportCategory === 'child-safety' ? ' (optional)' : ''}</span>
							<input
								type="email"
								bind:value={reporterEmail}
								maxlength="254"
								autocomplete="email"
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
				</div>

				<footer class="report-actions">
					<button type="button" class="report-secondary" onclick={() => reportDialog?.close()}>
						Cancel
					</button>
					<button type="submit" class="report-primary" disabled={reportBusy}>
						{reportBusy ? 'Submitting…' : 'Submit report'}
					</button>
				</footer>
			</form>
		{/if}
	</dialog>
</div>

<style>
	/* Share reader palette: watercolor paper with the Briefly brand green. */
	:global(:root:has(.public-share-shell)) {
		--background: #f6f1ea;
		--foreground: #1b2420;
		--muted-foreground: #5c645e;
		--primary: #10372d;
		--primary-foreground: #f6f1ea;
		--border: color-mix(in srgb, #10372d 16%, transparent);
		--ring: #10372d;
		--destructive: #a2382c;
		--share-backdrop: url('/backgrounds/desktop-light.webp');
		color-scheme: light dark !important;
		background: var(--background);
	}

	@media (max-aspect-ratio: 1/1) {
		:global(:root:has(.public-share-shell)) {
			--share-backdrop: url('/backgrounds/mobile-light.webp');
		}
	}

	@media (prefers-color-scheme: dark) {
		:global(:root:has(.public-share-shell)) {
			--background: #0f1714;
			--foreground: #e9e5dc;
			--muted-foreground: #9ba59f;
			--primary: #c9ddd0;
			--primary-foreground: #0f1714;
			--border: color-mix(in srgb, #e9e5dc 16%, transparent);
			--ring: #c9ddd0;
			--destructive: #f08c7e;
			--share-backdrop: url('/backgrounds/desktop-dark.webp');
		}
	}

	@media (prefers-color-scheme: dark) and (max-aspect-ratio: 1/1) {
		:global(:root:has(.public-share-shell)) {
			--share-backdrop: url('/backgrounds/mobile-dark.webp');
		}
	}

	/* Let the document scroll so mobile browsers can collapse their toolbars. */
	:global(html:has(.public-share-shell)),
	:global(html:has(.public-share-shell) body) {
		height: auto;
		min-height: 100%;
		overflow: visible;
	}

	.public-share-shell {
		position: relative;
		isolation: isolate;
		min-height: 100dvh;
		color: var(--foreground);
		font-family: var(--theme-font-sans);
		font-weight: 500;
		-webkit-font-smoothing: antialiased;
	}

	.public-share-shell::before {
		content: '';
		position: fixed;
		z-index: -1;
		inset: 0;
		background: var(--background) var(--share-backdrop) center / cover no-repeat;
	}

	.share-column {
		width: min(680px, calc(100% - 40px));
		margin-inline: auto;
	}

	/* Header and bottom bar soften the text beneath them with a masked blur. */
	.share-header,
	.share-bar {
		position: fixed;
		z-index: 20;
		left: 0;
		right: 0;
	}

	.share-header::before,
	.share-bar::before {
		content: '';
		position: absolute;
		z-index: -1;
		inset: 0;
		-webkit-backdrop-filter: blur(14px);
		backdrop-filter: blur(14px);
	}

	.share-header {
		top: 0;
		padding: max(14px, env(safe-area-inset-top)) 0 30px;
	}

	.share-header::before {
		background: linear-gradient(
			to bottom,
			color-mix(in srgb, var(--background) 78%, transparent) 40%,
			transparent
		);
		-webkit-mask-image: linear-gradient(to bottom, #000 45%, transparent);
		mask-image: linear-gradient(to bottom, #000 45%, transparent);
	}

	.share-header-row {
		display: flex;
		align-items: center;
		justify-content: space-between;
		gap: 16px;
	}

	.share-brand {
		display: block;
		color: var(--primary);
	}

	.share-brand :global(.share-wordmark) {
		display: block;
		width: auto;
		height: 30px;
	}

	.share-cta {
		display: inline-flex;
		min-height: 36px;
		align-items: center;
		justify-content: center;
		padding: 0 14px;
		background: var(--primary);
		color: var(--primary-foreground);
		font-size: 14px;
		font-weight: 650;
		line-height: 1;
		text-decoration: none;
		white-space: nowrap;
		transition: opacity 160ms ease;
	}

	.share-cta:hover {
		opacity: 0.86;
	}

	.share-brand:focus-visible,
	.share-cta:focus-visible,
	.share-text-link:focus-visible,
	.share-byline a:focus-visible,
	.share-footer :is(a, button):focus-visible,
	.share-play:focus-visible,
	.share-body :global(a:focus-visible) {
		outline: 2px solid var(--ring);
		outline-offset: 3px;
	}

	/* Loading, preparing, and error states */
	.share-state {
		display: grid;
		min-height: 100dvh;
		place-content: center;
		justify-items: center;
		gap: 10px;
		padding: 96px 28px;
		color: var(--muted-foreground);
		text-align: center;
	}

	.share-state :global(svg) {
		width: 22px;
		height: 22px;
		margin-bottom: 4px;
	}

	.share-state h1,
	.share-state-title {
		margin: 0;
		color: var(--foreground);
		font-weight: 700;
	}

	.share-state h1 {
		font-size: clamp(26px, 5vw, 32px);
		letter-spacing: -0.015em;
	}

	.share-state-title {
		font-size: 17px;
	}

	.share-state p {
		max-width: 360px;
		margin: 0;
		font-size: 15px;
		line-height: 1.5;
	}

	.share-state-actions {
		display: flex;
		align-items: center;
		gap: 18px;
		margin-top: 14px;
	}

	.share-text-link {
		color: var(--foreground);
		font-size: 14px;
		font-weight: 650;
		text-decoration: underline;
		text-decoration-color: color-mix(in srgb, currentColor 35%, transparent);
		text-underline-offset: 4px;
	}

	/* Reader */
	.share-reader {
		padding: clamp(104px, 14vh, 136px) 0 calc(128px + env(safe-area-inset-bottom));
	}

	.share-heading h1 {
		margin: 0;
		color: var(--foreground);
		font-size: clamp(30px, 4.4vw, 40px);
		font-weight: 700;
		line-height: 1.12;
		letter-spacing: -0.02em;
		text-wrap: balance;
		overflow-wrap: anywhere;
	}

	.share-byline {
		display: flex;
		flex-wrap: wrap;
		align-items: center;
		gap: 4px 7px;
		margin: 12px 0 0;
		color: var(--muted-foreground);
		font-size: 15px;
		font-weight: 600;
	}

	.share-byline a {
		display: inline-flex;
		align-items: center;
		gap: 3px;
		color: inherit;
		text-decoration: none;
	}

	.share-byline a:hover {
		color: var(--foreground);
	}

	.share-byline :global(svg),
	.share-footer :global(svg) {
		width: 13px;
		height: 13px;
		flex: none;
	}

	.share-body {
		margin-top: 34px;
	}

	.share-body :global(.library-prose) {
		color: var(--foreground);
		font-family: var(--theme-font-serif);
		font-size: 19px;
		font-weight: 400;
		line-height: 1.7;
		overflow-wrap: break-word;
	}

	.share-body :global(.library-prose > :first-child) {
		margin-top: 0;
	}

	.share-body :global(.library-prose > :last-child) {
		margin-bottom: 0;
	}

	.share-body :global(:is(h1, h2, h3, h4)) {
		margin: 1.9em 0 0.55em;
		color: var(--foreground);
		font-family: var(--theme-font-sans);
		font-weight: 700;
		line-height: 1.25;
		letter-spacing: -0.012em;
	}

	.share-body :global(:is(h1, h2)) {
		font-size: 24px;
	}

	.share-body :global(h3) {
		font-size: 20px;
	}

	.share-body :global(h4) {
		font-size: 17px;
	}

	.share-body :global(:is(p, ul, ol, blockquote, pre, table)) {
		margin: 0 0 1.05em;
	}

	.share-body :global(:is(ul, ol)) {
		padding-left: 1.3em;
	}

	.share-body :global(ul) {
		list-style: disc;
	}

	.share-body :global(ol) {
		list-style: decimal;
	}

	.share-body :global(li) {
		margin: 0.35em 0;
		padding-left: 0.2em;
	}

	.share-body :global(li::marker) {
		color: var(--muted-foreground);
	}

	.share-body :global(strong) {
		font-weight: 650;
	}

	.share-body :global(a) {
		color: inherit;
		text-decoration: underline;
		text-decoration-color: color-mix(in srgb, var(--primary) 45%, transparent);
		text-decoration-thickness: 1px;
		text-underline-offset: 4px;
	}

	.share-body :global(a:hover) {
		text-decoration-color: currentColor;
	}

	.share-body :global(blockquote) {
		padding-left: 1em;
		border-left: 2px solid color-mix(in srgb, var(--foreground) 22%, transparent);
		color: color-mix(in srgb, var(--foreground) 82%, var(--background));
		font-style: italic;
	}

	.share-body :global(code) {
		padding: 0.1em 0.3em;
		background: color-mix(in srgb, var(--foreground) 7%, transparent);
		font-family: var(--theme-font-mono);
		font-size: 0.82em;
	}

	.share-body :global(pre) {
		overflow-x: auto;
		padding: 14px 16px;
		background: color-mix(in srgb, var(--foreground) 6%, transparent);
		line-height: 1.5;
	}

	.share-body :global(pre code) {
		padding: 0;
		background: none;
	}

	.share-body :global(hr) {
		margin: 2em 0;
		border: 0;
		border-top: 1px solid var(--border);
	}

	.share-body :global(table) {
		display: block;
		overflow-x: auto;
		border-collapse: collapse;
		font-size: 0.88em;
	}

	.share-body :global(:is(th, td)) {
		padding: 6px 12px 6px 0;
		border-bottom: 1px solid var(--border);
		text-align: left;
	}

	/* End of item invitation */
	.share-invite {
		display: grid;
		justify-items: start;
		gap: 10px;
		margin-top: 72px;
		padding-top: 30px;
		border-top: 1px solid var(--border);
	}

	.share-invite-title {
		margin: 0;
		color: var(--foreground);
		font-size: 17px;
		font-weight: 700;
	}

	.share-invite p:not(.share-invite-title) {
		max-width: 460px;
		margin: 0 0 6px;
		color: var(--muted-foreground);
		font-size: 15px;
		line-height: 1.5;
	}

	.share-footer {
		display: flex;
		flex-wrap: wrap;
		align-items: center;
		gap: 4px 22px;
		margin-top: 40px;
		color: var(--muted-foreground);
		font-size: 13px;
		font-weight: 600;
	}

	.share-footer a,
	.share-footer button {
		display: inline-flex;
		min-height: 32px;
		align-items: center;
		gap: 5px;
		color: inherit;
		font: inherit;
		text-decoration: none;
	}

	.share-footer a:hover,
	.share-footer button:hover {
		color: var(--foreground);
	}

	/* Bottom bar */
	.share-bar {
		bottom: 0;
		padding: 44px 0 max(14px, env(safe-area-inset-bottom));
	}

	.share-bar::before {
		background: linear-gradient(
			to top,
			color-mix(in srgb, var(--background) 86%, transparent) 50%,
			transparent
		);
		-webkit-mask-image: linear-gradient(to top, #000 60%, transparent);
		mask-image: linear-gradient(to top, #000 60%, transparent);
	}

	.share-bar-row {
		display: flex;
		align-items: center;
		gap: 12px;
	}

	.share-audio-status {
		flex: 1;
		min-width: 0;
		color: var(--muted-foreground);
		font-size: 13px;
		font-weight: 600;
		text-align: right;
	}

	.share-play {
		display: grid;
		width: 52px;
		height: 52px;
		flex: none;
		place-items: center;
		border-radius: 50%;
		background: var(--foreground);
		color: var(--background);
		box-shadow: 0 8px 24px color-mix(in srgb, #000 16%, transparent);
		transition: transform 160ms ease;
	}

	.share-play:active {
		transform: scale(0.95);
	}

	.share-play :global(svg) {
		width: 20px;
		height: 20px;
		fill: currentColor;
	}

	@media (max-width: 560px) {
		.share-column {
			width: calc(100% - 40px);
		}

		.share-brand :global(.share-wordmark) {
			height: 26px;
		}

		.share-heading h1 {
			font-size: 29px;
		}

		.share-body :global(.library-prose) {
			font-size: 18px;
			line-height: 1.66;
		}

		.share-body :global(:is(h1, h2)) {
			font-size: 22px;
		}

		.share-bar-row {
			gap: 8px;
		}
	}

	/* Report dialog */
	.content-report-dialog {
		width: min(600px, calc(100% - 24px));
		max-height: min(800px, calc(100dvh - 24px));
		margin: auto;
		padding: 0;
		overflow: auto;
		overscroll-behavior: contain;
		border: 0;
		background: var(--background);
		color: var(--foreground);
		box-shadow: 0 30px 90px color-mix(in srgb, #000 30%, transparent);
	}

	.content-report-dialog::backdrop {
		background: rgb(15 23 20 / 0.42);
		-webkit-backdrop-filter: blur(6px);
		backdrop-filter: blur(6px);
	}

	.report-header {
		position: sticky;
		z-index: 1;
		top: 0;
		display: flex;
		align-items: start;
		justify-content: space-between;
		gap: 16px;
		padding: 24px 28px 14px;
		background: var(--background);
	}

	.report-header p {
		margin: 0 0 6px;
		color: var(--muted-foreground);
		font-size: 11px;
		font-weight: 700;
		letter-spacing: 0.09em;
		text-transform: uppercase;
	}

	.content-report-dialog h2 {
		margin: 0;
		font-size: 25px;
		font-weight: 700;
		line-height: 1.15;
		letter-spacing: -0.015em;
	}

	.report-fields {
		display: grid;
		gap: 18px;
		padding: 10px 28px 20px;
	}

	.report-fields label {
		display: grid;
		gap: 7px;
		font-size: 13px;
		font-weight: 650;
	}

	.report-fields :is(input, select, textarea) {
		width: 100%;
		min-height: 44px;
		padding: 10px 12px;
		border: 1px solid var(--border);
		border-radius: 0;
		background: color-mix(in srgb, var(--foreground) 4%, var(--background));
		color: inherit;
		font: inherit;
		font-size: 16px;
		font-weight: 500;
	}

	.report-fields textarea {
		resize: vertical;
		line-height: 1.45;
	}

	.report-fields :is(input, select, textarea):focus-visible {
		border-color: var(--ring);
		outline: 1px solid var(--ring);
		outline-offset: 0;
	}

	.report-contact-fields {
		display: grid;
		grid-template-columns: 1fr 1fr;
		gap: 12px;
	}

	.report-fields .report-confirmation {
		display: flex;
		align-items: start;
		gap: 10px;
		font-weight: 500;
		line-height: 1.45;
	}

	.report-confirmation input {
		width: 18px;
		min-height: 0;
		height: 18px;
		flex: none;
		margin-top: 1px;
		accent-color: var(--primary);
	}

	.report-error {
		margin: 0;
		color: var(--destructive);
		font-size: 14px;
	}

	.report-actions {
		position: sticky;
		bottom: 0;
		display: flex;
		justify-content: end;
		gap: 8px;
		padding: 14px 28px 22px;
		background: var(--background);
	}

	.content-report-dialog button {
		min-height: 40px;
		padding: 0 16px;
		font-size: 14px;
		font-weight: 650;
	}

	.content-report-dialog .report-primary {
		background: var(--primary);
		color: var(--primary-foreground);
	}

	.content-report-dialog :is(.report-secondary, .report-close) {
		color: var(--muted-foreground);
	}

	.report-close {
		margin: -8px -12px 0 0;
	}

	.content-report-dialog button:hover:not(:disabled) {
		opacity: 0.86;
	}

	.content-report-dialog button:disabled {
		cursor: wait;
		opacity: 0.6;
	}

	.content-report-dialog button:focus-visible {
		outline: 2px solid var(--ring);
		outline-offset: 2px;
	}

	.report-received {
		display: grid;
		justify-items: center;
		gap: 14px;
		padding: 48px 28px;
		text-align: center;
	}

	.report-received :global(svg) {
		width: 26px;
		height: 26px;
	}

	.report-received p {
		margin: 0;
		color: var(--muted-foreground);
		line-height: 1.5;
	}

	.report-received code {
		font-family: var(--theme-font-mono);
		font-size: 0.85em;
		overflow-wrap: anywhere;
	}

	@media (max-width: 560px) {
		.content-report-dialog {
			width: calc(100% - 16px);
			max-height: calc(100dvh - 16px);
		}

		.report-header,
		.report-fields,
		.report-actions {
			padding-inline: 20px;
		}

		.report-contact-fields {
			grid-template-columns: 1fr;
		}
	}

	@media (prefers-reduced-motion: reduce) {
		.share-cta,
		.share-play {
			transition: none;
		}
	}
</style>
