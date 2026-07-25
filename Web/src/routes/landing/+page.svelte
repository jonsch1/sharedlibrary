<script lang="ts">
	import { onMount } from 'svelte';
	import ArrowDownIcon from '@lucide/svelte/icons/arrow-down';
	import ArrowRightIcon from '@lucide/svelte/icons/arrow-right';
	import ArrowUpRightIcon from '@lucide/svelte/icons/arrow-up-right';
	import BotIcon from '@lucide/svelte/icons/bot';
	import CheckCircleIcon from '@lucide/svelte/icons/check-circle-2';
	import CommandIcon from '@lucide/svelte/icons/command';
	import FileTextIcon from '@lucide/svelte/icons/file-text';
	import GlobeIcon from '@lucide/svelte/icons/globe-2';
	import HeadphonesIcon from '@lucide/svelte/icons/headphones';
	import LayersIcon from '@lucide/svelte/icons/layers-3';
	import LinkIcon from '@lucide/svelte/icons/link-2';
	import LockIcon from '@lucide/svelte/icons/lock-keyhole';
	import MessageIcon from '@lucide/svelte/icons/message-circle';
	import PlayIcon from '@lucide/svelte/icons/play';
	import RssIcon from '@lucide/svelte/icons/rss';
	import SearchIcon from '@lucide/svelte/icons/search';
	import SparklesIcon from '@lucide/svelte/icons/sparkles';
	import VolumeIcon from '@lucide/svelte/icons/volume-2';

	type SourceCard = {
		id: string;
		kind: string;
		title: string;
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
			title: 'The AI that remembers',
			meta: '12:48 · Video',
			x: -69,
			y: 8,
			rotate: -7,
			tone: 'red'
		},
		{
			id: 'arxiv',
			kind: 'arXiv',
			title: 'Memory systems for agents',
			meta: 'Research paper',
			x: -48,
			y: -19,
			rotate: 6,
			tone: 'orange'
		},
		{
			id: 'x',
			kind: 'X',
			title: 'A useful thread on context',
			meta: '18 posts',
			x: -65,
			y: 29,
			rotate: 5,
			tone: 'ink'
		},
		{
			id: 'blog',
			kind: 'Blog',
			title: 'The shape of a good brief',
			meta: '8 min read',
			x: -34,
			y: 21,
			rotate: -5,
			tone: 'teal'
		},
		{
			id: 'podcast',
			kind: 'Podcast',
			title: 'Designing agents that remember',
			meta: '42 min · Audio',
			x: -51,
			y: 35,
			rotate: -3,
			tone: 'purple'
		},
		{
			id: 'pdf',
			kind: 'PDF',
			title: 'Field notes — context design',
			meta: '24 pages',
			x: -29,
			y: -31,
			rotate: 4,
			tone: 'blue'
		},
		{
			id: 'newsletter',
			kind: 'Newsletter',
			title: 'The context issue',
			meta: 'Saved from email',
			x: -71,
			y: -13,
			rotate: -4,
			tone: 'teal'
		},
		{
			id: 'web',
			kind: 'Web page',
			title: 'Building long-term memory',
			meta: '6 min read',
			x: -43,
			y: 3,
			rotate: 7,
			tone: 'blue'
		},
		{
			id: 'notes',
			kind: 'Notes',
			title: 'Ideas worth returning to',
			meta: 'Personal note',
			x: -23,
			y: 31,
			rotate: -6,
			tone: 'ink'
		},
		{
			id: 'report',
			kind: 'Report',
			title: 'State of agent infrastructure',
			meta: '32 pages',
			x: -61,
			y: -33,
			rotate: 3,
			tone: 'orange'
		}
	];

	const depthOptions = [
		{
			label: 'Brief',
			time: '20 sec',
			copy: 'Agent memory works best when context is curated, structured, and easy to retrieve.'
		},
		{
			label: 'Concise',
			time: '2 min',
			copy: 'Strong memory systems do more than store information. They compress useful context, preserve source links, and make the right detail easy to retrieve at the moment it matters.'
		},
		{
			label: 'Detailed',
			time: '7 min',
			copy: 'Agent memory is less a storage problem than a context-design problem. Useful systems decide what to retain, how to structure it, and which level of detail fits the task. Clear summaries, durable source links, and predictable Markdown give both people and agents a reliable surface to work from.'
		},
		{
			label: 'Comprehensive',
			time: '18 min',
			copy: 'A complete reading view preserves the source argument, supporting details, and practical implications while keeping the material navigable. Structured headings help an agent locate evidence; a stable original keeps the human reader grounded. The result is not another pile of notes, but a reusable context layer that can move from quick recall to deep work without losing provenance.'
		}
	];

	let viewportWidth = $state(1440);
	let viewportHeight = $state(900);
	let selectedDepth = $state(1);

	function sourceCardStyle(card: SourceCard, index: number): string {
		const mobileScale = viewportWidth < 720 ? 0.7 : 1;
		const x0 = card.x * viewportWidth * 0.01 * mobileScale;
		const y0 = card.y * viewportHeight * 0.01;
		const bend =
			(index % 2 === 0 ? -1 : 1) * viewportHeight * (0.035 + (index % 3) * 0.012);
		const x1 = x0 * 0.64;
		const y1 = y0 * 0.72 + bend;
		const x2 = x0 * 0.25;
		const y2 = y0 * 0.31 - bend * 0.45;
		const duration = 8.4 + (index % 4) * 0.85;
		const delay = -(index * 1.38 + 0.6);
		const scale = 0.82 + (index % 3) * 0.09;
		return [
			`--x0:${x0}px`,
			`--y0:${y0}px`,
			`--x1:${x1}px`,
			`--y1:${y1}px`,
			`--x2:${x2}px`,
			`--y2:${y2}px`,
			`--rotate:${card.rotate}deg`,
			`--rotate-1:${card.rotate * 0.64}deg`,
			`--rotate-2:${card.rotate * 0.22}deg`,
			`--source-scale:${scale}`,
			`animation-duration:${duration}s`,
			`animation-delay:${delay}s`
		].join(';');
	}

	onMount(() => {
		document.body.classList.add('landing-body');

		const updateViewport = (): void => {
			viewportWidth = window.innerWidth;
			viewportHeight = window.innerHeight;
		};

		const observer = new IntersectionObserver(
			(entries) => {
				for (const entry of entries) {
					if (entry.isIntersecting) entry.target.classList.add('is-visible');
				}
			},
			{ threshold: 0.14 }
		);

		document.querySelectorAll('.reveal').forEach((element) => observer.observe(element));
		window.addEventListener('resize', updateViewport, { passive: true });
		updateViewport();

		return () => {
			observer.disconnect();
			document.body.classList.remove('landing-body');
			window.removeEventListener('resize', updateViewport);
		};
	});
</script>

<svelte:head>
	<title>Briefly — Turn what you find into what you know</title>
	<meta
		name="description"
		content="Capture videos, papers, posts, podcasts, and pages. Briefly turns every source into a private, searchable, agent-ready library."
	/>
	<meta property="og:type" content="website" />
	<meta property="og:title" content="Briefly — Turn what you find into what you know" />
	<meta
		property="og:description"
		content="Capture anything. Understand it at any depth. Keep the context ready for you and your agents."
	/>
	<meta property="og:url" content="https://www.readbriefly.fyi/landing" />
	<meta property="og:image" content="https://www.readbriefly.fyi/og-landing.png" />
	<meta name="twitter:card" content="summary_large_image" />
	<meta name="twitter:title" content="Briefly — Turn what you find into what you know" />
	<meta
		name="twitter:description"
		content="Your private, searchable, agent-ready library."
	/>
	<meta name="twitter:image" content="https://www.readbriefly.fyi/og-landing.png" />
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
		</nav>

		<a class="nav-cta" href="/">
			Open Briefly
			<ArrowUpRightIcon aria-hidden="true" />
		</a>
	</header>

	<main>
		<section class="hero-scroll">
			<div class="hero-sticky">
				<div class="hero-grid" aria-hidden="true"></div>

				<div class="hero-copy">
					<div class="eyebrow"><span></span> Your second brain, with taste</div>
					<h1>Turn what you find<br />into what you know.</h1>
					<p>
						Capture any source in seconds. Briefly turns the internet into a private,
						searchable library—ready for you and your agents.
					</p>
					<div class="hero-actions">
						<a class="button button-primary" href="/">
							Open your library
							<ArrowRightIcon aria-hidden="true" />
						</a>
						<a class="text-link" href="#how">
							See how it works
							<ArrowDownIcon aria-hidden="true" />
						</a>
					</div>
				</div>

				<div class="gather-stage" aria-hidden="true">
					<div class="gather-orbit"></div>
					<div class="stream-rays">
						{#each Array(8) as _, index}
							<span
								style={`--ray-top:${18 + index * 8}%;--ray-height:${18 + index * 4}px;--ray-rotate:${-4 + index * 1.15}deg;--ray-delay:${index * -0.42}s;--ray-pulse-delay:${index * -0.31}s`}
							></span>
						{/each}
					</div>
					<div class="stream-particles">
						{#each Array(12) as _, index}
							<i
								style={`--particle-x:${-68 + index * 3.8}vw;--particle-y:${-22 + (index % 6) * 8}vh;--particle-delay:${index * -0.41}s`}
							></i>
						{/each}
					</div>
					<div class="gather-logo">
						<span class="logo-halo"></span>
						<span class="intake-ring intake-ring-one"></span>
						<span class="intake-ring intake-ring-two"></span>
						<img src="/icons/icon-512.png" alt="" />
					</div>

					{#each sourceCards as card, index}
						<article
							class="source-card source-card-{card.tone}"
							style={sourceCardStyle(card, index)}
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
								<span class="source-status"></span>
							</div>
							<strong>{card.title}</strong>
							<small>{card.meta}</small>
						</article>
					{/each}
					<div class="intake-label"><span></span> Always gathering</div>
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

			<div class="flow-canvas reveal">
				<div class="flow-noise" aria-hidden="true"></div>
				<div class="flow-inputs">
					<div class="mini-source"><PlayIcon /><span>YouTube</span></div>
					<div class="mini-source"><FileTextIcon /><span>arXiv</span></div>
					<div class="mini-source"><RssIcon /><span>Blog</span></div>
					<div class="mini-source"><HeadphonesIcon /><span>Podcast</span></div>
				</div>

				<div class="flow-line flow-line-in"><span></span></div>

				<div class="flow-core">
					<div class="shortcut">
						<kbd><CommandIcon /> C</kbd>
						<i></i>
						<kbd><CommandIcon /> G</kbd>
					</div>
					<div class="core-mark">
						<span></span>
						<img src="/icons/icon-192.png" alt="" />
					</div>
					<strong>Briefly</strong>
					<small>Capture in seconds</small>
				</div>

				<div class="flow-line flow-line-out"><span></span></div>

				<div class="flow-output">
					<div class="stack-card stack-back"></div>
					<div class="stack-card stack-mid"></div>
					<div class="stack-card stack-front">
						<div class="doc-toolbar"><i></i><i></i><i></i><span>briefly.md</span></div>
						<div class="doc-title"></div>
						<div class="doc-line long"></div>
						<div class="doc-line"></div>
						<div class="doc-line short"></div>
						<div class="doc-tag">AGENT-READY</div>
					</div>
				</div>
			</div>

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

			<div class="depth-demo reveal">
				<div class="demo-chrome">
					<div class="chrome-dots"><i></i><i></i><i></i></div>
					<span>Memory systems for agents</span>
					<button type="button" aria-label="Open document menu">•••</button>
				</div>

				<div class="demo-body">
					<div class="depth-tabs" role="tablist" aria-label="Reading depth">
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

					<div class="demo-document" aria-live="polite">
						<div class="document-meta">
							<span>{depthOptions[selectedDepth].label} view</span>
							<span>{depthOptions[selectedDepth].time} read</span>
						</div>
						<h3>Why context design matters</h3>
						<p>{depthOptions[selectedDepth].copy}</p>
						{#if selectedDepth > 1}
							<h4>Retrieval over accumulation</h4>
							<p class="supporting-copy">
								The value of a library is measured by what you can reuse, not what you can
								collect.
							</p>
						{/if}
						{#if selectedDepth > 2}
							<div class="document-callout">
								<strong>Practical takeaway</strong>
								<span>Keep the source, structure the insight, preserve the path back.</span>
							</div>
						{/if}
					</div>
				</div>
			</div>
		</section>

		<section class="agents-section" id="agents">
			<div class="agents-inner section-shell">
				<div class="agents-visual reveal">
					<div class="file-tree">
						<div class="tree-header">
							<span><LayersIcon /> BRIEFLY</span>
							<i></i>
						</div>
						<div class="tree-row folder"><span>⌄</span> library</div>
						<div class="tree-row nested"><FileTextIcon /> agent-memory.md</div>
						<div class="tree-row nested"><FileTextIcon /> context-design.md</div>
						<div class="tree-row nested"><FileTextIcon /> retrieval-notes.md</div>
						<div class="tree-row"><FileTextIcon /> topics.md</div>
						<div class="tree-row active"><BotIcon /> AGENTS.md</div>
					</div>
					<div class="code-pane">
						<div class="code-header">
							<span><FileTextIcon /> agent-memory.md</span>
							<i>Markdown</i>
						</div>
						<div class="code-body">
							<p><b># Agent memory systems</b></p>
							<p class="code-muted">Source: arxiv.org/abs/...</p>
							<p><em>## Key idea</em></p>
							<p>Useful memory is curated context,</p>
							<p>not an ever-growing transcript.</p>
							<p><em>## Implications</em></p>
							<p><span>-</span> preserve provenance</p>
							<p><span>-</span> retrieve by task</p>
							<p><span>-</span> match the level of detail</p>
						</div>
						<div class="agent-ready-pill"><SparklesIcon /> Ready for an agent</div>
					</div>
				</div>

				<div class="agents-copy reveal">
					<div class="section-number">04 / BUILT FOR AGENTS</div>
					<h2>Context,<br />without the cleanup.</h2>
					<p>
						Your library is written in plain Markdown with clear titles, useful headings, and
						source links. Humans can read it. Agents can work with it.
					</p>
					<ul>
						<li><CheckCircleIcon /> Predictable Markdown files</li>
						<li><CheckCircleIcon /> Source-aware summaries</li>
						<li><CheckCircleIcon /> A workspace agents can navigate</li>
					</ul>
					<a class="button button-light" href="/">
						Open Briefly
						<ArrowRightIcon aria-hidden="true" />
					</a>
				</div>
			</div>
		</section>

		<section class="privacy-section section-shell">
			<div class="privacy-heading reveal">
				<div class="section-number">05 / YOURS MEANS YOURS</div>
				<h2>Your library is not our content farm.</h2>
			</div>
			<div class="privacy-grid">
				<article class="reveal">
					<div class="privacy-icon"><LockIcon /></div>
					<h3>Private by default</h3>
					<p>Your complete library stays in your own workspace and Google Drive.</p>
				</article>
				<article class="reveal">
					<div class="privacy-icon"><GlobeIcon /></div>
					<h3>Offline when you need it</h3>
					<p>Your mirrored library remains readable even when the connection does not.</p>
				</article>
				<article class="reveal">
					<div class="privacy-icon"><ArrowUpRightIcon /></div>
					<h3>Shared on purpose</h3>
					<p>Publish a deliberate link when something is worth passing on.</p>
				</article>
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
				<a class="button button-white" href="/">
					Open your library
					<ArrowRightIcon aria-hidden="true" />
				</a>
				<span class="final-note">Capture in seconds. Read at any depth.</span>
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
			<a href="#how">How it works</a>
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
		background:
			radial-gradient(circle at 78% 58%, rgb(22 77 255 / 14%), transparent 25%),
			linear-gradient(180deg, #fbf8f0 0%, var(--paper) 100%);
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

	.hero-copy .eyebrow {
		display: inline-flex;
		align-items: center;
		gap: 9px;
		margin-bottom: 20px;
		color: #173ea8;
		font-size: 11px;
		font-weight: 760;
		letter-spacing: 0.16em;
		text-transform: uppercase;
	}

	.hero-copy .eyebrow span {
		width: 6px;
		height: 6px;
		border-radius: 50%;
		background: var(--blue);
		box-shadow: 0 0 0 5px rgb(22 77 255 / 12%);
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
		top: 58%;
		left: 79%;
		width: 1px;
		height: 1px;
	}

	.gather-logo {
		position: absolute;
		z-index: 20;
		top: 50%;
		left: 50%;
		width: clamp(190px, 16vw, 250px);
		aspect-ratio: 1;
		margin: calc(clamp(190px, 16vw, 250px) / -2);
		animation: logo-float 5s ease-in-out infinite;
	}

	.gather-logo img {
		position: relative;
		z-index: 4;
		width: 100%;
		height: 100%;
		filter: drop-shadow(0 34px 34px rgb(6 24 80 / 28%));
	}

	.logo-halo {
		position: absolute;
		z-index: 1;
		inset: -70%;
		border-radius: 50%;
		background: radial-gradient(circle, rgb(28 82 255 / 26%), transparent 62%);
		animation: halo-breathe 3.2s ease-in-out infinite;
	}

	.gather-orbit {
		position: absolute;
		top: 50%;
		left: 50%;
		width: min(42vw, 620px);
		aspect-ratio: 1;
		border: 1px solid rgb(22 77 255 / 10%);
		border-radius: 50%;
		transform: translate(-50%, -50%);
	}

	.gather-orbit::before,
	.gather-orbit::after {
		position: absolute;
		border: 1px solid rgb(22 77 255 / 7%);
		border-radius: 50%;
		content: '';
	}

	.gather-orbit::before {
		inset: 13%;
	}

	.gather-orbit::after {
		inset: 28%;
	}

	.stream-rays {
		position: absolute;
		z-index: 1;
		top: 0;
		right: -15px;
		width: min(77vw, 1180px);
		height: 48vh;
		transform: translateY(-50%);
	}

	.stream-rays span {
		position: absolute;
		top: var(--ray-top);
		right: 0;
		width: 100%;
		height: var(--ray-height);
		border-top: 1px solid rgb(41 91 255 / 16%);
		border-radius: 50%;
		transform: rotate(var(--ray-rotate));
		transform-origin: right center;
		animation: stream-shimmer 3.8s ease-in-out infinite;
		animation-delay: var(--ray-delay);
	}

	.stream-rays span::after {
		position: absolute;
		top: -2px;
		left: 0;
		width: 64px;
		height: 3px;
		border-radius: 50%;
		background: linear-gradient(90deg, transparent, rgb(85 126 255 / 90%), transparent);
		content: '';
		filter: blur(1px);
		animation: ray-pulse 3.3s ease-in-out infinite;
		animation-delay: var(--ray-pulse-delay);
	}

	.stream-particles {
		position: absolute;
		z-index: 2;
		inset: 0;
	}

	.stream-particles i {
		position: absolute;
		width: 3px;
		height: 3px;
		border-radius: 50%;
		background: #6f98ff;
		box-shadow: 0 0 10px #3f73ff;
		animation: particle-ingest 3.6s linear infinite;
		animation-delay: var(--particle-delay);
	}

	.intake-ring {
		position: absolute;
		z-index: 3;
		inset: -8%;
		border: 1px solid rgb(57 106 255 / 34%);
		border-radius: 30%;
		opacity: 0;
		animation: intake-ring 2.4s ease-out infinite;
	}

	.intake-ring-two {
		animation-delay: -1.2s;
	}

	.intake-label {
		position: absolute;
		z-index: 22;
		top: clamp(120px, 10vw, 155px);
		left: 50%;
		display: flex;
		width: max-content;
		align-items: center;
		gap: 8px;
		padding: 8px 11px;
		border: 1px solid rgb(22 77 255 / 12%);
		border-radius: 999px;
		background: rgb(255 255 255 / 62%);
		color: #173ea8;
		font-size: 8px;
		font-weight: 760;
		letter-spacing: 0.13em;
		text-transform: uppercase;
		transform: translateX(-50%);
		backdrop-filter: blur(12px);
	}

	.intake-label span {
		width: 5px;
		height: 5px;
		border-radius: 50%;
		background: #42a45c;
		box-shadow: 0 0 0 3px rgb(66 164 92 / 14%);
	}

	.source-card {
		position: absolute;
		z-index: 8;
		top: 50%;
		left: 50%;
		display: flex;
		width: clamp(148px, 13vw, 196px);
		min-height: 98px;
		flex-direction: column;
		padding: 12px 13px 13px;
		border: 1px solid rgb(17 17 15 / 15%);
		border-radius: 14px;
		background:
			linear-gradient(145deg, rgb(255 255 255 / 93%), rgb(241 237 226 / 96%)),
			var(--paper-bright);
		box-shadow:
			0 20px 45px rgb(27 25 17 / 13%),
			inset 0 1px 0 white;
		transform-origin: center;
		will-change: transform, filter, opacity;
		animation-name: ingest-card;
		animation-timing-function: linear;
		animation-iteration-count: infinite;
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

	.source-status {
		width: 5px;
		height: 5px;
		margin-left: auto;
		border-radius: 50%;
		background: #42a45c;
		box-shadow: 0 0 0 3px rgb(66 164 92 / 12%);
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
		margin-top: 11px;
		font-size: 12px;
		letter-spacing: -0.025em;
		line-height: 1.15;
	}

	.source-card small {
		margin-top: 5px;
		color: rgb(17 17 15 / 48%);
		font-size: 9px;
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

	.shortcut kbd {
		display: flex;
		height: 35px;
		align-items: center;
		gap: 3px;
		padding: 0 9px;
		border: 1px solid rgb(255 255 255 / 16%);
		border-radius: 8px;
		background: rgb(255 255 255 / 9%);
		box-shadow: inset 0 -2px 0 rgb(0 0 0 / 26%);
		color: rgb(255 255 255 / 78%);
		font-family: inherit;
		font-size: 11px;
	}

	.shortcut kbd :global(svg) {
		width: 11px;
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

	.core-mark img {
		position: relative;
		z-index: 2;
		width: 100%;
		filter: drop-shadow(0 24px 30px rgb(0 0 0 / 35%));
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

	.depth-demo {
		overflow: hidden;
		border: 1px solid rgb(17 17 15 / 18%);
		border-radius: 22px;
		background: #ddd7ca;
		box-shadow: 0 35px 80px rgb(43 36 22 / 17%);
		transform: rotate(1.2deg);
		transition: transform 350ms ease;
	}

	.depth-demo:hover {
		transform: rotate(0);
	}

	.demo-chrome {
		display: grid;
		height: 48px;
		grid-template-columns: 1fr auto 1fr;
		align-items: center;
		padding: 0 14px;
		border-bottom: 1px solid rgb(17 17 15 / 12%);
		background: #cec7ba;
	}

	.chrome-dots {
		display: flex;
		gap: 5px;
	}

	.chrome-dots i {
		width: 7px;
		height: 7px;
		border-radius: 50%;
		background: rgb(17 17 15 / 18%);
	}

	.demo-chrome > span {
		font-size: 10px;
		font-weight: 710;
	}

	.demo-chrome > button {
		justify-self: end;
		border: 0;
		background: none;
		color: rgb(17 17 15 / 46%);
		cursor: pointer;
	}

	.demo-body {
		display: grid;
		min-height: 540px;
		grid-template-columns: 190px 1fr;
	}

	.depth-tabs {
		display: flex;
		flex-direction: column;
		gap: 5px;
		padding: 18px;
		border-right: 1px solid rgb(17 17 15 / 11%);
		background: #d7d0c3;
	}

	.depth-tabs button {
		display: flex;
		height: 48px;
		align-items: center;
		gap: 10px;
		padding: 0 12px;
		border: 1px solid transparent;
		border-radius: 10px;
		background: transparent;
		color: rgb(17 17 15 / 55%);
		font-family: inherit;
		font-size: 11px;
		font-weight: 660;
		text-align: left;
		cursor: pointer;
		transition:
			background 180ms ease,
			color 180ms ease,
			border-color 180ms ease;
	}

	.depth-tabs button span {
		display: grid;
		width: 21px;
		height: 21px;
		place-items: center;
		border: 1px solid rgb(17 17 15 / 14%);
		border-radius: 7px;
		font-size: 8px;
	}

	.depth-tabs button.active {
		border-color: rgb(22 77 255 / 18%);
		background: #f3efe5;
		box-shadow: 0 7px 18px rgb(40 34 23 / 8%);
		color: var(--blue);
	}

	.depth-tabs button.active span {
		border-color: var(--blue);
		background: var(--blue);
		color: white;
	}

	.demo-document {
		padding: clamp(30px, 4vw, 58px);
		background:
			linear-gradient(rgb(17 17 15 / 2.5%) 1px, transparent 1px),
			#f9f6ee;
		background-size: 100% 28px;
	}

	.document-meta {
		display: flex;
		justify-content: space-between;
		color: var(--blue);
		font-size: 8px;
		font-weight: 790;
		letter-spacing: 0.12em;
		text-transform: uppercase;
	}

	.demo-document h3 {
		margin: 36px 0 28px;
		font-size: clamp(28px, 3.2vw, 46px);
		letter-spacing: -0.055em;
		line-height: 1;
	}

	.demo-document > p {
		margin: 0;
		color: rgb(17 17 15 / 67%);
		font-family: Georgia, serif;
		font-size: 16px;
		line-height: 1.75;
	}

	.demo-document h4 {
		margin: 34px 0 13px;
		font-size: 14px;
	}

	.demo-document .supporting-copy {
		font-size: 14px;
	}

	.document-callout {
		display: flex;
		flex-direction: column;
		gap: 6px;
		margin-top: 30px;
		padding: 16px;
		border-left: 3px solid var(--blue);
		background: rgb(22 77 255 / 6%);
	}

	.document-callout strong {
		color: var(--blue);
		font-size: 9px;
		letter-spacing: 0.11em;
		text-transform: uppercase;
	}

	.document-callout span {
		font-family: Georgia, serif;
		font-size: 12px;
		line-height: 1.5;
	}

	.agents-section {
		padding: clamp(110px, 14vw, 210px) 0;
		overflow: hidden;
		background:
			radial-gradient(circle at 20% 50%, rgb(28 83 255 / 18%), transparent 30%),
			#030b24;
		color: white;
	}

	.agents-inner {
		display: grid;
		grid-template-columns: 1.2fr 0.8fr;
		gap: clamp(70px, 9vw, 150px);
		align-items: center;
	}

	.agents-visual {
		display: grid;
		min-height: 540px;
		grid-template-columns: 220px 1fr;
		overflow: hidden;
		border: 1px solid rgb(255 255 255 / 11%);
		border-radius: 22px;
		background: #071433;
		box-shadow: 0 35px 80px rgb(0 0 0 / 35%);
		transform: perspective(1200px) rotateY(4deg) rotateX(1deg);
		transform-origin: right center;
	}

	.file-tree {
		padding: 17px 10px;
		border-right: 1px solid rgb(255 255 255 / 8%);
		background: rgb(0 0 0 / 16%);
		color: rgb(255 255 255 / 62%);
	}

	.tree-header {
		display: flex;
		align-items: center;
		justify-content: space-between;
		padding: 0 8px 15px;
		color: rgb(255 255 255 / 42%);
		font-size: 8px;
		font-weight: 740;
		letter-spacing: 0.1em;
	}

	.tree-header span {
		display: flex;
		align-items: center;
		gap: 6px;
	}

	.tree-header :global(svg) {
		width: 11px;
	}

	.tree-header i {
		width: 4px;
		height: 4px;
		border-radius: 50%;
		background: #57d579;
		box-shadow: 0 0 8px #57d579;
	}

	.tree-row {
		display: flex;
		height: 32px;
		align-items: center;
		gap: 7px;
		padding: 0 8px;
		border-radius: 6px;
		font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
		font-size: 9px;
	}

	.tree-row :global(svg) {
		width: 12px;
	}

	.tree-row.nested {
		padding-left: 27px;
	}

	.tree-row.folder {
		color: rgb(255 255 255 / 82%);
	}

	.tree-row.active {
		background: rgb(58 107 255 / 18%);
		color: #9fbbff;
	}

	.code-pane {
		position: relative;
	}

	.code-header {
		display: flex;
		height: 48px;
		align-items: center;
		justify-content: space-between;
		padding: 0 18px;
		border-bottom: 1px solid rgb(255 255 255 / 8%);
		color: rgb(255 255 255 / 56%);
		font-size: 9px;
	}

	.code-header span {
		display: flex;
		align-items: center;
		gap: 7px;
	}

	.code-header :global(svg) {
		width: 12px;
	}

	.code-header i {
		font-style: normal;
	}

	.code-body {
		padding: clamp(30px, 4vw, 54px);
		font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
		font-size: clamp(10px, 1vw, 13px);
		line-height: 1.9;
	}

	.code-body p {
		margin: 0;
		color: rgb(255 255 255 / 72%);
	}

	.code-body b {
		color: white;
		font-size: 1.3em;
	}

	.code-body em {
		color: #82a7ff;
		font-style: normal;
	}

	.code-body span {
		color: #65dc8b;
	}

	.code-body .code-muted {
		margin: 4px 0 25px;
		color: rgb(255 255 255 / 30%);
	}

	.agent-ready-pill {
		position: absolute;
		right: 24px;
		bottom: 22px;
		display: flex;
		align-items: center;
		gap: 7px;
		padding: 8px 11px;
		border: 1px solid rgb(105 220 139 / 22%);
		border-radius: 999px;
		background: rgb(73 192 107 / 10%);
		color: #7de39b;
		font-size: 8px;
		font-weight: 720;
		letter-spacing: 0.08em;
		text-transform: uppercase;
	}

	.agent-ready-pill :global(svg) {
		width: 12px;
	}

	.agents-copy .section-number {
		color: #82a7ff;
	}

	.agents-copy h2 {
		font-size: clamp(58px, 6.5vw, 100px);
	}

	.agents-copy > p {
		margin: 32px 0 0;
		color: rgb(255 255 255 / 61%);
		font-size: 17px;
		letter-spacing: -0.02em;
		line-height: 1.6;
	}

	.agents-copy ul {
		display: grid;
		gap: 14px;
		margin: 35px 0;
		padding: 0;
		list-style: none;
		color: rgb(255 255 255 / 78%);
		font-size: 13px;
	}

	.agents-copy li {
		display: flex;
		align-items: center;
		gap: 10px;
	}

	.agents-copy li :global(svg) {
		width: 16px;
		color: #6ee08f;
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

	@keyframes ingest-card {
		0% {
			opacity: 0;
			filter: blur(4px);
			transform: translate3d(var(--x0), var(--y0), 0) rotate(var(--rotate))
				scale(var(--source-scale));
		}
		8% {
			opacity: 1;
			filter: blur(0);
		}
		38% {
			opacity: 1;
			transform: translate3d(var(--x1), var(--y1), 0) rotate(var(--rotate-1)) scale(0.86);
		}
		74% {
			opacity: 1;
			filter: blur(0);
			transform: translate3d(var(--x2), var(--y2), 0) rotate(var(--rotate-2)) scale(0.54);
		}
		92% {
			opacity: 0.9;
		}
		100% {
			opacity: 0;
			filter: blur(7px);
			transform: translate3d(0, 0, 0) rotate(0) scale(0.06);
		}
	}

	@keyframes logo-float {
		0%,
		100% {
			transform: translateY(-4px);
		}
		50% {
			transform: translateY(5px);
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

	@keyframes stream-shimmer {
		0%,
		100% {
			border-color: rgb(41 91 255 / 9%);
		}
		50% {
			border-color: rgb(41 91 255 / 28%);
		}
	}

	@keyframes ray-pulse {
		0% {
			opacity: 0;
			transform: translateX(0);
		}
		18% {
			opacity: 0.85;
		}
		85% {
			opacity: 0.7;
		}
		100% {
			opacity: 0;
			transform: translateX(calc(min(77vw, 1180px) - 64px));
		}
	}

	@keyframes particle-ingest {
		0% {
			opacity: 0;
			transform: translate3d(var(--particle-x), var(--particle-y), 0) scale(0.4);
		}
		16% {
			opacity: 0.85;
		}
		82% {
			opacity: 0.7;
		}
		100% {
			opacity: 0;
			transform: translate3d(0, 0, 0) scale(0.1);
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

	@media (max-width: 1050px) {
		.landing-nav {
			grid-template-columns: 1fr 1fr;
		}

		.landing-nav nav {
			display: none;
		}

		.attention-grid,
		.flow-heading,
		.depth-section,
		.agents-inner {
			grid-template-columns: 1fr;
		}

		.attention-copy,
		.flow-heading > p,
		.depth-copy > p,
		.agents-copy {
			max-width: 650px;
		}

		.flow-canvas {
			grid-template-columns: 1fr 0.35fr 0.8fr 0.35fr 1fr;
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
			grid-row: 1;
		}

		.privacy-heading {
			grid-template-columns: 1fr;
			gap: 32px;
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

		.hero-copy .eyebrow {
			margin-bottom: 17px;
			font-size: 9px;
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

		.button {
			min-height: 46px;
			padding: 0 17px;
			font-size: 12px;
		}

		.hero-actions .text-link {
			display: none;
		}

		.gather-stage {
			top: 70%;
			left: 74%;
		}

		.gather-orbit {
			width: 92vw;
		}

		.gather-logo {
			width: 160px;
			margin: -80px;
		}

		.stream-rays {
			width: 100vw;
			height: 36vh;
		}

		.source-card {
			width: 128px;
			min-height: 84px;
			padding: 10px;
			border-radius: 13px;
		}

		.source-card strong {
			margin-top: 9px;
			font-size: 11px;
		}

		.source-card small {
			font-size: 8px;
		}

		.source-topline {
			font-size: 8px;
		}

		.source-icon {
			width: 19px;
			height: 19px;
		}

		.intake-label {
			top: 98px;
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
		.privacy-heading h2 {
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

		.depth-demo {
			border-radius: 16px;
			transform: none;
		}

		.demo-body {
			min-height: 600px;
			grid-template-columns: 1fr;
		}

		.depth-tabs {
			display: grid;
			grid-template-columns: repeat(4, 1fr);
			padding: 10px;
			border-right: 0;
			border-bottom: 1px solid rgb(17 17 15 / 11%);
		}

		.depth-tabs button {
			height: auto;
			flex-direction: column;
			gap: 6px;
			padding: 9px 4px;
			font-size: 8px;
			text-align: center;
		}

		.depth-tabs button span {
			width: 18px;
			height: 18px;
		}

		.demo-document {
			padding: 30px 24px;
		}

		.agents-inner {
			gap: 60px;
		}

		.agents-visual {
			min-height: 470px;
			grid-template-columns: 1fr;
			transform: none;
		}

		.file-tree {
			display: none;
		}

		.privacy-grid article {
			min-height: 240px;
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

		.source-card,
		.stream-rays,
		.stream-particles,
		.intake-ring {
			display: none;
		}

		.gather-logo {
			animation: none !important;
		}
	}
</style>
