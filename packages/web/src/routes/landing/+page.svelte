<script lang="ts">
	import BrieflyWordmark from '$lib/BrieflyWordmark.svelte';

	const description =
		'Save articles, videos, podcasts, PDFs, and notes. Briefly summarizes each one at the depth you choose. Free on Mac, iPhone, and iPad.';
</script>

<svelte:head>
	<title>Briefly</title>
	<meta name="description" content={description} />
	<link rel="canonical" href="https://www.readbriefly.fyi/landing" />
	<meta property="og:type" content="website" />
	<meta property="og:title" content="Briefly" />
	<meta property="og:description" content={description} />
	<meta property="og:url" content="https://www.readbriefly.fyi/landing" />
	<meta property="og:image" content="https://www.readbriefly.fyi/og-landing-v3.png" />
	<meta property="og:image:width" content="1200" />
	<meta property="og:image:height" content="630" />
	<meta property="og:image:alt" content="Briefly" />
	<meta name="twitter:card" content="summary_large_image" />
	<meta name="twitter:title" content="Briefly" />
	<meta name="twitter:description" content={description} />
	<meta name="twitter:image" content="https://www.readbriefly.fyi/og-landing-v3.png" />
</svelte:head>

<div class="landing">
	<main>
		<img class="icon" src="/brand/briefly-app-icon.png" alt="" width="256" height="256" />
		<h1>
			<BrieflyWordmark class="wordmark" />
			<span class="sr-only">Briefly</span>
		</h1>

		<p>
			Save articles, videos, podcasts, PDFs, and notes. Briefly summarizes each one at the depth
			you choose, so you can read or listen when you have time.
		</p>
		<p class="quiet">
			Free on Mac, iPhone, and iPad. Summaries run on your own OpenRouter account, and your
			library stays on your devices and in your iCloud.
		</p>
		<p class="availability">
			<a href="https://apps.apple.com/us/app/readbriefly/id6799611069?mt=12">
				Download on the App Store
			</a>
		</p>
	</main>

	<footer>
		<a href="/privacy">Privacy</a>
		<a href="/terms">Terms</a>
		<a href="/imprint">Imprint</a>
		<a href="/feedback">Feedback</a>
	</footer>
</div>

<style>
	/* Same watercolor paper and brand green as the public share reader. */
	:global(:root:has(.landing)) {
		--background: #f6f1ea;
		--foreground: #1b2420;
		--muted-foreground: #5c645e;
		--primary: #10372d;
		--border: color-mix(in srgb, #10372d 16%, transparent);
		--landing-backdrop: url('/backgrounds/desktop-light.webp');
		color-scheme: light dark !important;
		background: var(--background);
	}

	@media (max-aspect-ratio: 1/1) {
		:global(:root:has(.landing)) {
			--landing-backdrop: url('/backgrounds/mobile-light.webp');
		}
	}

	@media (prefers-color-scheme: dark) {
		:global(:root:has(.landing)) {
			--background: #0f1714;
			--foreground: #e9e5dc;
			--muted-foreground: #9ba59f;
			--primary: #c9ddd0;
			--border: color-mix(in srgb, #e9e5dc 16%, transparent);
			--landing-backdrop: url('/backgrounds/desktop-dark.webp');
		}
	}

	@media (prefers-color-scheme: dark) and (max-aspect-ratio: 1/1) {
		:global(:root:has(.landing)) {
			--landing-backdrop: url('/backgrounds/mobile-dark.webp');
		}
	}

	:global(html:has(.landing)),
	:global(html:has(.landing) body) {
		height: auto;
		min-height: 100%;
		overflow: visible;
	}

	.landing {
		position: relative;
		isolation: isolate;
		display: flex;
		min-height: 100dvh;
		flex-direction: column;
		color: var(--foreground);
		font-family: var(--theme-font-sans);
		font-weight: 500;
		-webkit-font-smoothing: antialiased;
	}

	.landing::before {
		content: '';
		position: fixed;
		z-index: -1;
		inset: 0;
		background: var(--background) var(--landing-backdrop) center / cover no-repeat;
	}

	main {
		display: flex;
		width: min(520px, calc(100% - 32px));
		flex: 1;
		flex-direction: column;
		justify-content: center;
		margin-inline: auto;
		padding-block: 72px 48px;
	}

	.icon {
		display: block;
		width: 72px;
		height: 72px;
		border-radius: 22.5%;
		box-shadow: 0 10px 28px rgb(16 55 45 / 14%);
	}

	h1 {
		margin: 32px 0 28px;
		color: var(--primary);
		line-height: 0;
	}

	h1 :global(.wordmark) {
		display: block;
		width: auto;
		height: 44px;
	}

	p {
		margin: 0;
		font-size: 18px;
		line-height: 1.6;
		text-wrap: pretty;
	}

	p + p {
		margin-top: 16px;
	}

	.quiet {
		color: var(--muted-foreground);
		font-size: 16px;
	}

	.availability {
		margin-top: 32px;
		padding-top: 20px;
		border-top: 1px solid var(--border);
		font-size: 15px;
	}

	.availability a {
		display: inline-flex;
		min-height: 44px;
		align-items: center;
		padding: 0 18px;
		background: var(--primary);
		color: var(--background);
		font-weight: 650;
		text-decoration: none;
		transition: opacity 160ms ease;
	}

	.availability a:hover {
		opacity: 0.86;
	}

	footer {
		display: flex;
		width: min(520px, calc(100% - 32px));
		flex-wrap: wrap;
		gap: 8px 20px;
		margin-inline: auto;
		padding-block: 24px max(24px, env(safe-area-inset-bottom));
		font-size: 13px;
	}

	footer a {
		color: var(--muted-foreground);
		text-decoration: none;
	}

	footer a:hover,
	footer a:focus-visible {
		color: var(--foreground);
		text-decoration: underline;
		text-underline-offset: 3px;
	}

	.sr-only {
		position: absolute;
		width: 1px;
		height: 1px;
		overflow: hidden;
		clip-path: inset(50%);
		white-space: nowrap;
	}

	@media (max-width: 480px) {
		main {
			padding-top: 56px;
		}

		h1 :global(.wordmark) {
			height: 36px;
		}

		p {
			font-size: 17px;
		}

		.quiet {
			font-size: 15px;
		}
	}
</style>
