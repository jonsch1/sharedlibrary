<script lang="ts">
	import { onMount } from 'svelte';
	import ArrowLeftIcon from '@lucide/svelte/icons/arrow-left';
	import ArrowUpRightIcon from '@lucide/svelte/icons/arrow-up-right';
	import type { Snippet } from 'svelte';

	type LegalPage = 'overview' | 'privacy' | 'terms' | 'cookies' | 'imprint';

	let {
		active,
		title,
		description,
		updated = '26 July 2026',
		children
	}: {
		active: LegalPage;
		title: string;
		description: string;
		updated?: string;
		children: Snippet;
	} = $props();

	const pages: Array<{ id: LegalPage; label: string; href: string }> = [
		{ id: 'overview', label: 'Legal overview', href: '/legal' },
		{ id: 'privacy', label: 'Privacy', href: '/privacy' },
		{ id: 'terms', label: 'Terms', href: '/terms' },
		{ id: 'cookies', label: 'Cookies & storage', href: '/cookies' },
		{ id: 'imprint', label: 'Imprint (Impressum)', href: '/imprint' }
	];

	const canonicalPath = pages.find((page) => page.id === active)?.href ?? '/legal';

	onMount(() => {
		document.body.classList.add('legal-body');
		return () => document.body.classList.remove('legal-body');
	});
</script>

<svelte:head>
	<title>{title} · Briefly</title>
	<meta name="description" content={description} />
	<link rel="canonical" href={`https://www.readbriefly.fyi${canonicalPath}`} />
	<meta property="og:type" content="website" />
	<meta property="og:title" content={`${title} · Briefly`} />
	<meta property="og:description" content={description} />
	<meta property="og:url" content={`https://www.readbriefly.fyi${canonicalPath}`} />
	<meta name="twitter:card" content="summary" />
</svelte:head>

<div class="legal-shell">
	<header class="legal-header">
		<a class="legal-brand" href="/landing" aria-label="Briefly home">
			<img src="/brand/briefly-app-icon.png" alt="" width="240" height="240" />
			<span>Briefly</span>
		</a>
		<a class="back-link" href="/landing">
			<ArrowLeftIcon aria-hidden="true" />
			Back to Briefly
		</a>
	</header>

	<div class="legal-grid">
		<aside class="legal-sidebar">
			<p class="legal-eyebrow">Legal</p>
			<nav aria-label="Legal pages">
				{#each pages as page}
					<a
						href={page.href}
						class:active={page.id === active}
						aria-current={page.id === active ? 'page' : undefined}
					>
						{page.label}
					</a>
				{/each}
			</nav>
			<div class="legal-contact">
				<span>Questions or requests</span>
				<a href="mailto:hello@readbriefly.fyi">
					hello@readbriefly.fyi
					<ArrowUpRightIcon aria-hidden="true" />
				</a>
			</div>
		</aside>

		<main class="legal-content">
			<header class="legal-title">
				<p class="legal-eyebrow">Briefly · Legal</p>
				<h1>{title}</h1>
				<div class="title-meta">
					<span>Effective 26 July 2026</span>
					<span>Last updated {updated}</span>
				</div>
				<p class="legal-description">{description}</p>
			</header>

			{@render children()}
		</main>
	</div>

	<footer class="legal-footer">
		<span>© 2026 Briefly</span>
		<div>
			<a href="/landing">Home</a>
			<a href="/">Open app</a>
			<a href="/imprint">Imprint</a>
			<a href="mailto:hello@readbriefly.fyi">Contact</a>
		</div>
	</footer>
</div>

<style>
	:global(body.legal-body),
	:global(body:has(.legal-shell)) {
		overflow-x: hidden;
		overflow-y: auto;
		background: #f4f0e6;
		color: #11110f;
	}

	:global(body.legal-body *) {
		box-sizing: border-box;
	}

	.legal-shell {
		--legal-ink: #11110f;
		--legal-blue: #164dff;
		--legal-paper: #f4f0e6;
		--legal-line: rgb(17 17 15 / 17%);
		min-height: 100vh;
		overflow-x: hidden;
		background:
			radial-gradient(circle at 72% -8%, rgb(255 255 255 / 92%), transparent 33rem),
			linear-gradient(90deg, rgb(22 77 255 / 4%) 1px, transparent 1px),
			var(--legal-paper);
		background-size:
			auto,
			64px 64px,
			auto;
		color: var(--legal-ink);
		font-family: 'Inter Variable', Inter, sans-serif;
	}

	.legal-header {
		display: flex;
		min-height: 76px;
		align-items: center;
		justify-content: space-between;
		padding: 0 clamp(22px, 5vw, 78px);
		border-bottom: 1px solid var(--legal-line);
		background: rgb(244 240 230 / 86%);
		backdrop-filter: blur(18px);
	}

	.legal-brand,
	.back-link,
	.legal-contact a,
	.legal-footer div {
		display: flex;
		align-items: center;
	}

	.legal-brand {
		gap: 9px;
		color: inherit;
		font-size: 18px;
		font-weight: 780;
		letter-spacing: -0.05em;
		text-decoration: none;
	}

	.legal-brand img {
		width: 34px;
		height: 34px;
		border-radius: 0;
	}

	.back-link {
		gap: 8px;
		color: rgb(17 17 15 / 58%);
		font-size: 11px;
		font-weight: 650;
		text-decoration: none;
	}

	.back-link:hover {
		color: var(--legal-blue);
	}

	.back-link :global(svg) {
		width: 14px;
		height: 14px;
	}

	.legal-grid {
		display: grid;
		width: min(1180px, calc(100% - 44px));
		grid-template-columns: 220px minmax(0, 760px);
		justify-content: center;
		gap: clamp(54px, 8vw, 118px);
		margin: 0 auto;
		padding: clamp(64px, 8vw, 110px) 0 120px;
	}

	.legal-sidebar {
		position: sticky;
		top: 40px;
		align-self: start;
	}

	.legal-eyebrow {
		margin: 0;
		color: var(--legal-blue);
		font-size: 10px;
		font-weight: 760;
		letter-spacing: 0.14em;
		text-transform: uppercase;
	}

	.legal-sidebar nav {
		display: grid;
		gap: 3px;
		margin-top: 18px;
	}

	.legal-sidebar nav a {
		padding: 10px 12px;
		border-left: 2px solid transparent;
		color: rgb(17 17 15 / 56%);
		font-size: 12px;
		font-weight: 610;
		text-decoration: none;
		transition:
			border-color 160ms ease,
			background 160ms ease,
			color 160ms ease;
	}

	.legal-sidebar nav a:hover,
	.legal-sidebar nav a.active {
		border-left-color: var(--legal-blue);
		background: rgb(22 77 255 / 6%);
		color: var(--legal-ink);
	}

	.legal-contact {
		display: grid;
		gap: 7px;
		margin-top: 40px;
		padding-top: 18px;
		border-top: 1px solid var(--legal-line);
	}

	.legal-contact span {
		color: rgb(17 17 15 / 47%);
		font-size: 9px;
		font-weight: 650;
		text-transform: uppercase;
	}

	.legal-contact a {
		gap: 5px;
		color: var(--legal-ink);
		font-size: 10px;
		font-weight: 650;
		text-decoration: none;
	}

	.legal-contact a:hover {
		color: var(--legal-blue);
	}

	.legal-contact :global(svg) {
		width: 12px;
		height: 12px;
	}

	.legal-title {
		padding-bottom: 46px;
		border-bottom: 1px solid var(--legal-line);
	}

	.legal-content {
		min-width: 0;
	}

	.legal-title h1 {
		max-width: 700px;
		margin: 18px 0 20px;
		font-family: ui-serif, 'Iowan Old Style', 'Palatino Linotype', Georgia, serif;
		font-size: clamp(48px, 7vw, 82px);
		font-weight: 530;
		letter-spacing: -0.055em;
		line-height: 0.98;
	}

	.title-meta {
		display: flex;
		flex-wrap: wrap;
		gap: 9px 20px;
		margin-bottom: 28px;
		color: rgb(17 17 15 / 45%);
		font-size: 10px;
	}

	.legal-description {
		max-width: 680px;
		margin: 0;
		color: rgb(17 17 15 / 67%);
		font-size: 17px;
		letter-spacing: -0.02em;
		line-height: 1.65;
	}

	:global(.legal-content section) {
		padding: 42px 0;
		border-bottom: 1px solid var(--legal-line);
	}

	:global(.legal-content section:last-child) {
		border-bottom: 0;
	}

	:global(.legal-content h2) {
		margin: 0 0 20px;
		font-family: ui-serif, 'Iowan Old Style', 'Palatino Linotype', Georgia, serif;
		font-size: clamp(28px, 4vw, 38px);
		font-weight: 560;
		letter-spacing: -0.035em;
		line-height: 1.12;
	}

	:global(.legal-content h3) {
		margin: 30px 0 10px;
		font-size: 13px;
		font-weight: 760;
		letter-spacing: -0.01em;
	}

	:global(.legal-content p),
	:global(.legal-content li),
	:global(.legal-content dd) {
		color: rgb(17 17 15 / 68%);
		font-size: 14px;
		line-height: 1.75;
	}

	:global(.legal-content p) {
		margin: 12px 0 0;
	}

	:global(.legal-content ul),
	:global(.legal-content ol) {
		display: grid;
		gap: 9px;
		margin: 16px 0 0;
		padding-left: 22px;
	}

	:global(.legal-content strong) {
		color: var(--legal-ink);
		font-weight: 720;
	}

	:global(.legal-content a) {
		color: #0e43dd;
		text-underline-offset: 3px;
	}

	:global(.legal-content a:hover) {
		color: #092b90;
	}

	:global(.legal-content table) {
		width: 100%;
		margin-top: 24px;
		border-collapse: collapse;
		border-top: 1px solid var(--legal-line);
		font-size: 11px;
		line-height: 1.55;
	}

	:global(.legal-content th),
	:global(.legal-content td) {
		padding: 15px 14px;
		border-bottom: 1px solid var(--legal-line);
		vertical-align: top;
		text-align: left;
	}

	:global(.legal-content th) {
		color: rgb(17 17 15 / 50%);
		font-size: 9px;
		font-weight: 760;
		letter-spacing: 0.08em;
		text-transform: uppercase;
	}

	:global(.legal-content td) {
		color: rgb(17 17 15 / 67%);
	}

	:global(.legal-content td:first-child) {
		color: var(--legal-ink);
		font-weight: 680;
	}

	:global(.legal-content .legal-callout) {
		margin-top: 22px;
		padding: 18px 20px;
		border: 1px solid rgb(22 77 255 / 20%);
		border-radius: 0;
		background: rgb(22 77 255 / 5%);
	}

	:global(.legal-content .legal-callout p:first-child) {
		margin-top: 0;
	}

	:global(.legal-content .legal-cards) {
		display: grid;
		grid-template-columns: repeat(2, minmax(0, 1fr));
		gap: 12px;
		margin-top: 24px;
	}

	:global(.legal-content .legal-card) {
		display: grid;
		min-height: 180px;
		align-content: space-between;
		gap: 30px;
		padding: 22px;
		border: 1px solid var(--legal-line);
		border-radius: 0;
		background: rgb(255 255 255 / 36%);
		color: inherit;
		text-decoration: none;
		transition:
			border-color 160ms ease,
			transform 160ms ease;
	}

	:global(.legal-content .legal-card:hover) {
		border-color: rgb(22 77 255 / 42%);
		color: inherit;
		transform: translateY(-2px);
	}

	:global(.legal-content .legal-card span) {
		color: var(--legal-blue);
		font-size: 10px;
		font-weight: 760;
		letter-spacing: 0.09em;
		text-transform: uppercase;
	}

	:global(.legal-content .legal-card h2) {
		margin: 0 0 10px;
		font-size: 28px;
	}

	:global(.legal-content .legal-card p) {
		margin: 0;
		font-size: 12px;
		line-height: 1.6;
	}

	:global(.legal-content .withdrawal-form) {
		margin-top: 20px;
		padding: 20px;
		border-left: 3px solid var(--legal-blue);
		background: rgb(255 255 255 / 42%);
	}

	:global(.legal-content .withdrawal-form p) {
		margin: 5px 0;
		font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace;
		font-size: 11px;
		line-height: 1.65;
	}

	.legal-footer {
		display: flex;
		align-items: center;
		justify-content: space-between;
		gap: 30px;
		padding: 26px clamp(22px, 5vw, 78px);
		border-top: 1px solid var(--legal-line);
		background: #e8e2d7;
		color: rgb(17 17 15 / 48%);
		font-size: 10px;
	}

	.legal-footer div {
		gap: 22px;
	}

	.legal-footer a {
		color: inherit;
		text-decoration: none;
	}

	.legal-footer a:hover {
		color: var(--legal-blue);
	}

	@media (max-width: 760px) {
		.legal-header {
			min-height: 66px;
		}

		.legal-grid {
			width: min(calc(100% - 36px), 680px);
			grid-template-columns: 1fr;
			gap: 40px;
			padding: 42px 0 80px;
		}

		.legal-sidebar {
			position: static;
		}

		.legal-sidebar nav {
			display: flex;
			flex-wrap: wrap;
			margin: 14px -4px 0;
			padding: 4px;
			overflow-x: visible;
		}

		.legal-sidebar nav a {
			flex: 0 0 auto;
			padding: 9px 10px;
			border: 0;
			border-radius: 0;
		}

		.legal-sidebar nav a:hover,
		.legal-sidebar nav a.active {
			border: 0;
		}

		.legal-contact {
			display: none;
		}

		.legal-title h1 {
			font-size: clamp(48px, 14vw, 72px);
		}

		:global(.legal-content table) {
			display: block;
			overflow-x: auto;
			white-space: normal;
		}

		:global(.legal-content th),
		:global(.legal-content td) {
			min-width: 150px;
		}

		:global(.legal-content .legal-cards) {
			grid-template-columns: 1fr;
		}
	}

	@media (max-width: 480px) {
		.back-link {
			font-size: 0;
		}

		.back-link :global(svg) {
			width: 18px;
			height: 18px;
		}

		.legal-description {
			font-size: 15px;
		}

		.legal-footer {
			align-items: flex-start;
			flex-direction: column;
			gap: 14px;
		}
	}
</style>
