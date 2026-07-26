<script lang="ts">
	import { onMount } from 'svelte';
	import ArrowDownIcon from '@lucide/svelte/icons/arrow-down';
	import ArrowRightIcon from '@lucide/svelte/icons/arrow-right';
	import ArrowUpRightIcon from '@lucide/svelte/icons/arrow-up-right';
	import CheckCircleIcon from '@lucide/svelte/icons/check-circle-2';
	import DownloadIcon from '@lucide/svelte/icons/download';
	import FileTextIcon from '@lucide/svelte/icons/file-text';
	import GlobeIcon from '@lucide/svelte/icons/globe-2';
	import HeadphonesIcon from '@lucide/svelte/icons/headphones';
	import LaptopIcon from '@lucide/svelte/icons/laptop';
	import LinkIcon from '@lucide/svelte/icons/link-2';
	import LockIcon from '@lucide/svelte/icons/lock-keyhole';
	import MessageIcon from '@lucide/svelte/icons/message-circle';
	import MonitorIcon from '@lucide/svelte/icons/monitor';
	import PlayIcon from '@lucide/svelte/icons/play';
	import RotateCcwIcon from '@lucide/svelte/icons/rotate-ccw';
	import RssIcon from '@lucide/svelte/icons/rss';
	import SearchIcon from '@lucide/svelte/icons/search';
	import SmartphoneIcon from '@lucide/svelte/icons/smartphone';
	import SparklesIcon from '@lucide/svelte/icons/sparkles';
	import TerminalIcon from '@lucide/svelte/icons/terminal';
	import VolumeIcon from '@lucide/svelte/icons/volume-2';
	import {
		beginBrieflyPlusCheckout,
		formatMonthlyPrice,
		loadBillingStatus,
		openBillingPortal,
		type BillingStatus,
		type PricingTier
	} from '$lib/billing.js';

	type SourceCard = {
		id: string;
		kind: string;
		title: string;
		source: string;
		meta: string;
		x: number;
		y: number;
		rotate: number;
		tone: string;
	};

	const sourceCards: SourceCard[] = [
		{
			id: 'youtube',
			kind: 'YouTube',
			title: 'Intro to Large Language Models',
			source: 'Andrej Karpathy',
			meta: '1:00:18 · Video',
			x: 84,
			y: 18,
			rotate: 5,
			tone: 'red'
		},
		{
			id: 'arxiv',
			kind: 'arXiv',
			title: 'Attention Is All You Need',
			source: 'Vaswani et al.',
			meta: 'arXiv:1706.03762',
			x: 58,
			y: 16,
			rotate: -5,
			tone: 'orange'
		},
		{
			id: 'x',
			kind: 'X',
			title: 'Notes on “vibe coding”',
			source: '@karpathy',
			meta: 'Post · Feb 2025',
			x: 92,
			y: 42,
			rotate: -7,
			tone: 'ink'
		},
		{
			id: 'blog',
			kind: 'Blog',
			title: 'The Illustrated Transformer',
			source: 'Jay Alammar',
			meta: '12 min read',
			x: 69,
			y: 35,
			rotate: 4,
			tone: 'teal'
		},
		{
			id: 'podcast',
			kind: 'Podcast',
			title: 'Machines of Loving Grace',
			source: 'Dwarkesh Podcast',
			meta: '2:02:07 · Audio',
			x: 83,
			y: 77,
			rotate: -4,
			tone: 'purple'
		},
		{
			id: 'pdf',
			kind: 'PDF',
			title: 'Constitutional AI: Harmlessness from AI Feedback',
			source: 'Anthropic',
			meta: '22 pages',
			x: 53,
			y: 64,
			rotate: 6,
			tone: 'blue'
		},
		{
			id: 'newsletter',
			kind: 'Newsletter',
			title: 'Centaurs and Cyborgs on the Jagged Frontier',
			source: 'One Useful Thing',
			meta: '14 min read',
			x: 28,
			y: 80,
			rotate: -6,
			tone: 'teal'
		},
		{
			id: 'web',
			kind: 'Web page',
			title: 'What Is ChatGPT Doing … and Why Does It Work?',
			source: 'Stephen Wolfram',
			meta: '35 min read',
			x: 18,
			y: 63,
			rotate: 5,
			tone: 'blue'
		},
		{
			id: 'notes',
			kind: 'Notes',
			title: 'Designing reliable scientific data pipelines',
			source: 'Private Briefly note',
			meta: '6 highlights',
			x: 40,
			y: 41,
			rotate: -4,
			tone: 'ink'
		},
		{
			id: 'report',
			kind: 'Report',
			title: 'The 2025 AI Index Report',
			source: 'Stanford HAI',
			meta: '456 pages',
			x: 94,
			y: 86,
			rotate: 5,
			tone: 'orange'
		},
		{
			id: 'github',
			kind: 'Code',
			title: 'The Annotated Transformer',
			source: 'Harvard NLP',
			meta: 'Notebook · PyTorch',
			x: 12,
			y: 88,
			rotate: -3,
			tone: 'ink'
		},
		{
			id: 'research',
			kind: 'Research',
			title: 'Cell–cell communication workflows',
			source: 'Private Briefly library',
			meta: '4 related sources',
			x: 43,
			y: 12,
			rotate: 4,
			tone: 'purple'
		}
	];

	const depthOptions = [
		{
			label: 'Brief',
			time: '20 sec',
			image: '/product-ui-brief.png',
			copy: 'Agent memory works best when context is curated, structured, and easy to retrieve.'
		},
		{
			label: 'Concise',
			time: '2 min',
			image: '/product-ui-concise.png',
			copy: 'Strong memory systems do more than store information. They compress useful context, preserve source links, and make the right detail easy to retrieve at the moment it matters.'
		},
		{
			label: 'Detailed',
			time: '7 min',
			image: '/product-ui-detailed.png',
			copy: 'Agent memory is less a storage problem than a context-design problem. Useful systems decide what to retain, how to structure it, and which level of detail fits the task. Clear summaries, durable source links, and predictable Markdown give both people and agents a reliable surface to work from.'
		},
		{
			label: 'Comprehensive',
			time: '18 min',
			image: '/product-ui-comprehensive.png',
			copy: 'A complete reading view preserves the source argument, supporting details, and practical implications while keeping the material navigable. Structured headings help an agent locate evidence; a stable original keeps the human reader grounded. The result is not another pile of notes, but a reusable context layer that can move from quick recall to deep work without losing provenance.'
		}
	];

	type Platform = 'mac' | 'windows' | 'linux' | 'pwa';

	const downloadBase =
		'https://github.com/jonsch1/briefly-downloads/releases/latest/download';
	const desktopDownloads = {
		mac: {
			label: 'Download free for Mac',
			href: `${downloadBase}/Briefly-mac-universal.dmg`
		},
		windows: {
			label: 'Download free for Windows',
			href: `${downloadBase}/Briefly-windows-x64.exe`
		},
		linux: {
			label: 'Download free for Linux',
			href: `${downloadBase}/Briefly-linux-x64.AppImage`
		},
		pwa: {
			label: 'Use the free web app',
			href: '/'
		}
	} satisfies Record<Platform, { label: string; href: string }>;

	const defaultPricingTiers: PricingTier[] = [
		{
			key: 'founding',
			name: 'Founding',
			amount: 399,
			currency: 'eur',
			capacity: 50,
			claimed: 0,
			remaining: 50,
			current: true
		},
		{
			key: 'early',
			name: 'Early',
			amount: 599,
			currency: 'eur',
			capacity: 100,
			claimed: 0,
			remaining: 100,
			current: false
		},
		{
			key: 'growing',
			name: 'Growing',
			amount: 799,
			currency: 'eur',
			capacity: 250,
			claimed: 0,
			remaining: 250,
			current: false
		},
		{
			key: 'standard',
			name: 'Standard',
			amount: 999,
			currency: 'eur',
			capacity: null,
			claimed: 0,
			remaining: null,
			current: false
		}
	];

	let selectedDepth = $state(1);
	let collectedCount = $state(0);
	let fieldComplete = $state(false);
	let detectedPlatform = $state<Platform>('pwa');
	let resetSweep = (): void => {};
	let billing = $state<BillingStatus | null>(null);
	let billingBusy = $state(false);
	let billingMessage = $state('');
	let preferredDownload = $derived(desktopDownloads[detectedPlatform]);
	let displayedPricingTiers = $derived(billing?.tiers ?? defaultPricingTiers);
	let currentPricingTier = $derived(
		displayedPricingTiers.find((tier) => tier.current) ?? displayedPricingTiers.at(-1)!
	);

	async function initializePricing(): Promise<void> {
		try {
			billing = await loadBillingStatus();
			const url = new URL(window.location.href);
			if (url.searchParams.get('billing') === 'cancelled') {
				billingMessage = 'Checkout was cancelled. Your place was not charged.';
				url.searchParams.delete('billing');
			}
			const continueCheckout = url.searchParams.get('checkout') === 'plus';
			if (continueCheckout) url.searchParams.delete('checkout');
			window.history.replaceState({}, '', `${url.pathname}${url.search}${url.hash}`);
			if (continueCheckout && billing.authenticated) await startCheckout();
		} catch (error) {
			billingMessage =
				error instanceof Error ? error.message : 'Briefly Plus pricing could not be loaded.';
		}
	}

	async function startCheckout(): Promise<void> {
		if (billingBusy) return;
		billingBusy = true;
		billingMessage = '';
		try {
			await beginBrieflyPlusCheckout();
		} catch (error) {
			const checkoutError = error as Error & { code?: string };
			if (checkoutError.code === 'authentication_required') {
				const returnTo = encodeURIComponent('/landing?checkout=plus#pricing');
				window.location.assign(`/api/auth/google/start?return_to=${returnTo}`);
				return;
			}
			if (checkoutError.code === 'subscription_exists') {
				await openBillingPortal();
				return;
			}
			billingMessage = checkoutError.message;
		} finally {
			billingBusy = false;
		}
	}

	async function manageBilling(): Promise<void> {
		if (billingBusy) return;
		billingBusy = true;
		billingMessage = '';
		try {
			await openBillingPortal();
		} catch (error) {
			billingMessage =
				error instanceof Error ? error.message : 'The billing portal could not be opened.';
		} finally {
			billingBusy = false;
		}
	}

	onMount(() => {
		document.body.classList.add('landing-body');
		void initializePricing();
		const userAgent = navigator.userAgent.toLowerCase();
		detectedPlatform = /iphone|ipad|android/.test(userAgent)
			? 'pwa'
			: /macintosh|mac os x/.test(userAgent)
				? 'mac'
				: /windows/.test(userAgent)
					? 'windows'
					: /linux/.test(userAgent)
						? 'linux'
						: 'pwa';

		const observer = new IntersectionObserver(
			(entries) => {
				for (const entry of entries) {
					if (entry.isIntersecting) entry.target.classList.add('is-visible');
				}
			},
			{ threshold: 0.14 }
		);

		document.querySelectorAll('.reveal').forEach((element) => observer.observe(element));

		const arena = document.querySelector<HTMLElement>('[data-sweep-arena]');
		const collector = document.querySelector<HTMLElement>('[data-sweep-collector]');
		const cards = Array.from(document.querySelectorAll<HTMLElement>('[data-source-card]'));
		const reduceMotion = window.matchMedia('(prefers-reduced-motion: reduce)').matches;
		let animationFrame = 0;
		let heroObserver: IntersectionObserver | null = null;
		let heroInView = true;
		let pointerSeen = false;
		let impact = 0;
		let collectorX = 0;
		let collectorY = 0;
		let targetX = 0;
		let targetY = 0;

		const motion = cards.map((element, index) => ({
			element,
			homeX: 0,
			homeY: 0,
			x: 0,
			y: 0,
			vx: 0,
			vy: 0,
			rotation: sourceCards[index].rotate,
			scale: 1,
			opacity: 1,
			collected: false
		}));

		const placeCard = (item: (typeof motion)[number]): void => {
			item.element.style.left = '0';
			item.element.style.top = '0';
			item.element.style.opacity = `${item.opacity}`;
			item.element.style.filter = item.scale < 0.7 ? `blur(${(1 - item.scale) * 4}px)` : '';
			item.element.style.transform = `translate3d(${item.x}px, ${item.y}px, 0) translate(-50%, -50%) rotate(${item.rotation}deg) scale(${item.scale})`;
		};

		const layoutSweep = (): void => {
			if (!arena || !collector) return;
			const bounds = arena.getBoundingClientRect();
			if (!collectorX && !collectorY) {
				collectorX = bounds.width * 0.78;
				collectorY = bounds.height * 0.58;
				targetX = collectorX;
				targetY = collectorY;
			}

			motion.forEach((item, index) => {
				const wasAtHome = Math.abs(item.x - item.homeX) < 4 && Math.abs(item.y - item.homeY) < 4;
				item.homeX = bounds.width * sourceCards[index].x * 0.01;
				item.homeY = bounds.height * sourceCards[index].y * 0.01;
				if (wasAtHome || (!item.x && !item.y)) {
					item.x = item.homeX;
					item.y = item.homeY;
					placeCard(item);
				}
			});
		};

		const collect = (item: (typeof motion)[number]): void => {
			if (!collector || item.collected) return;
			item.collected = true;
			item.vx = 0;
			item.vy = 0;
			item.scale = 0.04;
			item.opacity = 0;
			item.element.classList.add('is-absorbing');
			item.element.style.opacity = '0';
			item.element.style.filter = 'blur(7px)';
			item.element.style.transform = `translate3d(${collectorX}px, ${collectorY}px, 0) translate(-50%, -50%) rotate(0deg) scale(0.04)`;
			collectedCount += 1;
			impact = Math.min(0.28, impact + 0.18);
			collector.classList.remove('has-impact');
			void collector.offsetWidth;
			collector.classList.add('has-impact');
			fieldComplete = collectedCount === sourceCards.length;
		};

		resetSweep = (): void => {
			if (!arena || !collector) return;
			const bounds = arena.getBoundingClientRect();
			collectedCount = 0;
			fieldComplete = false;
			pointerSeen = false;
			impact = 0;
			targetX = bounds.width * 0.78;
			targetY = bounds.height * 0.58;
			collectorX = targetX;
			collectorY = targetY;
			collector.classList.remove('has-impact', 'is-attracting');
			motion.forEach((item) => {
				item.collected = false;
				item.x = item.homeX;
				item.y = item.homeY;
				item.vx = 0;
				item.vy = 0;
				item.rotation = sourceCards[motion.indexOf(item)].rotate;
				item.scale = 1;
				item.opacity = 1;
				item.element.classList.remove('is-absorbing');
				item.element.style.transition = '';
				placeCard(item);
			});
		};

		const setTarget = (event: PointerEvent): void => {
			if (!arena) return;
			const bounds = arena.getBoundingClientRect();
			targetX = Math.max(0, Math.min(bounds.width, event.clientX - bounds.left));
			targetY = Math.max(0, Math.min(bounds.height, event.clientY - bounds.top));
			pointerSeen = true;
			arena.classList.add('has-pointer');
		};

		const returnCollector = (): void => {
			if (!arena) return;
			const bounds = arena.getBoundingClientRect();
			targetX = bounds.width * 0.78;
			targetY = bounds.height * 0.58;
		};

		const handleSweepShortcut = (event: KeyboardEvent): void => {
			const target = event.target as HTMLElement | null;
			if (
				event.key.toLowerCase() !== 'r' ||
				event.metaKey ||
				event.ctrlKey ||
				event.altKey ||
				!heroInView ||
				target?.matches('input, textarea, select, [contenteditable="true"]')
			) {
				return;
			}
			event.preventDefault();
			resetSweep();
		};

		const animate = (): void => {
			if (!arena || !collector) return;
			if (!heroInView || document.hidden || reduceMotion) {
				animationFrame = window.requestAnimationFrame(animate);
				return;
			}
			const pullRadius = Math.max(135, Math.min(190, arena.clientWidth * 0.13));
			const absorbRadius = Math.max(68, Math.min(88, arena.clientWidth * 0.06));
			let attracting = false;

			collectorX += (targetX - collectorX) * 0.2;
			collectorY += (targetY - collectorY) * 0.2;
			impact *= 0.86;

			if (pointerSeen && !reduceMotion) {
				for (const item of motion) {
					if (item.collected) continue;
					const dx = collectorX - item.x;
					const dy = collectorY - item.y;
					const distance = Math.hypot(dx, dy);

					if (distance < pullRadius) {
						const force = 1 - distance / pullRadius;
						attracting = true;
						item.vx += dx * (0.015 + force * 0.055);
						item.vy += dy * (0.015 + force * 0.055);
						item.rotation *= 0.88;
						item.scale = Math.max(0.2, item.scale - force * 0.04);
						item.opacity = Math.max(0.35, item.opacity - force * 0.025);
					} else {
						item.vx += (item.homeX - item.x) * 0.012;
						item.vy += (item.homeY - item.y) * 0.012;
						item.rotation +=
							(sourceCards[motion.indexOf(item)].rotate - item.rotation) * 0.045;
						item.scale += (1 - item.scale) * 0.07;
						item.opacity += (1 - item.opacity) * 0.1;
					}

					item.vx *= 0.82;
					item.vy *= 0.82;
					item.x += item.vx;
					item.y += item.vy;

					if (distance < absorbRadius) {
						collect(item);
					} else {
						placeCard(item);
					}
				}
			}

			collector.classList.toggle('is-attracting', attracting);
			const persistentGrowth = Math.min(0.15, collectedCount * 0.0125);
			const tilt = Math.max(-4, Math.min(4, (targetX - collectorX) * 0.025));
			collector.style.transform = `translate3d(${collectorX}px, ${collectorY}px, 0) translate(-50%, -50%) rotate(${tilt}deg) scale(${1 + persistentGrowth + impact})`;
			animationFrame = window.requestAnimationFrame(animate);
		};

		if (arena && collector) {
			layoutSweep();
			heroObserver = new IntersectionObserver(
				([entry]) => {
					heroInView = entry?.isIntersecting ?? true;
				},
				{ threshold: 0 }
			);
			heroObserver.observe(arena);

			if (!reduceMotion) {
				arena.addEventListener('pointermove', setTarget, { passive: true });
				arena.addEventListener('pointerdown', setTarget, { passive: true });
				arena.addEventListener('pointerleave', returnCollector, { passive: true });
			}
			window.addEventListener('resize', layoutSweep, { passive: true });
			window.addEventListener('keydown', handleSweepShortcut);
			animationFrame = window.requestAnimationFrame(animate);
		}

		return () => {
			observer.disconnect();
			document.body.classList.remove('landing-body');
			window.cancelAnimationFrame(animationFrame);
			heroObserver?.disconnect();
			arena?.removeEventListener('pointermove', setTarget);
			arena?.removeEventListener('pointerdown', setTarget);
			arena?.removeEventListener('pointerleave', returnCollector);
			window.removeEventListener('resize', layoutSweep);
			window.removeEventListener('keydown', handleSweepShortcut);
		};
	});
</script>

<svelte:head>
	<title>Briefly — Turn what you find into what you know</title>
	<meta
		name="description"
		content="Capture videos, papers, posts, podcasts, and pages for free. Briefly turns every source into a private, searchable, agent-ready library. Upgrade for sync and sharing."
	/>
	<meta property="og:type" content="website" />
	<meta property="og:title" content="Briefly — Turn what you find into what you know" />
	<meta
		property="og:description"
		content="Capture anything. Understand it at any depth. Keep the context ready for you and your agents."
	/>
	<meta property="og:url" content="https://www.readbriefly.fyi/landing" />
	<meta property="og:image" content="https://www.readbriefly.fyi/og-landing-free.png" />
	<meta name="twitter:card" content="summary_large_image" />
	<meta name="twitter:title" content="Briefly — Turn what you find into what you know" />
	<meta
		name="twitter:description"
		content="Your private, searchable, agent-ready library."
	/>
	<meta name="twitter:image" content="https://www.readbriefly.fyi/og-landing-free.png" />
</svelte:head>

<div class="landing">
	<header class="landing-nav">
		<a class="landing-brand" href="/landing" aria-label="Briefly home">
			<img src="/icons/icon-192.png" alt="" />
			<span>Briefly</span>
		</a>

		<nav aria-label="Main navigation">
			<a href="#how">How it works</a>
			<a href="#depth">Four depths</a>
			<a href="#agents">For agents</a>
			<a href="#pricing">Pricing</a>
			<a href="#get-briefly">Downloads</a>
		</nav>

		<a class="nav-cta" href="#get-briefly">
			Get Briefly
			<DownloadIcon aria-hidden="true" />
		</a>
	</header>

	<main>
		<section class="hero-scroll">
			<div class="hero-sticky" data-sweep-arena>
				<div class="hero-grid" aria-hidden="true"></div>

				<div class="hero-copy">
					<h1>Turn what you find<br />into what you know.</h1>
					<p>
						Capture any source in seconds. Briefly turns the internet into a private,
						searchable library—ready for you and your agents.
					</p>
					<div class="hero-actions">
						<a class="button button-primary" href={preferredDownload.href}>
							{preferredDownload.label}
							<DownloadIcon aria-hidden="true" />
						</a>
						<a class="text-link" href="#how">
							See how it works
							<ArrowDownIcon aria-hidden="true" />
						</a>
					</div>
					<div class="hero-free-note">
						<CheckCircleIcon aria-hidden="true" />
						Core app free · sync + sharing with Briefly Plus
					</div>
				</div>

				<div class="gather-stage" aria-hidden="true">
					<div class="gather-logo" data-sweep-collector>
						<span class="logo-halo"></span>
						<span class="intake-ring intake-ring-one"></span>
						<span class="intake-ring intake-ring-two"></span>
						<img src="/icons/icon-512.png" alt="" />
					</div>

					{#each sourceCards as card}
						<article
							class="source-card source-card-{card.tone}"
							data-source-card
							style={`left:${card.x}%;top:${card.y}%;--rotate:${card.rotate}deg`}
						>
							<div class="source-topline">
								<span class="source-icon">
									{#if card.id === 'youtube'}
										<PlayIcon />
									{:else if card.id === 'arxiv' || card.id === 'pdf' || card.id === 'report'}
										<FileTextIcon />
									{:else if card.id === 'x'}
										<MessageIcon />
									{:else if card.id === 'blog' || card.id === 'newsletter'}
										<RssIcon />
									{:else if card.id === 'podcast'}
										<HeadphonesIcon />
									{:else}
										<GlobeIcon />
									{/if}
								</span>
								<span>{card.kind}</span>
								<span class="source-grip"><i></i><i></i><i></i></span>
							</div>
							<strong>{card.title}</strong>
							<span class="source-author">{card.source}</span>
							<small>{card.meta}</small>
						</article>
					{/each}
				</div>

				<div class="sweep-status" class:is-complete={fieldComplete} aria-live="polite">
					<div>
						<span class="sweep-count">{collectedCount} / {sourceCards.length}</span>
						<span>{fieldComplete ? 'Your page is clean' : 'Sweep over a source to gather it'}</span>
					</div>
					{#if fieldComplete}
						<button type="button" onclick={() => resetSweep()}>
							<RotateCcwIcon aria-hidden="true" />
							Scatter again
							<kbd>R</kbd>
						</button>
					{:else}
						<span class="sweep-hint">
							The Briefly mark is your cursor · <kbd>R</kbd> resets
						</span>
					{/if}
				</div>

				<div class="scroll-cue">
					<span>Scroll to explore</span>
					<div class="scroll-track"><i></i></div>
				</div>
			</div>
		</section>

		<section class="source-marquee" aria-label="Supported source types">
			<div class="marquee-track">
				{#each Array(2) as _}
					<div class="marquee-set" aria-hidden="true">
						<span>YouTube</span><i></i>
						<span>arXiv</span><i></i>
						<span>Podcasts</span><i></i>
						<span>Blog posts</span><i></i>
						<span>X posts</span><i></i>
						<span>PDFs</span><i></i>
						<span>Any URL</span><i></i>
						<span>Your notes</span><i></i>
					</div>
				{/each}
			</div>
		</section>

		<section class="attention-section section-shell">
			<div class="section-number reveal">01 / WHY BRIEFLY</div>
			<div class="attention-grid">
				<h2 class="display-heading reveal">
					The best thing you read this week shouldn’t disappear by Friday.
				</h2>
				<div class="attention-copy reveal">
					<p>
						The internet is excellent at giving you more. It is terrible at helping you keep
						what mattered.
					</p>
					<p>
						Briefly turns scattered sources into durable understanding—without another
						inbox to triage or a note-taking ritual to maintain.
					</p>
					<div class="proof-note">
						<span class="proof-icon"><CheckCircleIcon /></span>
						<div>
							<strong>Save once. Use repeatedly.</strong>
							<small>Your context stays searchable, readable, and ready to work.</small>
						</div>
					</div>
				</div>
			</div>
		</section>

		<section class="flow-section" id="how">
			<div class="flow-heading section-shell reveal">
				<div>
					<div class="section-number">02 / THE FLOW</div>
					<h2>From open tab<br />to useful context.</h2>
				</div>
				<p>
					One shortcut captures the source. Briefly handles the structure, depth, and
					retrievability.
				</p>
			</div>

			<figure class="flow-visual reveal">
				<img
					src="/briefly-flow-v2.webp"
					alt="YouTube videos, arXiv papers, blog posts, and podcasts flow through Briefly into four reading depths and agent-ready Markdown."
				/>
				<figcaption>
					<span>Capture any source</span>
					<i aria-hidden="true"></i>
					<span>Choose the useful depth</span>
					<i aria-hidden="true"></i>
					<span>Keep clean, agent-ready context</span>
				</figcaption>
			</figure>

			<div class="steps-grid section-shell">
				<article class="step-card reveal">
					<span>01</span>
					<div class="step-icon"><LinkIcon /></div>
					<h3>Capture</h3>
					<p>Copy anything worth keeping. One shortcut gets it out of your tabs.</p>
				</article>
				<article class="step-card reveal">
					<span>02</span>
					<div class="step-icon"><SparklesIcon /></div>
					<h3>Clarify</h3>
					<p>Briefly extracts the signal and writes every useful level of detail.</p>
				</article>
				<article class="step-card reveal">
					<span>03</span>
					<div class="step-icon"><SearchIcon /></div>
					<h3>Connect</h3>
					<p>Find it, read it, hear it, share it, or give it to an agent.</p>
				</article>
			</div>
		</section>

		<section class="depth-section section-shell" id="depth">
			<div class="depth-copy reveal">
				<div class="section-number">03 / ONE SOURCE, FOUR DEPTHS</div>
				<h2>Go from the gist<br />to the whole thing.</h2>
				<p>
					Not every source deserves an hour. Not every question can be answered in a sentence.
					Choose exactly how deep you want to go.
				</p>
				<div class="listen-chip"><VolumeIcon /> Every level can be read aloud</div>
			</div>

			<div class="product-demo reveal">
				<div class="product-demo-toolbar">
					<div>
						<span class="live-dot"></span>
						Real Briefly interface
					</div>
					<span>{depthOptions[selectedDepth].time} read</span>
				</div>

				<div class="product-screenshot" aria-live="polite">
					<img
						src={depthOptions[selectedDepth].image}
						alt={`The actual Briefly library and reader interface showing the ${depthOptions[selectedDepth].label.toLowerCase()} reading depth`}
					/>
				</div>

				<div class="product-depth-picker" role="tablist" aria-label="Preview reading depth">
					{#each depthOptions as option, index}
						<button
							type="button"
							class:active={selectedDepth === index}
							role="tab"
							aria-selected={selectedDepth === index}
							onclick={() => (selectedDepth = index)}
						>
							<span>{index + 1}</span>
							{option.label}
						</button>
					{/each}
				</div>

				<p class="product-demo-caption">
					No concept render: this is the current Briefly app using its built-in sample library.
				</p>
			</div>
		</section>

		<section class="agents-section" id="agents">
			<div class="agents-inner section-shell">
				<div class="agents-copy reveal">
					<div class="agents-heading">
						<div class="section-number">04 / YOU + YOUR AGENTS</div>
						<h2>One workspace.<br />Shared context.</h2>
					</div>
					<div class="agents-story">
						<p>
							Briefly gives you and every agent one place to research, understand, and create.
							They can build on what you know, investigate further, and leave the useful work
							in your hands.
						</p>
						<ul>
							<li><CheckCircleIcon /> Research with everything you have already saved</li>
							<li><CheckCircleIcon /> Give any agent the context to continue</li>
							<li><CheckCircleIcon /> Keep the insights, drafts, and decisions</li>
						</ul>
						<a class="button button-light" href="/">
							Start your shared workspace
							<ArrowRightIcon aria-hidden="true" />
						</a>
					</div>
				</div>

				<figure class="agents-visual reveal">
					<img
						src="/briefly-agent-workspace.webp"
						alt="Claude Code, Codex, OpenCode, and Pi connect to the same Briefly workspace to produce research, insights, and drafts."
						width="1672"
						height="941"
						loading="lazy"
						decoding="async"
					/>
					<figcaption>
						<span>You and your agents, working from the same place.</span>
						<span>Research · insight · useful work</span>
					</figcaption>
				</figure>
			</div>
		</section>

		<section class="privacy-section section-shell">
			<div class="privacy-heading reveal">
				<div class="section-number">05 / YOURS MEANS YOURS</div>
				<h2>Local when you want it. Shared when you choose.</h2>
			</div>
			<div class="privacy-grid">
				<article class="reveal">
					<div class="privacy-icon"><LockIcon /></div>
					<h3>Private by default</h3>
					<p>Your free library stays in your own local workspace until you choose otherwise.</p>
				</article>
				<article class="reveal">
					<div class="privacy-icon"><GlobeIcon /></div>
					<h3>Offline when you need it</h3>
					<p>Capture, search, and read your library locally—even when the connection does not.</p>
				</article>
				<article class="reveal">
					<div class="privacy-icon"><ArrowUpRightIcon /></div>
					<h3>Shared on purpose</h3>
					<p>Briefly Plus adds cross-device sync and deliberate share links when you need them.</p>
				</article>
			</div>
		</section>

		<section class="downloads-section" id="get-briefly">
			<div class="downloads-inner section-shell">
				<div class="downloads-heading reveal">
					<div class="section-number">06 / GET BRIEFLY</div>
					<h2>One library.<br />Every screen.</h2>
					<p>
						Briefly’s core capture, reading, and local library are free. Add Plus only when
						you want your library synchronized and shareable.
					</p>
				</div>

				<div class="plan-strip reveal" id="pricing">
					<article class="plan-card plan-free">
						<div class="plan-card-top">
							<span>Briefly Free</span>
							<strong>Free</strong>
						</div>
						<h3>Everything you need to turn sources into knowledge.</h3>
						<ul>
							<li><CheckCircleIcon /> Capture links, files, and notes</li>
							<li><CheckCircleIcon /> Four reading depths + read aloud</li>
							<li><CheckCircleIcon /> Local, searchable Markdown library</li>
						</ul>
					</article>
					<article class="plan-card plan-plus">
						<div class="plan-card-top">
							<span>Briefly Plus</span>
							<strong>{formatMonthlyPrice(currentPricingTier.amount)}/month</strong>
						</div>
						<h3>Join earlier. Keep the lower price.</h3>
						<p class="plan-plus-intro">
							Your monthly price stays fixed while your subscription remains active.
						</p>
						<div class="pricing-ladder" aria-label="Briefly Plus launch pricing">
							{#each displayedPricingTiers as tier}
								<div class:current={tier.current} class:past={!tier.current && tier.remaining === 0}>
									<span>
										<b>{tier.name}</b>
										<small>
											{tier.capacity === null
												? 'Stable price'
												: `${tier.capacity} subscriber${tier.capacity === 1 ? '' : 's'}`}
										</small>
									</span>
									<strong>{formatMonthlyPrice(tier.amount)}</strong>
									{#if tier.current}
										<em>
											{tier.remaining === null
												? 'Current'
												: `${tier.remaining} left`}
										</em>
									{:else if tier.remaining === 0}
										<em>Filled</em>
									{/if}
								</div>
							{/each}
						</div>
						<ul>
							<li><CheckCircleIcon /> Sync your library across devices</li>
							<li><CheckCircleIcon /> Share clean, deliberate reading links</li>
							<li><CheckCircleIcon /> First month's payment matched in AI voice credit</li>
							<li><CheckCircleIcon /> Everything included in Briefly Free</li>
						</ul>
						{#if billing?.entitled && billing.subscription}
							<button
								class="pricing-cta"
								type="button"
								disabled={billingBusy}
								onclick={manageBilling}
							>
								{billingBusy ? 'Opening billing…' : 'Manage billing'}
								<ArrowUpRightIcon aria-hidden="true" />
							</button>
						{:else}
							<button
								class="pricing-cta"
								type="button"
								disabled={billingBusy || billing?.configured === false}
								onclick={startCheckout}
							>
								{billingBusy
									? 'Opening secure checkout…'
									: billing?.configured === false
										? 'Checkout setup pending'
										: `Lock in ${formatMonthlyPrice(currentPricingTier.amount)}/month`}
								<ArrowRightIcon aria-hidden="true" />
							</button>
						{/if}
						<p class="pricing-note">
							Cancel anytime · Taxes calculated at checkout · Secure checkout by Stripe<br />
							By subscribing, you agree to the <a href="/terms">Terms</a> and acknowledge the
							<a href="/privacy">Privacy Notice</a>.
						</p>
						{#if billingMessage}
							<p class="pricing-message" role="status">{billingMessage}</p>
						{/if}
					</article>
				</div>

				<div class="download-grid">
					<article class="download-card reveal" class:preferred={detectedPlatform === 'mac'}>
						<div class="download-card-top">
							<div class="platform-icon"><LaptopIcon /></div>
							{#if detectedPlatform === 'mac'}<span class="preferred-pill">Best for this device</span>{/if}
						</div>
						<div>
							<p>Desktop · Free</p>
							<h3>macOS</h3>
							<span>Universal build for Apple silicon and Intel.</span>
						</div>
						<a href={desktopDownloads.mac.href}>
							<DownloadIcon />
							Free download · .dmg
						</a>
					</article>

					<article class="download-card reveal" class:preferred={detectedPlatform === 'windows'}>
						<div class="download-card-top">
							<div class="platform-icon"><MonitorIcon /></div>
							{#if detectedPlatform === 'windows'}<span class="preferred-pill">Best for this device</span>{/if}
						</div>
						<div>
							<p>Desktop · Free</p>
							<h3>Windows</h3>
							<span>64-bit installer for Windows PCs.</span>
						</div>
						<a href={desktopDownloads.windows.href}>
							<DownloadIcon />
							Free download · .exe
						</a>
					</article>

					<article class="download-card reveal" class:preferred={detectedPlatform === 'linux'}>
						<div class="download-card-top">
							<div class="platform-icon"><TerminalIcon /></div>
							{#if detectedPlatform === 'linux'}<span class="preferred-pill">Best for this device</span>{/if}
						</div>
						<div>
							<p>Desktop · Free</p>
							<h3>Linux</h3>
							<span>Portable AppImage or Debian / Ubuntu package.</span>
						</div>
						<div class="linux-actions">
							<a href={desktopDownloads.linux.href}>
								<DownloadIcon />
								AppImage
							</a>
							<a href={`${downloadBase}/Briefly-linux-amd64.deb`}>.deb</a>
						</div>
					</article>

					<article class="download-card pwa-card reveal" class:preferred={detectedPlatform === 'pwa'}>
						<div class="download-card-top">
							<div class="platform-icon"><SmartphoneIcon /></div>
							<span class="pwa-pill">No app store needed</span>
						</div>
						<div>
							<p>Phone + tablet · Free</p>
							<h3>Progressive web app</h3>
							<span>Install from Safari or Chrome and launch Briefly from your home screen.</span>
						</div>
						<a href="/">
							<GlobeIcon />
							Open the web app
						</a>
						<ol>
							<li><b>iPhone / iPad:</b> Share → Add to Home Screen</li>
							<li><b>Android:</b> Browser menu → Install app</li>
						</ol>
					</article>
				</div>

				<div class="download-footnote reveal">
					<CheckCircleIcon />
					<span>
						The core Briefly app is free on every platform. Briefly Plus adds Google Drive
						sync and sharing. Desktop builds are in public beta, so your operating system may
						ask you to confirm the first launch.
					</span>
				</div>
			</div>
		</section>

		<section class="final-cta">
			<div class="final-orbit orbit-one" aria-hidden="true"></div>
			<div class="final-orbit orbit-two" aria-hidden="true"></div>
			<div class="final-sources" aria-hidden="true">
				<span><PlayIcon /></span>
				<span><FileTextIcon /></span>
				<span><HeadphonesIcon /></span>
				<span><RssIcon /></span>
			</div>
			<div class="final-content reveal">
				<img src="/icons/icon-192.png" alt="" />
				<p>THE INTERNET IS ENDLESS. YOUR ATTENTION ISN’T.</p>
				<h2>Keep the parts<br />worth knowing.</h2>
				<a class="button button-white" href={preferredDownload.href}>
					{preferredDownload.label}
					<DownloadIcon aria-hidden="true" />
				</a>
				<span class="final-note">Free on Mac · Windows · Linux · Installable web app</span>
			</div>
		</section>
	</main>

	<footer class="landing-footer">
		<a class="landing-brand" href="/landing">
			<img src="/icons/icon-192.png" alt="" />
			<span>Briefly</span>
		</a>
		<p>Turn what you find into what you know.</p>
		<div>
			<a href="/">Open app</a>
			<a href="#get-briefly">Downloads</a>
			<a class="footer-legal" href="/privacy">Privacy</a>
			<a class="footer-legal" href="/terms">Terms</a>
			<a class="footer-legal" href="/cookies">Cookies</a>
			<a class="footer-legal" href="/imprint">Imprint</a>
			<span>© 2026 Briefly</span>
		</div>
	</footer>
</div>

<style>
	:global(html) {
		scroll-behavior: smooth;
	}

	:global(body.landing-body),
	:global(body:has(.landing)) {
		overflow-x: hidden;
		overflow-y: auto;
		background: #f3efe5;
		color: #11110f;
	}

	:global(body.landing-body *) {
		box-sizing: border-box;
	}

	.landing {
		--paper: #f3efe5;
		--paper-bright: #fbf8f0;
		--ink: #11110f;
		--blue: #164dff;
		--blue-deep: #071a54;
		--blue-black: #020a24;
		--line: rgb(17 17 15 / 18%);
		min-height: 100vh;
		overflow: clip;
		background:
			radial-gradient(circle at 50% 5%, rgb(255 255 255 / 88%), transparent 24rem),
			var(--paper);
		color: var(--ink);
		font-family: 'Inter Variable', Inter, sans-serif;
	}

	.landing a {
		color: inherit;
		text-decoration: none;
	}

	.landing button,
	.landing a {
		-webkit-tap-highlight-color: transparent;
	}

	.landing-nav {
		position: absolute;
		z-index: 100;
		top: 0;
		left: 0;
		display: grid;
		width: 100%;
		grid-template-columns: 1fr auto 1fr;
		align-items: center;
		padding: 24px clamp(22px, 4vw, 68px);
	}

	.landing-brand {
		display: inline-flex;
		width: fit-content;
		align-items: center;
		gap: 10px;
		font-size: 18px;
		font-weight: 780;
		letter-spacing: -0.04em;
	}

	.landing-brand img {
		width: 35px;
		height: 35px;
		border-radius: 10px;
		box-shadow: 0 8px 18px rgb(8 27 82 / 18%);
	}

	.landing-nav nav {
		display: flex;
		align-items: center;
		gap: clamp(22px, 3vw, 42px);
		color: rgb(17 17 15 / 68%);
		font-size: 13px;
		font-weight: 590;
	}

	.landing-nav nav a {
		position: relative;
		padding: 7px 0;
	}

	.landing-nav nav a::after {
		position: absolute;
		right: 0;
		bottom: 2px;
		left: 0;
		height: 1px;
		background: currentColor;
		content: '';
		transform: scaleX(0);
		transform-origin: right;
		transition: transform 240ms ease;
	}

	.landing-nav nav a:hover::after,
	.landing-nav nav a:focus-visible::after {
		transform: scaleX(1);
		transform-origin: left;
	}

	.nav-cta {
		display: inline-flex;
		justify-self: end;
		align-items: center;
		gap: 10px;
		padding: 11px 16px;
		border: 1px solid rgb(17 17 15 / 20%);
		border-radius: 999px;
		background: rgb(255 255 255 / 50%);
		font-size: 13px;
		font-weight: 680;
		backdrop-filter: blur(12px);
		transition:
			border-color 200ms ease,
			background 200ms ease,
			transform 200ms ease;
	}

	.nav-cta:hover {
		border-color: var(--blue);
		background: white;
		transform: translateY(-2px);
	}

	.nav-cta :global(svg) {
		width: 15px;
	}

	.hero-scroll {
		position: relative;
		height: 100svh;
		min-height: 720px;
	}

	.hero-sticky {
		position: relative;
		height: 100%;
		min-height: inherit;
		overflow: hidden;
		cursor: none;
		touch-action: pan-y;
		background:
			radial-gradient(circle at 78% 58%, rgb(22 77 255 / 14%), transparent 25%),
			linear-gradient(180deg, #fbf8f0 0%, var(--paper) 100%);
	}

	.hero-sticky * {
		cursor: none;
	}

	.hero-grid {
		position: absolute;
		inset: 0;
		background-image:
			linear-gradient(rgb(17 17 15 / 3.5%) 1px, transparent 1px),
			linear-gradient(90deg, rgb(17 17 15 / 3.5%) 1px, transparent 1px);
		background-position: center center;
		background-size: 46px 46px;
		mask-image: radial-gradient(circle at center, black, transparent 72%);
		opacity: 0.6;
	}

	.hero-copy {
		position: absolute;
		z-index: 12;
		top: clamp(132px, 18vh, 180px);
		left: clamp(24px, 5vw, 82px);
		width: min(690px, 54vw);
		text-align: left;
	}

	.hero-copy h1,
	.display-heading,
	.flow-heading h2,
	.depth-copy h2,
	.agents-copy h2,
	.privacy-heading h2,
	.final-content h2 {
		margin: 0;
		font-size: clamp(58px, 8vw, 124px);
		font-weight: 820;
		letter-spacing: -0.075em;
		line-height: 0.86;
	}

	.hero-copy p {
		max-width: 560px;
		margin: 27px 0 0;
		color: rgb(17 17 15 / 64%);
		font-size: clamp(16px, 1.5vw, 20px);
		letter-spacing: -0.025em;
		line-height: 1.5;
	}

	.hero-actions {
		display: flex;
		align-items: center;
		justify-content: flex-start;
		gap: 24px;
		margin-top: 29px;
	}

	.hero-free-note {
		display: flex;
		align-items: center;
		gap: 7px;
		margin-top: 15px;
		color: rgb(17 17 15 / 49%);
		font-size: 10px;
		font-weight: 680;
		letter-spacing: 0.015em;
	}

	.hero-free-note :global(svg) {
		width: 13px;
		color: #087253;
	}

	.button {
		display: inline-flex;
		align-items: center;
		justify-content: center;
		gap: 12px;
		min-height: 52px;
		padding: 0 22px;
		border: 0;
		border-radius: 999px;
		font-size: 14px;
		font-weight: 730;
		letter-spacing: -0.015em;
		transition:
			transform 220ms ease,
			box-shadow 220ms ease,
			background 220ms ease;
	}

	.button :global(svg) {
		width: 17px;
		transition: transform 220ms ease;
	}

	.button:hover {
		transform: translateY(-3px);
	}

	.button:hover :global(svg) {
		transform: translateX(3px);
	}

	.button-primary {
		background: var(--blue);
		color: white !important;
		box-shadow: 0 16px 35px rgb(22 77 255 / 22%);
	}

	.button-primary:hover {
		background: #0c40ec;
		box-shadow: 0 20px 45px rgb(22 77 255 / 30%);
	}

	.text-link {
		display: inline-flex;
		align-items: center;
		gap: 8px;
		font-size: 14px;
		font-weight: 680;
	}

	.text-link :global(svg) {
		width: 15px;
		transition: transform 200ms ease;
	}

	.text-link:hover :global(svg) {
		transform: translateY(3px);
	}

	.gather-stage {
		position: absolute;
		z-index: 8;
		inset: 0;
		pointer-events: none;
	}

	.gather-logo {
		position: absolute;
		z-index: 20;
		top: 0;
		left: 0;
		width: clamp(156px, 13vw, 208px);
		aspect-ratio: 1;
		transform: translate3d(78vw, 58vh, 0) translate(-50%, -50%);
		transform-origin: center;
		will-change: transform;
	}

	.gather-logo img {
		position: relative;
		z-index: 4;
		width: 100%;
		height: 100%;
		filter: drop-shadow(0 25px 28px rgb(6 24 80 / 30%));
		transition: filter 180ms ease;
	}

	.gather-logo:global(.is-attracting) img {
		filter:
			drop-shadow(0 28px 30px rgb(6 24 80 / 32%))
			drop-shadow(0 0 18px rgb(44 95 255 / 50%));
	}

	.gather-logo:global(.has-impact) img {
		animation: logo-impact 360ms cubic-bezier(0.16, 0.8, 0.28, 1);
	}

	.logo-halo {
		position: absolute;
		z-index: 1;
		inset: -82%;
		border-radius: 50%;
		background: radial-gradient(circle, rgb(28 82 255 / 21%), transparent 64%);
		animation: halo-breathe 3.2s ease-in-out infinite;
	}

	.intake-ring {
		position: absolute;
		z-index: 3;
		inset: -10%;
		border: 1px solid rgb(57 106 255 / 34%);
		border-radius: 30%;
		opacity: 0;
	}

	.gather-logo:global(.is-attracting) .intake-ring {
		animation: intake-ring 1s ease-out infinite;
	}

	.intake-ring-two {
		animation-delay: -0.5s !important;
	}

	.source-card {
		position: absolute;
		z-index: 8;
		display: flex;
		width: clamp(162px, 14vw, 214px);
		min-height: 118px;
		flex-direction: column;
		padding: 12px 13px 12px;
		border: 1px solid rgb(17 17 15 / 15%);
		border-radius: 15px;
		background:
			linear-gradient(145deg, rgb(255 255 255 / 95%), rgb(241 237 226 / 97%)),
			var(--paper-bright);
		box-shadow:
			0 20px 45px rgb(27 25 17 / 13%),
			inset 0 1px 0 white;
		transform: translate(-50%, -50%) rotate(var(--rotate));
		transform-origin: center center;
		will-change: transform, filter, opacity;
		backdrop-filter: blur(12px);
	}

	.source-card::after {
		position: absolute;
		inset: 0;
		border-radius: inherit;
		background: linear-gradient(115deg, transparent 22%, rgb(255 255 255 / 42%), transparent 58%);
		content: '';
		opacity: 0.45;
		pointer-events: none;
	}

	.source-card.is-absorbing {
		transition:
			opacity 240ms ease,
			filter 240ms ease,
			transform 240ms cubic-bezier(0.5, 0, 1, 0.4);
	}

	.source-topline {
		display: flex;
		align-items: center;
		gap: 8px;
		color: rgb(17 17 15 / 65%);
		font-size: 10px;
		font-weight: 750;
		letter-spacing: 0.11em;
		text-transform: uppercase;
	}

	.source-grip {
		display: flex;
		gap: 2px;
		margin-left: auto;
	}

	.source-grip i {
		width: 2px;
		height: 2px;
		border-radius: 50%;
		background: rgb(17 17 15 / 35%);
	}

	.source-icon {
		display: grid;
		width: 24px;
		height: 24px;
		place-items: center;
		border-radius: 7px;
		background: rgb(22 77 255 / 9%);
		color: var(--blue);
	}

	.source-icon :global(svg) {
		width: 13px;
		height: 13px;
		stroke-width: 2.2;
	}

	.source-card-red .source-icon {
		background: rgb(238 40 40 / 10%);
		color: #e62d2d;
	}

	.source-card-orange .source-icon {
		background: rgb(224 95 32 / 10%);
		color: #d55a20;
	}

	.source-card-ink .source-icon {
		background: rgb(17 17 15 / 8%);
		color: #11110f;
	}

	.source-card-teal .source-icon {
		background: rgb(15 141 135 / 10%);
		color: #087e78;
	}

	.source-card-purple .source-icon {
		background: rgb(118 57 218 / 10%);
		color: #7236c9;
	}

	.source-card strong {
		position: relative;
		z-index: 1;
		margin-top: 12px;
		font-size: 12px;
		letter-spacing: -0.025em;
		line-height: 1.2;
	}

	.source-author {
		position: relative;
		z-index: 1;
		margin-top: 6px;
		color: rgb(17 17 15 / 68%);
		font-size: 9px;
		font-weight: 650;
		letter-spacing: -0.01em;
	}

	.source-card small {
		position: relative;
		z-index: 1;
		margin-top: auto;
		padding-top: 8px;
		color: rgb(17 17 15 / 48%);
		font-size: 9px;
	}

	.sweep-status {
		position: absolute;
		z-index: 24;
		right: clamp(20px, 3vw, 48px);
		bottom: 24px;
		display: flex;
		align-items: center;
		gap: 20px;
		padding: 10px 12px 10px 14px;
		border: 1px solid rgb(17 17 15 / 11%);
		border-radius: 999px;
		background: rgb(250 247 239 / 78%);
		box-shadow: 0 12px 28px rgb(26 23 14 / 8%);
		color: rgb(17 17 15 / 56%);
		font-size: 9px;
		font-weight: 680;
		letter-spacing: 0.03em;
		backdrop-filter: blur(18px);
		transition:
			border-color 200ms ease,
			background 200ms ease;
	}

	.sweep-status > div {
		display: flex;
		align-items: center;
		gap: 9px;
		white-space: nowrap;
	}

	.sweep-count {
		color: var(--blue);
		font-variant-numeric: tabular-nums;
	}

	.sweep-hint {
		display: flex;
		align-items: center;
		gap: 5px;
		padding-left: 18px;
		border-left: 1px solid rgb(17 17 15 / 10%);
		color: rgb(17 17 15 / 38%);
	}

	.sweep-status kbd {
		display: inline-grid;
		min-width: 19px;
		height: 19px;
		place-items: center;
		padding: 0 5px;
		border: 1px solid rgb(17 17 15 / 16%);
		border-bottom-width: 2px;
		border-radius: 5px;
		background: rgb(255 255 255 / 72%);
		color: rgb(17 17 15 / 64%);
		font-family: inherit;
		font-size: 8px;
		font-weight: 780;
	}

	.sweep-status.is-complete {
		border-color: rgb(22 77 255 / 22%);
		background: rgb(247 249 255 / 88%);
	}

	.sweep-status button {
		display: flex;
		align-items: center;
		gap: 6px;
		padding: 7px 11px;
		border: 0;
		border-radius: 999px;
		background: var(--blue);
		color: white;
		font: inherit;
		cursor: none;
	}

	.sweep-status button :global(svg) {
		width: 12px;
	}

	.sweep-status button kbd {
		border-color: rgb(255 255 255 / 28%);
		background: rgb(255 255 255 / 14%);
		color: white;
	}

	.scroll-cue {
		position: absolute;
		z-index: 15;
		bottom: 26px;
		left: clamp(22px, 4vw, 68px);
		display: flex;
		align-items: center;
		gap: 12px;
		color: rgb(17 17 15 / 46%);
		font-size: 9px;
		font-weight: 740;
		letter-spacing: 0.16em;
		text-transform: uppercase;
	}

	.scroll-track {
		position: relative;
		width: 42px;
		height: 1px;
		overflow: hidden;
		background: rgb(17 17 15 / 16%);
	}

	.scroll-track i {
		position: absolute;
		width: 18px;
		height: 1px;
		background: var(--blue);
		animation: scroll-line 1.8s ease-in-out infinite;
	}

	.source-marquee {
		overflow: hidden;
		padding: 17px 0;
		border-top: 1px solid var(--line);
		border-bottom: 1px solid var(--line);
		background: #e9e3d7;
	}

	.marquee-track {
		display: flex;
		width: max-content;
		animation: marquee 30s linear infinite;
	}

	.marquee-set {
		display: flex;
		align-items: center;
		gap: 24px;
		padding-right: 24px;
	}

	.marquee-set span {
		font-size: 11px;
		font-weight: 780;
		letter-spacing: 0.13em;
		text-transform: uppercase;
	}

	.marquee-set i {
		width: 4px;
		height: 4px;
		border-radius: 50%;
		background: var(--blue);
	}

	.section-shell {
		width: min(1380px, calc(100% - clamp(40px, 8vw, 132px)));
		margin-inline: auto;
	}

	.attention-section {
		padding-top: clamp(110px, 14vw, 220px);
		padding-bottom: clamp(120px, 15vw, 230px);
	}

	.section-number {
		color: var(--blue);
		font-size: 10px;
		font-weight: 820;
		letter-spacing: 0.16em;
		text-transform: uppercase;
	}

	.attention-grid {
		display: grid;
		grid-template-columns: minmax(0, 1.6fr) minmax(280px, 0.65fr);
		gap: clamp(50px, 9vw, 150px);
		margin-top: clamp(55px, 7vw, 96px);
	}

	.display-heading {
		max-width: 960px;
		font-size: clamp(58px, 7.3vw, 116px);
	}

	.attention-copy {
		padding-top: 8px;
	}

	.attention-copy > p {
		margin: 0 0 26px;
		color: rgb(17 17 15 / 64%);
		font-size: clamp(17px, 1.5vw, 21px);
		letter-spacing: -0.025em;
		line-height: 1.55;
	}

	.attention-copy > p:first-child {
		color: var(--ink);
		font-weight: 610;
	}

	.proof-note {
		display: flex;
		align-items: flex-start;
		gap: 13px;
		margin-top: 40px;
		padding-top: 21px;
		border-top: 1px solid var(--line);
	}

	.proof-icon {
		display: grid;
		width: 34px;
		height: 34px;
		flex: 0 0 34px;
		place-items: center;
		border-radius: 50%;
		background: rgb(22 77 255 / 9%);
		color: var(--blue);
	}

	.proof-icon :global(svg) {
		width: 17px;
	}

	.proof-note strong,
	.proof-note small {
		display: block;
	}

	.proof-note strong {
		font-size: 13px;
	}

	.proof-note small {
		margin-top: 5px;
		color: rgb(17 17 15 / 50%);
		font-size: 11px;
		line-height: 1.45;
	}

	.flow-section {
		padding: clamp(100px, 12vw, 180px) 0;
		background: #e8e2d6;
	}

	.flow-heading {
		display: grid;
		grid-template-columns: 1fr 0.42fr;
		align-items: end;
		gap: 80px;
	}

	.flow-heading h2,
	.depth-copy h2,
	.agents-copy h2,
	.privacy-heading h2 {
		margin-top: 30px;
		font-size: clamp(60px, 7.6vw, 118px);
	}

	.flow-heading > p {
		max-width: 440px;
		margin: 0 0 4px;
		color: rgb(17 17 15 / 61%);
		font-size: 18px;
		letter-spacing: -0.025em;
		line-height: 1.55;
	}

	.flow-visual {
		position: relative;
		width: min(1480px, calc(100% - 32px));
		margin: clamp(70px, 8vw, 120px) auto 0;
		overflow: hidden;
		border: 1px solid rgb(17 17 15 / 11%);
		border-radius: 32px;
		background: #f7f2e9;
		box-shadow: 0 40px 100px rgb(55 46 29 / 12%);
	}

	.flow-visual::after {
		position: absolute;
		inset: 0;
		border-radius: inherit;
		box-shadow: inset 0 1px 0 rgb(255 255 255 / 72%);
		content: '';
		pointer-events: none;
	}

	.flow-visual img {
		display: block;
		width: 100%;
		aspect-ratio: 1672 / 941;
		object-fit: cover;
	}

	.flow-visual figcaption {
		display: grid;
		grid-template-columns: auto 1fr auto 1fr auto;
		align-items: center;
		gap: 18px;
		padding: 18px 24px;
		border-top: 1px solid rgb(17 17 15 / 8%);
		background: rgb(250 247 239 / 92%);
		color: rgb(17 17 15 / 48%);
		font-size: 9px;
		font-weight: 760;
		letter-spacing: 0.09em;
		text-transform: uppercase;
	}

	.flow-visual figcaption i {
		height: 1px;
		background: linear-gradient(90deg, rgb(22 77 255 / 14%), rgb(22 77 255 / 58%));
	}

	.flow-canvas {
		position: relative;
		display: grid;
		width: min(1480px, calc(100% - 32px));
		min-height: 580px;
		grid-template-columns: 1fr 0.5fr 0.8fr 0.5fr 1fr;
		align-items: center;
		margin: clamp(70px, 8vw, 120px) auto 0;
		overflow: hidden;
		border: 1px solid rgb(255 255 255 / 8%);
		border-radius: 32px;
		background:
			radial-gradient(circle at 50% 50%, rgb(29 85 255 / 20%), transparent 28%),
			linear-gradient(145deg, #071b59, #020817 62%, #061439);
		box-shadow: 0 40px 100px rgb(1 6 23 / 18%);
		color: white;
	}

	.flow-noise {
		position: absolute;
		inset: 0;
		background-image: radial-gradient(rgb(255 255 255 / 12%) 0.7px, transparent 0.7px);
		background-size: 7px 7px;
		mask-image: linear-gradient(90deg, transparent, black 45%, black 55%, transparent);
		opacity: 0.22;
	}

	.flow-inputs {
		position: relative;
		z-index: 2;
		display: grid;
		grid-template-columns: repeat(2, minmax(110px, 1fr));
		gap: 12px;
		padding-left: clamp(24px, 5vw, 76px);
	}

	.mini-source {
		display: flex;
		min-height: 80px;
		align-items: center;
		gap: 11px;
		padding: 16px;
		border: 1px solid rgb(255 255 255 / 11%);
		border-radius: 14px;
		background: rgb(255 255 255 / 7%);
		font-size: 11px;
		font-weight: 700;
		letter-spacing: 0.06em;
		text-transform: uppercase;
		backdrop-filter: blur(12px);
	}

	.mini-source :global(svg) {
		width: 18px;
		color: #78a0ff;
	}

	.flow-line {
		position: relative;
		z-index: 2;
		height: 1px;
		background: linear-gradient(90deg, rgb(80 124 255 / 8%), #4b7dff);
	}

	.flow-line-out {
		background: linear-gradient(90deg, #4b7dff, rgb(80 124 255 / 8%));
	}

	.flow-line::before,
	.flow-line::after {
		position: absolute;
		top: -2px;
		width: 5px;
		height: 5px;
		border-radius: 50%;
		background: #80a3ff;
		box-shadow: 0 0 12px #4678ff;
		content: '';
	}

	.flow-line::before {
		left: 15%;
	}

	.flow-line::after {
		right: 15%;
	}

	.flow-line span {
		position: absolute;
		top: -1px;
		width: 70px;
		height: 3px;
		background: linear-gradient(90deg, transparent, white, transparent);
		filter: blur(1px);
		animation: data-flow 2.4s ease-in-out infinite;
	}

	.flow-core {
		position: relative;
		z-index: 3;
		display: flex;
		align-items: center;
		flex-direction: column;
	}

	.shortcut {
		display: flex;
		align-items: center;
		gap: 8px;
		margin-bottom: 30px;
	}

	.shortcut i {
		width: 13px;
		height: 1px;
		background: rgb(255 255 255 / 26%);
	}

	.core-mark {
		position: relative;
		width: clamp(116px, 11vw, 150px);
		aspect-ratio: 1;
	}

	.core-mark span {
		position: absolute;
		inset: -35%;
		border-radius: 50%;
		background: radial-gradient(circle, rgb(47 102 255 / 38%), transparent 65%);
		animation: halo-breathe 3s ease-in-out infinite;
	}

	.flow-core > strong {
		margin-top: 18px;
		font-size: 21px;
		letter-spacing: -0.04em;
	}

	.flow-core > small {
		margin-top: 6px;
		color: rgb(255 255 255 / 48%);
		font-size: 10px;
		letter-spacing: 0.08em;
		text-transform: uppercase;
	}

	.flow-output {
		position: relative;
		z-index: 2;
		height: 300px;
		margin-right: clamp(24px, 5vw, 76px);
	}

	.stack-card {
		position: absolute;
		inset: 0;
		border: 1px solid rgb(255 255 255 / 12%);
		border-radius: 18px;
	}

	.stack-back {
		background: #0e2a73;
		transform: translate(22px, -18px) rotate(5deg);
	}

	.stack-mid {
		background: #274fbd;
		transform: translate(12px, -9px) rotate(2deg);
	}

	.stack-front {
		overflow: hidden;
		padding: 58px 24px 24px;
		background: #f6f3ea;
		box-shadow: 0 20px 50px rgb(0 0 0 / 30%);
		color: var(--ink);
	}

	.doc-toolbar {
		position: absolute;
		top: 0;
		right: 0;
		left: 0;
		display: flex;
		height: 38px;
		align-items: center;
		gap: 5px;
		padding: 0 12px;
		border-bottom: 1px solid rgb(17 17 15 / 9%);
		background: #e6e1d6;
	}

	.doc-toolbar i {
		width: 6px;
		height: 6px;
		border-radius: 50%;
		background: rgb(17 17 15 / 16%);
	}

	.doc-toolbar span {
		margin-left: auto;
		color: rgb(17 17 15 / 45%);
		font-size: 8px;
		font-weight: 700;
		letter-spacing: 0.06em;
	}

	.doc-title {
		width: 72%;
		height: 13px;
		margin-bottom: 23px;
		border-radius: 4px;
		background: var(--ink);
	}

	.doc-line {
		width: 72%;
		height: 5px;
		margin-bottom: 10px;
		border-radius: 3px;
		background: rgb(17 17 15 / 20%);
	}

	.doc-line.long {
		width: 96%;
	}

	.doc-line.short {
		width: 52%;
	}

	.doc-tag {
		position: absolute;
		right: 18px;
		bottom: 18px;
		padding: 7px 9px;
		border: 1px solid rgb(22 77 255 / 25%);
		border-radius: 7px;
		background: rgb(22 77 255 / 7%);
		color: var(--blue);
		font-size: 7px;
		font-weight: 850;
		letter-spacing: 0.12em;
	}

	.steps-grid {
		display: grid;
		grid-template-columns: repeat(3, 1fr);
		margin-top: 30px;
		border-top: 1px solid var(--line);
		border-left: 1px solid var(--line);
	}

	.step-card {
		position: relative;
		min-height: 330px;
		padding: 30px;
		border-right: 1px solid var(--line);
		border-bottom: 1px solid var(--line);
		transition:
			background 240ms ease,
			transform 240ms ease;
	}

	.step-card:hover {
		z-index: 2;
		background: #f2ede3;
		transform: translateY(-5px);
	}

	.step-card > span {
		color: rgb(17 17 15 / 35%);
		font-size: 9px;
		font-weight: 780;
		letter-spacing: 0.12em;
	}

	.step-icon {
		display: grid;
		width: 58px;
		height: 58px;
		margin-top: 58px;
		place-items: center;
		border: 1px solid rgb(22 77 255 / 14%);
		border-radius: 18px;
		background: rgb(22 77 255 / 7%);
		color: var(--blue);
	}

	.step-icon :global(svg) {
		width: 23px;
	}

	.step-card h3 {
		margin: 23px 0 9px;
		font-size: 23px;
		letter-spacing: -0.045em;
	}

	.step-card p {
		max-width: 330px;
		margin: 0;
		color: rgb(17 17 15 / 56%);
		font-size: 14px;
		line-height: 1.55;
	}

	.depth-section {
		display: grid;
		grid-template-columns: 0.85fr 1.15fr;
		gap: clamp(60px, 9vw, 150px);
		align-items: center;
		padding-top: clamp(120px, 15vw, 230px);
		padding-bottom: clamp(120px, 15vw, 230px);
	}

	.depth-copy h2 {
		font-size: clamp(58px, 6.8vw, 104px);
	}

	.depth-copy > p {
		max-width: 520px;
		margin: 34px 0 0;
		color: rgb(17 17 15 / 60%);
		font-size: 18px;
		letter-spacing: -0.025em;
		line-height: 1.6;
	}

	.listen-chip {
		display: inline-flex;
		align-items: center;
		gap: 9px;
		margin-top: 32px;
		padding: 10px 13px;
		border: 1px solid rgb(22 77 255 / 13%);
		border-radius: 999px;
		background: rgb(22 77 255 / 6%);
		color: #173ea8;
		font-size: 11px;
		font-weight: 650;
	}

	.listen-chip :global(svg) {
		width: 14px;
	}

	.product-demo {
		position: relative;
		padding: 10px;
		border: 1px solid rgb(17 17 15 / 16%);
		border-radius: 25px;
		background: #d0d1cd;
		box-shadow:
			0 42px 100px rgb(43 36 22 / 21%),
			inset 0 1px 0 rgb(255 255 255 / 60%);
		transform: rotate(1deg);
		transition: transform 350ms ease;
	}

	.product-demo:hover {
		transform: rotate(0);
	}

	.product-demo-toolbar {
		display: flex;
		height: 36px;
		align-items: center;
		justify-content: space-between;
		padding: 0 8px 0 10px;
		color: rgb(17 17 15 / 52%);
		font-size: 8px;
		font-weight: 740;
		letter-spacing: 0.12em;
		text-transform: uppercase;
	}

	.product-demo-toolbar > div {
		display: flex;
		align-items: center;
		gap: 7px;
	}

	.live-dot {
		width: 5px;
		height: 5px;
		border-radius: 50%;
		background: #1a7a5c;
		box-shadow: 0 0 0 4px rgb(26 122 92 / 12%);
	}

	.product-screenshot {
		overflow: hidden;
		aspect-ratio: 16 / 9;
		border: 1px solid rgb(17 17 15 / 13%);
		border-radius: 17px;
		background: #aeb0ab;
		box-shadow: 0 18px 45px rgb(30 28 22 / 18%);
	}

	.product-screenshot img {
		display: block;
		width: 100%;
		height: 100%;
		object-fit: cover;
	}

	.product-depth-picker {
		display: grid;
		grid-template-columns: repeat(4, 1fr);
		gap: 6px;
		padding: 10px 2px 1px;
	}

	.product-depth-picker button {
		display: flex;
		min-width: 0;
		height: 42px;
		align-items: center;
		justify-content: center;
		gap: 7px;
		padding: 0 8px;
		border: 1px solid transparent;
		border-radius: 12px;
		background: transparent;
		color: rgb(17 17 15 / 52%);
		font: inherit;
		font-size: 9px;
		font-weight: 680;
		cursor: pointer;
		transition:
			background 180ms ease,
			border-color 180ms ease,
			color 180ms ease;
	}

	.product-depth-picker button span {
		display: grid;
		width: 19px;
		height: 19px;
		flex: 0 0 19px;
		place-items: center;
		border: 1px solid rgb(17 17 15 / 16%);
		border-radius: 6px;
		font-size: 7px;
	}

	.product-depth-picker button.active {
		border-color: rgb(11 86 63 / 18%);
		background: #ecece7;
		color: #0b563f;
	}

	.product-depth-picker button.active span {
		border-color: #0b563f;
		background: #0b563f;
		color: white;
	}

	.product-demo-caption {
		position: absolute;
		top: calc(100% + 12px);
		right: 6px;
		margin: 0;
		color: rgb(17 17 15 / 42%);
		font-size: 9px;
	}

	.agents-section {
		padding: clamp(110px, 14vw, 210px) 0;
		overflow: hidden;
		background:
			radial-gradient(circle at 50% 72%, rgb(28 83 255 / 16%), transparent 38%),
			#030b24;
		color: white;
	}

	.agents-inner {
		display: grid;
		gap: clamp(54px, 7vw, 92px);
	}

	.agents-copy {
		display: grid;
		grid-template-columns: minmax(0, 1.15fr) minmax(320px, 0.55fr);
		gap: clamp(60px, 9vw, 150px);
		align-items: end;
	}

	.agents-heading .section-number {
		color: #82a7ff;
	}

	.agents-heading h2 {
		max-width: 900px;
		font-size: clamp(58px, 6.5vw, 100px);
	}

	.agents-story > p {
		margin: 0;
		color: rgb(255 255 255 / 61%);
		font-size: 17px;
		letter-spacing: -0.02em;
		line-height: 1.6;
	}

	.agents-story ul {
		display: grid;
		gap: 14px;
		margin: 35px 0;
		padding: 0;
		list-style: none;
		color: rgb(255 255 255 / 78%);
		font-size: 13px;
	}

	.agents-story li {
		display: flex;
		align-items: flex-start;
		gap: 10px;
	}

	.agents-story li :global(svg) {
		width: 16px;
		flex: 0 0 16px;
		margin-top: 1px;
		color: #6ee08f;
	}

	.agents-visual {
		position: relative;
		margin: 0;
		overflow: hidden;
		border: 1px solid rgb(255 255 255 / 14%);
		border-radius: 28px;
		background: #f4eee4;
		box-shadow: 0 42px 110px rgb(0 0 0 / 36%);
		isolation: isolate;
	}

	.agents-visual::after {
		position: absolute;
		z-index: 1;
		inset: 0;
		background: linear-gradient(
			110deg,
			transparent 35%,
			rgb(255 255 255 / 22%) 48%,
			transparent 61%
		);
		content: '';
		pointer-events: none;
		transform: translateX(-120%);
		animation: workspace-glint 8s ease-in-out infinite;
	}

	.agents-visual img {
		display: block;
		width: 100%;
		height: auto;
		transition: transform 900ms cubic-bezier(0.2, 0.75, 0.2, 1);
	}

	.agents-visual:hover img {
		transform: scale(1.012);
	}

	.agents-visual figcaption {
		position: relative;
		z-index: 2;
		display: flex;
		justify-content: space-between;
		gap: 24px;
		padding: 16px 20px;
		border-top: 1px solid rgb(17 17 15 / 8%);
		background: #f4eee4;
		color: rgb(17 17 15 / 52%);
		font-size: 10px;
		font-weight: 680;
		letter-spacing: 0.08em;
		text-transform: uppercase;
	}

	.button-light {
		background: #e9efff;
		color: #09236d !important;
	}

	.button-light:hover {
		box-shadow: 0 18px 40px rgb(38 88 230 / 28%);
	}

	.privacy-section {
		padding-top: clamp(120px, 15vw, 220px);
		padding-bottom: clamp(120px, 14vw, 210px);
	}

	.privacy-heading {
		display: grid;
		grid-template-columns: 0.32fr 1fr;
		align-items: start;
		gap: 60px;
	}

	.privacy-heading h2 {
		max-width: 980px;
		margin-top: 0;
		font-size: clamp(58px, 7vw, 110px);
	}

	.privacy-grid {
		display: grid;
		grid-template-columns: repeat(3, 1fr);
		margin-top: clamp(75px, 9vw, 130px);
		border-top: 1px solid var(--line);
		border-left: 1px solid var(--line);
	}

	.privacy-grid article {
		min-height: 270px;
		padding: 30px;
		border-right: 1px solid var(--line);
		border-bottom: 1px solid var(--line);
	}

	.privacy-icon {
		display: grid;
		width: 48px;
		height: 48px;
		place-items: center;
		border-radius: 15px;
		background: var(--ink);
		color: white;
	}

	.privacy-icon :global(svg) {
		width: 19px;
	}

	.privacy-grid h3 {
		margin: 65px 0 12px;
		font-size: 21px;
		letter-spacing: -0.045em;
	}

	.privacy-grid p {
		max-width: 320px;
		margin: 0;
		color: rgb(17 17 15 / 55%);
		font-size: 13px;
		line-height: 1.6;
	}

	.downloads-section {
		padding: clamp(110px, 14vw, 210px) 0;
		border-top: 1px solid var(--line);
		background:
			radial-gradient(circle at 84% 16%, rgb(22 77 255 / 12%), transparent 26%),
			#e7e1d5;
	}

	.downloads-heading {
		display: grid;
		grid-template-columns: 0.28fr 0.8fr 0.72fr;
		gap: clamp(30px, 5vw, 80px);
		align-items: end;
	}

	.downloads-heading h2 {
		margin: 0;
		font-size: clamp(62px, 7.6vw, 118px);
		font-weight: 820;
		letter-spacing: -0.075em;
		line-height: 0.87;
	}

	.downloads-heading > p {
		max-width: 480px;
		margin: 0 0 8px;
		color: rgb(17 17 15 / 58%);
		font-size: 16px;
		letter-spacing: -0.025em;
		line-height: 1.62;
	}

	.plan-strip {
		display: grid;
		grid-template-columns: minmax(0, 0.8fr) minmax(0, 1.2fr);
		margin-top: clamp(64px, 7vw, 100px);
		overflow: hidden;
		border: 1px solid rgb(17 17 15 / 13%);
		border-radius: 28px;
		background: rgb(250 247 239 / 72%);
		box-shadow: 0 28px 70px rgb(31 27 18 / 8%);
	}

	.plan-card {
		min-height: 330px;
		padding: clamp(28px, 4vw, 52px);
	}

	.plan-plus {
		background:
			radial-gradient(circle at 88% 12%, rgb(99 139 255 / 42%), transparent 28%),
			linear-gradient(145deg, #0b2a83, #030d2d 78%);
		color: white;
	}

	.plan-card-top {
		display: flex;
		align-items: center;
		justify-content: space-between;
		gap: 24px;
	}

	.plan-card-top span {
		font-size: 10px;
		font-weight: 820;
		letter-spacing: 0.12em;
		text-transform: uppercase;
	}

	.plan-card-top strong {
		padding: 8px 11px;
		border-radius: 999px;
		background: rgb(22 77 255 / 9%);
		color: #173ea8;
		font-size: 9px;
		letter-spacing: 0.04em;
	}

	.plan-plus .plan-card-top strong {
		background: rgb(255 255 255 / 11%);
		color: #c6d3ff;
	}

	.plan-card h3 {
		max-width: 570px;
		margin: 58px 0 0;
		font-size: clamp(28px, 3vw, 44px);
		letter-spacing: -0.06em;
		line-height: 1;
	}

	.plan-plus h3 {
		margin-top: 38px;
	}

	.plan-plus-intro {
		max-width: 540px;
		margin: 13px 0 0;
		color: rgb(255 255 255 / 58%);
		font-size: 12px;
		line-height: 1.55;
	}

	.pricing-ladder {
		display: grid;
		margin-top: 28px;
		overflow: hidden;
		border: 1px solid rgb(255 255 255 / 12%);
		border-radius: 16px;
		background: rgb(255 255 255 / 4%);
	}

	.pricing-ladder > div {
		display: grid;
		min-height: 58px;
		grid-template-columns: minmax(0, 1fr) auto minmax(58px, auto);
		align-items: center;
		gap: 16px;
		padding: 10px 13px;
		border-bottom: 1px solid rgb(255 255 255 / 9%);
		color: rgb(255 255 255 / 48%);
	}

	.pricing-ladder > div:last-child {
		border-bottom: 0;
	}

	.pricing-ladder > div.current {
		background: rgb(95 139 255 / 16%);
		color: white;
		box-shadow: inset 3px 0 #7da0ff;
	}

	.pricing-ladder > div.past {
		opacity: 0.5;
	}

	.pricing-ladder span,
	.pricing-ladder b,
	.pricing-ladder small {
		display: block;
	}

	.pricing-ladder b {
		font-size: 11px;
	}

	.pricing-ladder small {
		margin-top: 3px;
		color: rgb(255 255 255 / 42%);
		font-size: 9px;
		font-weight: 500;
	}

	.pricing-ladder > div > strong {
		color: inherit;
		font-size: 14px;
		font-variant-numeric: tabular-nums;
	}

	.pricing-ladder em {
		min-width: 58px;
		padding: 5px 7px;
		border-radius: 999px;
		background: rgb(255 255 255 / 10%);
		color: #c8d5ff;
		font-size: 8px;
		font-style: normal;
		font-weight: 760;
		text-align: center;
		text-transform: uppercase;
	}

	.plan-card ul {
		display: grid;
		gap: 11px;
		margin: 34px 0 0;
		padding: 0;
		color: rgb(17 17 15 / 57%);
		font-size: 12px;
		list-style: none;
	}

	.plan-plus ul {
		color: rgb(255 255 255 / 64%);
	}

	.plan-card li {
		display: flex;
		align-items: center;
		gap: 9px;
	}

	.plan-card li :global(svg) {
		width: 15px;
		flex: 0 0 auto;
		color: #0c7757;
	}

	.plan-plus li :global(svg) {
		color: #8aa9ff;
	}

	.pricing-cta {
		display: inline-flex;
		min-height: 48px;
		align-items: center;
		justify-content: center;
		gap: 10px;
		margin-top: 27px;
		padding: 0 18px;
		border: 0;
		border-radius: 999px;
		background: white;
		color: #09236d;
		font: inherit;
		font-size: 12px;
		font-weight: 760;
		cursor: pointer;
		transition:
			transform 180ms ease,
			box-shadow 180ms ease;
	}

	.pricing-cta:hover:not(:disabled) {
		box-shadow: 0 16px 34px rgb(0 0 0 / 22%);
		transform: translateY(-2px);
	}

	.pricing-cta:disabled {
		cursor: not-allowed;
		opacity: 0.55;
	}

	.pricing-cta :global(svg) {
		width: 15px;
	}

	.pricing-note,
	.pricing-message {
		margin: 11px 0 0;
		color: rgb(255 255 255 / 42%);
		font-size: 9px;
		line-height: 1.5;
	}

	.pricing-note a {
		text-decoration: underline;
		text-underline-offset: 2px;
	}

	.pricing-message {
		color: #f8cfa7;
	}

	.download-grid {
		display: grid;
		grid-template-columns: repeat(3, 1fr);
		gap: 12px;
		margin-top: clamp(70px, 8vw, 120px);
	}

	.download-card {
		position: relative;
		display: flex;
		min-height: 330px;
		flex-direction: column;
		padding: 26px;
		overflow: hidden;
		border: 1px solid rgb(17 17 15 / 13%);
		border-radius: 23px;
		background: rgb(250 247 239 / 75%);
		box-shadow: 0 20px 50px rgb(31 27 18 / 7%);
		transition:
			transform 220ms ease,
			border-color 220ms ease,
			box-shadow 220ms ease;
	}

	.download-card:hover {
		border-color: rgb(22 77 255 / 25%);
		box-shadow: 0 26px 60px rgb(31 27 18 / 11%);
		transform: translateY(-5px);
	}

	.download-card.preferred {
		border-color: rgb(22 77 255 / 40%);
		box-shadow:
			0 25px 60px rgb(22 77 255 / 11%),
			inset 0 0 0 1px rgb(22 77 255 / 10%);
	}

	.download-card-top {
		display: flex;
		align-items: center;
		justify-content: space-between;
		gap: 14px;
	}

	.platform-icon {
		display: grid;
		width: 48px;
		height: 48px;
		place-items: center;
		border: 1px solid rgb(17 17 15 / 11%);
		border-radius: 15px;
		background: white;
		color: var(--blue);
		box-shadow: 0 10px 25px rgb(31 27 18 / 8%);
	}

	.platform-icon :global(svg) {
		width: 20px;
	}

	.preferred-pill,
	.pwa-pill {
		padding: 7px 9px;
		border-radius: 999px;
		background: rgb(22 77 255 / 8%);
		color: #173ea8;
		font-size: 8px;
		font-weight: 760;
		letter-spacing: 0.08em;
		text-transform: uppercase;
	}

	.download-card > div:nth-child(2) {
		margin-top: auto;
		padding-top: 42px;
	}

	.download-card p {
		margin: 0 0 8px;
		color: rgb(17 17 15 / 42%);
		font-size: 8px;
		font-weight: 780;
		letter-spacing: 0.14em;
		text-transform: uppercase;
	}

	.download-card h3 {
		margin: 0;
		font-size: 32px;
		letter-spacing: -0.055em;
	}

	.download-card > div:nth-child(2) > span {
		display: block;
		max-width: 270px;
		margin-top: 10px;
		color: rgb(17 17 15 / 50%);
		font-size: 12px;
		line-height: 1.5;
	}

	.download-card > a,
	.linux-actions a {
		display: inline-flex;
		min-height: 44px;
		align-items: center;
		justify-content: center;
		gap: 8px;
		margin-top: 25px;
		padding: 0 15px;
		border-radius: 999px;
		background: var(--ink);
		color: white;
		font-size: 11px;
		font-weight: 720;
	}

	.download-card > a :global(svg),
	.linux-actions a :global(svg) {
		width: 14px;
	}

	.linux-actions {
		display: grid;
		grid-template-columns: 1fr auto;
		gap: 7px;
	}

	.linux-actions a:last-child {
		min-width: 60px;
		border: 1px solid rgb(17 17 15 / 14%);
		background: transparent;
		color: var(--ink);
	}

	.pwa-card {
		min-height: 250px;
		grid-column: 1 / -1;
		display: grid;
		grid-template-columns: auto minmax(260px, 1fr) auto;
		align-items: center;
		gap: clamp(30px, 5vw, 80px);
		background:
			radial-gradient(circle at 80% 50%, rgb(92 134 255 / 35%), transparent 25%),
			linear-gradient(140deg, #092b8d, #031038 72%);
		color: white;
	}

	.pwa-card .download-card-top {
		display: block;
	}

	.pwa-card .platform-icon {
		width: 70px;
		height: 70px;
		border-color: rgb(255 255 255 / 16%);
		background: rgb(255 255 255 / 10%);
		color: white;
		box-shadow: none;
	}

	.pwa-card .platform-icon :global(svg) {
		width: 27px;
	}

	.pwa-card .pwa-pill {
		display: inline-flex;
		margin-top: 12px;
		background: rgb(255 255 255 / 10%);
		color: #b8c9ff;
	}

	.pwa-card > div:nth-child(2) {
		margin: 0;
		padding: 0;
	}

	.pwa-card p {
		color: #9cb5ff;
	}

	.pwa-card h3 {
		font-size: clamp(31px, 3.5vw, 48px);
	}

	.pwa-card > div:nth-child(2) > span {
		max-width: 560px;
		color: rgb(255 255 255 / 62%);
	}

	.pwa-card > a {
		min-width: 165px;
		margin: 0;
		background: white;
		color: #09236d;
	}

	.pwa-card ol {
		grid-column: 2 / 4;
		display: flex;
		gap: 30px;
		margin: -26px 0 0;
		padding: 0;
		color: rgb(255 255 255 / 46%);
		font-size: 9px;
		list-style: none;
	}

	.pwa-card ol b {
		color: rgb(255 255 255 / 68%);
	}

	.download-footnote {
		display: flex;
		align-items: center;
		justify-content: center;
		gap: 9px;
		margin-top: 27px;
		color: rgb(17 17 15 / 45%);
		font-size: 10px;
	}

	.download-footnote :global(svg) {
		width: 14px;
		color: #0b6a4d;
	}

	.final-cta {
		position: relative;
		display: grid;
		min-height: 92svh;
		place-items: center;
		overflow: hidden;
		background:
			radial-gradient(circle at 50% 50%, rgb(41 98 255 / 46%), transparent 27%),
			linear-gradient(150deg, #092a86, #020a24 68%);
		color: white;
		text-align: center;
	}

	.final-cta::before {
		position: absolute;
		inset: 0;
		background-image: radial-gradient(rgb(255 255 255 / 20%) 0.65px, transparent 0.65px);
		background-size: 9px 9px;
		mask-image: radial-gradient(circle, black, transparent 74%);
		content: '';
		opacity: 0.24;
	}

	.final-orbit {
		position: absolute;
		border: 1px solid rgb(110 149 255 / 17%);
		border-radius: 50%;
	}

	.orbit-one {
		width: min(76vw, 1020px);
		aspect-ratio: 1;
	}

	.orbit-two {
		width: min(48vw, 660px);
		aspect-ratio: 1;
	}

	.final-sources span {
		position: absolute;
		display: grid;
		width: 50px;
		height: 50px;
		place-items: center;
		border: 1px solid rgb(255 255 255 / 13%);
		border-radius: 15px;
		background: rgb(255 255 255 / 7%);
		color: #9ab7ff;
		backdrop-filter: blur(8px);
		animation: float 5s ease-in-out infinite;
	}

	.final-sources span :global(svg) {
		width: 18px;
	}

	.final-sources span:nth-child(1) {
		top: 23%;
		left: 13%;
	}

	.final-sources span:nth-child(2) {
		top: 17%;
		right: 17%;
		animation-delay: -1.4s;
	}

	.final-sources span:nth-child(3) {
		right: 12%;
		bottom: 20%;
		animation-delay: -2.8s;
	}

	.final-sources span:nth-child(4) {
		bottom: 18%;
		left: 17%;
		animation-delay: -4s;
	}

	.final-content {
		position: relative;
		z-index: 3;
		width: min(1000px, calc(100% - 40px));
		padding: 80px 0;
	}

	.final-content > img {
		width: 88px;
		height: 88px;
		margin-bottom: 27px;
		filter: drop-shadow(0 20px 30px rgb(0 0 0 / 35%));
	}

	.final-content > p {
		margin: 0 0 27px;
		color: #9ab7ff;
		font-size: 10px;
		font-weight: 780;
		letter-spacing: 0.18em;
	}

	.final-content h2 {
		font-size: clamp(66px, 9vw, 138px);
	}

	.button-white {
		margin-top: 36px;
		background: white;
		color: #09236d !important;
		box-shadow: 0 20px 50px rgb(0 0 0 / 24%);
	}

	.final-note {
		display: block;
		margin-top: 18px;
		color: rgb(255 255 255 / 45%);
		font-size: 10px;
	}

	.landing-footer {
		display: grid;
		grid-template-columns: 1fr auto 1fr;
		align-items: center;
		gap: 30px;
		padding: 28px clamp(22px, 4vw, 68px);
		border-top: 1px solid var(--line);
		background: #e7e1d5;
	}

	.landing-footer p {
		margin: 0;
		color: rgb(17 17 15 / 50%);
		font-size: 11px;
	}

	.landing-footer > div {
		display: flex;
		justify-self: end;
		align-items: center;
		gap: 22px;
		color: rgb(17 17 15 / 50%);
		font-size: 10px;
	}

	.reveal {
		opacity: 0;
		transform: translateY(34px);
		transition:
			opacity 800ms cubic-bezier(0.2, 0.72, 0.2, 1),
			transform 800ms cubic-bezier(0.2, 0.72, 0.2, 1);
	}

	.reveal.is-visible {
		opacity: 1;
		transform: translateY(0);
	}

	.steps-grid .reveal:nth-child(2),
	.privacy-grid .reveal:nth-child(2) {
		transition-delay: 100ms;
	}

	.steps-grid .reveal:nth-child(3),
	.privacy-grid .reveal:nth-child(3) {
		transition-delay: 200ms;
	}

	@keyframes halo-breathe {
		0%,
		100% {
			opacity: 0.7;
			transform: scale(0.94);
		}
		50% {
			opacity: 1;
			transform: scale(1.06);
		}
	}

	@keyframes logo-impact {
		0%,
		100% {
			transform: scale(1);
		}
		48% {
			transform: scale(1.1);
		}
	}

	@keyframes intake-ring {
		0% {
			opacity: 0;
			transform: scale(0.76);
		}
		16% {
			opacity: 0.55;
		}
		70%,
		100% {
			opacity: 0;
			transform: scale(1.24);
		}
	}

	@keyframes scroll-line {
		0% {
			transform: translateX(-20px);
		}
		100% {
			transform: translateX(48px);
		}
	}

	@keyframes marquee {
		to {
			transform: translateX(-50%);
		}
	}

	@keyframes data-flow {
		0% {
			left: -35%;
			opacity: 0;
		}
		25%,
		70% {
			opacity: 1;
		}
		100% {
			left: 105%;
			opacity: 0;
		}
	}

	@keyframes float {
		0%,
		100% {
			transform: translateY(-7px) rotate(-3deg);
		}
		50% {
			transform: translateY(8px) rotate(3deg);
		}
	}

	@keyframes workspace-glint {
		0%,
		52% {
			transform: translateX(-120%);
		}
		72%,
		100% {
			transform: translateX(120%);
		}
	}

	@media (max-width: 1050px) {
		.landing-nav {
			grid-template-columns: 1fr 1fr;
		}

		.landing-nav nav {
			display: none;
		}

		.attention-grid,
		.flow-heading,
		.depth-section {
			grid-template-columns: 1fr;
		}

		.attention-copy,
		.flow-heading > p,
		.depth-copy > p {
			max-width: 650px;
		}

		.flow-canvas {
			grid-template-columns: 1fr 0.35fr 0.8fr 0.35fr 1fr;
		}

		.flow-visual figcaption {
			grid-template-columns: repeat(3, 1fr);
			gap: 12px;
			text-align: center;
		}

		.flow-visual figcaption i {
			display: none;
		}

		.flow-inputs {
			grid-template-columns: 1fr;
		}

		.mini-source:nth-child(n + 3) {
			display: none;
		}

		.depth-section {
			gap: 70px;
		}

		.agents-copy {
			grid-template-columns: 1fr;
			gap: 42px;
		}

		.agents-story {
			max-width: 650px;
		}

		.privacy-heading {
			grid-template-columns: 1fr;
			gap: 32px;
		}

		.downloads-heading {
			grid-template-columns: 1fr;
			align-items: start;
		}

		.downloads-heading > p {
			margin-top: 8px;
		}

		.download-grid {
			grid-template-columns: repeat(2, 1fr);
		}

		.plan-strip {
			grid-template-columns: 1fr;
		}

		.pwa-card {
			grid-column: 1 / -1;
		}
	}

	@media (max-width: 720px) {
		.landing-nav {
			padding: 18px 18px;
		}

		.landing-brand {
			font-size: 16px;
		}

		.landing-brand img {
			width: 31px;
			height: 31px;
			border-radius: 9px;
		}

		.nav-cta {
			padding: 9px 13px;
			font-size: 11px;
		}

		.hero-scroll {
			height: 100svh;
			min-height: 820px;
		}

		.hero-sticky {
			min-height: inherit;
			background:
				radial-gradient(circle at 72% 70%, rgb(22 77 255 / 16%), transparent 26%),
				linear-gradient(180deg, #fbf8f0 0%, var(--paper) 100%);
		}

		.hero-copy {
			top: 108px;
			left: 18px;
			width: calc(100% - 36px);
		}

		.hero-copy h1 {
			font-size: clamp(48px, 14vw, 70px);
			line-height: 0.9;
		}

		.hero-copy p {
			max-width: 370px;
			margin-top: 20px;
			font-size: 14px;
		}

		.hero-actions {
			gap: 16px;
			margin-top: 22px;
		}

		.hero-free-note {
			max-width: 270px;
			font-size: 9px;
			line-height: 1.4;
		}

		.button {
			min-height: 46px;
			padding: 0 17px;
			font-size: 12px;
		}

		.hero-actions .text-link {
			display: none;
		}

		.gather-logo {
			width: 132px;
		}

		.source-card {
			width: 126px;
			min-height: 102px;
			padding: 9px;
			border-radius: 13px;
		}

		.source-card strong {
			margin-top: 9px;
			font-size: 11px;
		}

		.source-card small {
			font-size: 8px;
		}

		.source-author {
			font-size: 8px;
		}

		.source-topline {
			font-size: 8px;
		}

		.source-icon {
			width: 19px;
			height: 19px;
		}

		.sweep-status {
			right: 14px;
			bottom: 14px;
			left: 14px;
			justify-content: space-between;
		}

		.sweep-hint {
			display: none;
		}

		.scroll-cue {
			display: none;
		}

		.section-shell {
			width: calc(100% - 36px);
		}

		.attention-grid {
			gap: 45px;
			margin-top: 42px;
		}

		.display-heading,
		.flow-heading h2,
		.depth-copy h2,
		.agents-copy h2,
		.privacy-heading h2,
		.downloads-heading h2 {
			font-size: clamp(50px, 15vw, 72px);
		}

		.flow-canvas {
			display: flex;
			min-height: 780px;
			flex-direction: column;
			justify-content: center;
			gap: 34px;
			padding: 60px 24px;
		}

		.flow-visual {
			width: calc(100% - 20px);
			border-radius: 21px;
		}

		.flow-visual img {
			aspect-ratio: 4 / 3;
			object-position: center;
		}

		.flow-visual figcaption {
			padding: 14px 12px;
			font-size: 7px;
			line-height: 1.35;
		}

		.flow-inputs {
			display: flex;
			width: 100%;
			padding: 0;
		}

		.mini-source {
			width: 50%;
			min-height: 64px;
			justify-content: center;
		}

		.flow-line {
			width: 1px;
			height: 45px;
			background: linear-gradient(180deg, rgb(80 124 255 / 8%), #4b7dff);
		}

		.flow-line-out {
			background: linear-gradient(180deg, #4b7dff, rgb(80 124 255 / 8%));
		}

		.flow-line::before,
		.flow-line::after {
			top: auto;
			left: -2px;
		}

		.flow-line::before {
			top: 15%;
		}

		.flow-line::after {
			right: auto;
			bottom: 15%;
		}

		.flow-line span {
			display: none;
		}

		.shortcut {
			margin-bottom: 20px;
		}

		.flow-output {
			width: min(100%, 300px);
			height: 230px;
			margin: 0;
		}

		.steps-grid,
		.privacy-grid {
			grid-template-columns: 1fr;
		}

		.plan-card {
			min-height: 315px;
			padding: 28px 24px;
		}

		.plan-card h3 {
			margin-top: 48px;
			font-size: 31px;
		}

		.plan-plus h3 {
			margin-top: 32px;
		}

		.pricing-ladder > div {
			grid-template-columns: minmax(0, 1fr) auto;
			gap: 10px;
		}

		.pricing-ladder em {
			display: none;
		}

		.pricing-cta {
			width: 100%;
		}

		.step-card {
			min-height: 270px;
		}

		.step-icon {
			margin-top: 36px;
		}

		.depth-section {
			padding-top: 110px;
			padding-bottom: 110px;
		}

		.product-demo {
			padding: 6px;
			border-radius: 16px;
			transform: none;
		}

		.product-demo-toolbar {
			height: 31px;
			font-size: 7px;
		}

		.product-screenshot {
			border-radius: 11px;
		}

		.product-depth-picker {
			grid-template-columns: repeat(4, 1fr);
			gap: 3px;
			padding-top: 7px;
		}

		.product-depth-picker button {
			height: 47px;
			flex-direction: column;
			gap: 4px;
			padding: 4px 2px;
			font-size: 7px;
			text-align: center;
		}

		.product-depth-picker button span {
			width: 17px;
			height: 17px;
			flex-basis: 17px;
		}

		.product-demo-caption {
			display: none;
		}

		.agents-inner {
			gap: 42px;
		}

		.agents-visual {
			border-radius: 18px;
		}

		.agents-visual img {
			min-height: 330px;
			object-fit: cover;
			object-position: center;
		}

		.agents-visual figcaption {
			flex-direction: column;
			gap: 5px;
			padding: 13px 15px;
			font-size: 8px;
		}

		.privacy-grid article {
			min-height: 240px;
		}

		.downloads-section {
			padding: 110px 0;
		}

		.download-grid {
			grid-template-columns: 1fr;
			margin-top: 58px;
		}

		.download-card {
			min-height: 300px;
		}

		.pwa-card {
			display: flex;
			min-height: 380px;
			align-items: stretch;
			gap: 0;
		}

		.pwa-card .download-card-top {
			display: flex;
		}

		.pwa-card .platform-icon {
			width: 54px;
			height: 54px;
		}

		.pwa-card > div:nth-child(2) {
			margin-top: auto;
			padding-top: 36px;
		}

		.pwa-card > a {
			margin-top: 25px;
		}

		.pwa-card ol {
			display: grid;
			gap: 7px;
			margin: 19px 0 0;
		}

		.final-content h2 {
			font-size: clamp(58px, 17vw, 82px);
		}

		.final-sources span:nth-child(1),
		.final-sources span:nth-child(4) {
			left: 6%;
		}

		.final-sources span:nth-child(2),
		.final-sources span:nth-child(3) {
			right: 6%;
		}

		.landing-footer {
			grid-template-columns: 1fr auto;
		}

		.landing-footer > p {
			display: none;
		}

		.landing-footer > div a {
			display: none;
		}

		.landing-footer > div a.footer-legal {
			display: inline;
		}
	}

	@media (prefers-reduced-motion: reduce) {
		:global(html) {
			scroll-behavior: auto;
		}

		.landing *,
		.landing *::before,
		.landing *::after {
			scroll-behavior: auto !important;
			animation-duration: 0.01ms !important;
			animation-iteration-count: 1 !important;
			transition-duration: 0.01ms !important;
		}

		.reveal {
			opacity: 1;
			transform: none;
		}

		.intake-ring {
			display: none;
		}

		.hero-sticky,
		.hero-sticky * {
			cursor: auto;
		}
	}
</style>
