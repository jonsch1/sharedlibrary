<script lang="ts">
	import { onMount } from 'svelte';

	onMount(() => {
		document.body.classList.add('landing-body');
		return () => document.body.classList.remove('landing-body');
	});
</script>

<svelte:head>
	<title>Briefly — Stay curious. Skip the feed.</title>
	<meta
		name="description"
		content="Save what interests you, understand it at the depth you choose, and keep up with trusted sources without living in a feed."
	/>
	<meta property="og:type" content="website" />
	<meta property="og:title" content="Briefly — Stay curious. Skip the feed." />
	<meta
		property="og:description"
		content="A quieter way to understand what matters and keep it close."
	/>
	<meta property="og:url" content="https://www.readbriefly.fyi/landing" />
	<meta property="og:image" content="https://www.readbriefly.fyi/og-landing.png" />
	<meta name="twitter:card" content="summary_large_image" />
	<meta name="twitter:title" content="Briefly — Stay curious. Skip the feed." />
	<meta
		name="twitter:description"
		content="A quieter way to understand what matters and keep it close."
	/>
	<meta name="twitter:image" content="https://www.readbriefly.fyi/og-landing.png" />
</svelte:head>

<div class="landing">
	<header class="landing-nav section-shell">
		<a class="landing-brand" href="/landing" aria-label="Briefly home">
			<img src="/brand/briefly-wordmark.svg" alt="" />
		</a>

		<nav aria-label="Main navigation">
			<a href="#how-it-works">How it works</a>
			<a href="#briefs">Briefs</a>
		</nav>

		<div class="nav-actions">
			<a class="nav-cta" href="#get-briefly">Get Briefly</a>
		</div>
	</header>

	<main>
		<section class="hero section-shell">
			<div class="hero-inner">
				<div class="hero-message">
					<h1>Stay curious. Skip the feed.</h1>
					<p>
						Save what interests you. Briefly gives you the useful version, at the depth you
						choose.
					</p>
					<a class="button button-primary" href="#get-briefly">Get Briefly</a>
				</div>

				<div class="hero-product">
					<img
						class="hero-mac"
						src="/landing-mac.webp"
						alt="Briefly on Mac showing a saved article at the selected reading depth"
						width="2400"
						height="1620"
						fetchpriority="high"
					/>
					<img
						class="hero-phone"
						src="/landing-iphone.webp"
						alt="Briefly on iPhone playing an audio brief"
						width="738"
						height="1600"
						fetchpriority="high"
					/>
				</div>
			</div>
		</section>

		<section class="outcomes section-shell" id="how-it-works">
			<div class="section-heading">
				<p class="eyebrow">How it works</p>
				<h2>Save more.<br />Read less.</h2>
				<p>
					Briefly turns the things you want to read into a private library of clear summaries.
				</p>
			</div>

			<ol class="outcome-list">
				<li>
					<span>01</span>
					<h3>Save anything.</h3>
					<p>Send an article, video, podcast, or note to Briefly and get back to your day.</p>
				</li>
				<li>
					<span>02</span>
					<h3>Get the point.</h3>
					<p>Start with a short summary. Read more only when you want to.</p>
				</li>
				<li>
					<span>03</span>
					<h3>Find it again.</h3>
					<p>Keep everything in one private, searchable library.</p>
				</li>
			</ol>
		</section>

		<section class="depth-panel section-shell" aria-labelledby="depth-title">
			<div class="depth-copy">
				<p class="eyebrow">Choose the length</p>
				<h2 id="depth-title">Read as much as you want.</h2>
				<p>
					Start with the shortest summary. Add more detail when you need it.
				</p>
			</div>

			<ol class="depth-list" aria-label="Available reading depths">
				<li><span>Brief</span><strong>Know the point.</strong></li>
				<li><span>Concise</span><strong>Get the key ideas.</strong></li>
				<li><span>Detailed</span><strong>Add the context.</strong></li>
				<li><span>Comprehensive</span><strong>Get the full story.</strong></li>
			</ol>
		</section>

		<section class="briefs" id="briefs">
			<div class="briefs-inner section-shell">
				<div class="briefs-copy">
					<p class="eyebrow">Follow your sources</p>
					<h2>Keep up without the feed.</h2>
					<p>
						Choose the sources you trust. Briefly collects what is new into one cited brief
						you can read or listen to.
					</p>
				</div>

				<div class="brief-path" aria-label="Sources become one scheduled brief">
					<div><span>01</span><strong>Sources you choose</strong></div>
					<i aria-hidden="true"></i>
					<div><span>02</span><strong>One cited brief</strong></div>
					<i aria-hidden="true"></i>
					<div><span>03</span><strong>Read or listen</strong></div>
				</div>
			</div>
		</section>

		<section class="privacy section-shell">
			<p class="eyebrow">Private by default</p>
			<h2>Your library stays private.</h2>
			<p>
				It stays on your Apple devices and iCloud. Nothing is public unless you share it.
			</p>
		</section>

		<section class="final-cta section-shell" id="get-briefly">
			<img src="/brand/briefly-mark.svg" alt="" />
			<h2>Make space for what matters.</h2>
			<p>Briefly is coming to Mac and iPhone.</p>
			<span class="availability">Coming to the App Store</span>
		</section>
	</main>

	<footer class="landing-footer section-shell">
		<a class="landing-brand" href="/landing">
			<img src="/brand/briefly-wordmark.svg" alt="Briefly" />
		</a>
		<p>A quieter way to stay curious.</p>
		<div>
			<a href="/feedback">Feedback</a>
			<a href="/privacy">Privacy</a>
			<a href="/terms">Terms</a>
			<a href="/cookies">Cookies</a>
			<a href="/imprint">Imprint</a>
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
		background: #fbfaf7;
		color: #10372d;
	}

	:global(body.landing-body *) {
		box-sizing: border-box;
	}

	.landing {
		--paper: #fffaf1;
		--forest: #10372d;
		--forest-deep: #082a22;
		--orange: #d85312;
		--line: rgb(16 55 45 / 15%);
		min-height: 100vh;
		overflow: clip;
		background: #fbfaf7;
		color: var(--forest);
		font-family: 'DM Sans Variable', 'DM Sans', sans-serif;
	}

	.landing :global(*) {
		box-sizing: border-box;
	}

	.landing a {
		color: inherit;
		text-decoration: none;
	}

	.landing a {
		-webkit-tap-highlight-color: transparent;
	}

	.section-shell {
		width: min(100% - 48px, 1280px);
		margin-inline: auto;
	}

	.landing-nav {
		position: relative;
		z-index: 20;
		display: grid;
		grid-template-columns: 1fr auto 1fr;
		align-items: center;
		padding-block: 18px;
	}

	.landing-brand {
		display: inline-flex;
		width: fit-content;
		align-items: center;
	}

	.landing-brand img {
		display: block;
		width: 122px;
		height: auto;
	}

	.landing-nav .landing-brand {
		width: 122px;
	}

	.landing-nav nav,
	.nav-actions {
		display: flex;
		align-items: center;
		gap: 28px;
		font-size: 14px;
	}

	.landing-nav nav a {
		transition: opacity 160ms ease;
	}

	.landing-nav nav a:hover {
		opacity: 0.58;
	}

	.nav-actions {
		justify-self: end;
	}

	.nav-cta {
		padding: 11px 17px;
		border: 1px solid var(--forest);
		border-radius: 999px;
		background: var(--forest);
		color: var(--paper) !important;
		font-weight: 650;
	}

	.hero {
		position: relative;
		min-height: 830px;
		padding: 64px 28px 0;
		overflow: hidden;
		border-radius: 24px;
		background: #f0f1ee;
	}

	.hero-inner {
		display: flex;
		min-height: 766px;
		flex-direction: column;
		align-items: center;
		text-align: center;
	}

	.hero-message {
		position: relative;
		z-index: 2;
	}

	.hero h1,
	.section-heading h2,
	.depth-copy h2,
	.briefs h2,
	.privacy h2,
	.final-cta h2 {
		margin: 0;
		font-family: 'Source Serif 4 Variable', Georgia, serif;
		font-weight: 480;
		letter-spacing: -0.055em;
		line-height: 0.98;
	}

	.hero h1 {
		max-width: 980px;
		font-size: clamp(50px, 6vw, 80px);
		line-height: 1.02;
	}

	.hero-message p {
		max-width: 700px;
		margin: 20px auto 0;
		color: rgb(16 55 45 / 76%);
		font-size: clamp(16px, 1.4vw, 19px);
		line-height: 1.55;
	}

	.button {
		display: inline-flex;
		min-height: 52px;
		align-items: center;
		justify-content: center;
		padding: 0 23px;
		border-radius: 8px;
		font-size: 14px;
		font-weight: 700;
	}

	.button-primary {
		margin-top: 27px;
		box-shadow: 0 12px 28px rgb(16 55 45 / 15%);
		background: var(--forest);
		color: white !important;
	}

	.hero-product {
		position: relative;
		width: min(100%, 1040px);
		margin-top: 42px;
	}

	.hero-mac {
		display: block;
		width: 100%;
		height: auto;
		filter: drop-shadow(0 24px 32px rgb(8 42 34 / 13%));
	}

	.hero-phone {
		position: absolute;
		right: -1%;
		bottom: 3%;
		width: clamp(145px, 19vw, 225px);
		height: auto;
		border: 4px solid #111315;
		border-radius: 13% / 6%;
		box-shadow: 0 24px 50px rgb(8 42 34 / 24%);
	}

	.eyebrow {
		margin: 0 0 18px;
		color: var(--orange);
		font-size: 11px;
		font-weight: 750;
		letter-spacing: 0.18em;
		line-height: 1.4;
		text-transform: uppercase;
	}

	.outcomes {
		padding-block: clamp(110px, 13vw, 180px);
	}

	.section-heading {
		max-width: 820px;
		margin-inline: auto;
		text-align: center;
	}

	.section-heading h2 {
		font-size: clamp(52px, 6vw, 82px);
	}

	.section-heading > p:last-child,
	.depth-copy > p:last-child,
	.briefs-copy > p:last-child,
	.privacy > p:last-child {
		color: rgb(16 55 45 / 68%);
		font-size: 17px;
		line-height: 1.7;
	}

	.section-heading > p:last-child {
		max-width: 610px;
		margin: 28px auto 0;
	}

	.outcome-list {
		display: grid;
		grid-template-columns: repeat(3, 1fr);
		gap: 0;
		margin: clamp(70px, 8vw, 110px) 0 0;
		padding: 0;
		border-block: 1px solid var(--line);
		list-style: none;
	}

	.outcome-list li {
		padding: 34px clamp(24px, 4vw, 54px) 38px;
	}

	.outcome-list li + li {
		border-left: 1px solid var(--line);
	}

	.outcome-list span {
		color: var(--orange);
		font-size: 11px;
		font-weight: 750;
		letter-spacing: 0.14em;
	}

	.outcome-list h3 {
		margin: 48px 0 13px;
		font-family: 'Source Serif 4 Variable', Georgia, serif;
		font-size: clamp(27px, 2.5vw, 36px);
		font-weight: 520;
		letter-spacing: -0.04em;
		line-height: 1.04;
	}

	.outcome-list p {
		margin: 0;
		color: rgb(16 55 45 / 63%);
		font-size: 14px;
		line-height: 1.65;
	}

	.depth-panel {
		display: grid;
		grid-template-columns: minmax(0, 0.9fr) minmax(360px, 1.1fr);
		gap: clamp(55px, 9vw, 130px);
		align-items: center;
		padding: clamp(55px, 7vw, 90px);
		border-radius: 24px;
		background: #f0f1ee;
	}

	.depth-copy h2,
	.briefs h2,
	.privacy h2 {
		font-size: clamp(46px, 5vw, 72px);
	}

	.depth-copy > p:last-child {
		margin: 26px 0 0;
	}

	.depth-list {
		margin: 0;
		padding: 0;
		border-top: 1px solid var(--line);
		list-style: none;
	}

	.depth-list li {
		display: grid;
		grid-template-columns: 120px 1fr;
		gap: 20px;
		align-items: center;
		padding: 22px 0;
		border-bottom: 1px solid var(--line);
	}

	.depth-list span {
		color: var(--orange);
		font-size: 11px;
		font-weight: 750;
		letter-spacing: 0.08em;
		text-transform: uppercase;
	}

	.depth-list strong {
		font-family: 'Source Serif 4 Variable', Georgia, serif;
		font-size: clamp(21px, 2vw, 27px);
		font-weight: 520;
	}

	.briefs {
		margin-top: clamp(110px, 13vw, 180px);
		padding-block: clamp(100px, 11vw, 150px);
		background: var(--forest-deep);
		color: var(--paper);
	}

	.briefs-inner {
		display: grid;
		grid-template-columns: minmax(0, 0.85fr) minmax(440px, 1.15fr);
		gap: clamp(60px, 9vw, 140px);
		align-items: end;
	}

	.briefs .eyebrow {
		color: #f07e42;
	}

	.briefs-copy > p:last-child {
		max-width: 570px;
		margin: 28px 0 0;
		color: rgb(255 250 241 / 70%);
	}

	.brief-path {
		display: grid;
		grid-template-columns: 1fr auto 1fr auto 1fr;
		gap: 20px;
		align-items: center;
		padding-block: 28px;
		border-block: 1px solid rgb(255 250 241 / 18%);
	}

	.brief-path div {
		display: grid;
		gap: 18px;
	}

	.brief-path span {
		color: #f07e42;
		font-size: 10px;
		font-weight: 800;
		letter-spacing: 0.13em;
	}

	.brief-path strong {
		font-family: 'Source Serif 4 Variable', Georgia, serif;
		font-size: clamp(19px, 2vw, 26px);
		font-weight: 520;
		line-height: 1.1;
	}

	.brief-path i {
		width: 26px;
		height: 1px;
		background: rgb(255 250 241 / 25%);
	}

	.privacy {
		max-width: 880px;
		padding-block: clamp(120px, 14vw, 200px);
		text-align: center;
	}

	.privacy > p:last-child {
		max-width: 620px;
		margin: 28px auto 0;
	}

	.final-cta {
		display: grid;
		min-height: 520px;
		place-items: center;
		align-content: center;
		padding: 70px 24px;
		border-radius: 24px;
		background: var(--orange);
		color: white;
		text-align: center;
	}

	.final-cta img {
		width: 42px;
		height: auto;
	}

	.final-cta h2 {
		max-width: 820px;
		margin-top: 28px;
		font-size: clamp(54px, 7vw, 92px);
	}

	.final-cta p {
		margin: 24px 0 0;
		font-size: 16px;
	}

	.availability {
		margin-top: 30px;
		padding: 15px 22px;
		border-radius: 8px;
		background: var(--paper);
		color: var(--forest);
		font-size: 13px;
		font-weight: 750;
	}

	.landing-footer {
		display: grid;
		grid-template-columns: auto 1fr auto;
		gap: 30px;
		align-items: center;
		padding-block: 32px;
	}

	.landing-footer .landing-brand {
		width: 96px;
	}

	.landing-footer .landing-brand img {
		width: 96px;
	}

	.landing-footer > p {
		margin: 0;
		color: rgb(16 55 45 / 55%);
		font-family: 'Source Serif 4 Variable', Georgia, serif;
		font-size: 13px;
	}

	.landing-footer > div {
		display: flex;
		flex-wrap: wrap;
		justify-content: flex-end;
		gap: 15px;
		color: rgb(16 55 45 / 62%);
		font-size: 10px;
	}

	@media (max-width: 1000px) {
		.landing-nav {
			grid-template-columns: 1fr auto;
		}

		.landing-nav nav {
			display: none;
		}

		.depth-panel,
		.briefs-inner {
			grid-template-columns: 1fr;
		}

		.depth-copy,
		.briefs-copy {
			max-width: 680px;
		}
	}

	@media (max-width: 720px) {
		.section-shell {
			width: min(100% - 30px, 1280px);
		}

		.landing-brand img {
			width: 105px;
		}

		.landing-nav .landing-brand {
			width: 105px;
		}

		.nav-cta {
			padding: 9px 12px;
			font-size: 11px;
		}

		.hero {
			min-height: 650px;
			padding: 52px 16px 0;
			border-radius: 18px;
		}

		.hero-inner {
			min-height: auto;
		}

		.hero h1 {
			font-size: clamp(43px, 12vw, 62px);
		}

		.hero-message p {
			font-size: 16px;
		}

		.hero-product {
			width: 108%;
			margin-top: 38px;
		}

		.hero-phone {
			right: 1%;
			width: 28%;
			border-width: 2px;
		}

		.outcome-list {
			grid-template-columns: 1fr;
		}

		.outcome-list li {
			padding-inline: 0;
		}

		.outcome-list li + li {
			border-top: 1px solid var(--line);
			border-left: 0;
		}

		.outcome-list h3 {
			margin-top: 26px;
		}

		.depth-panel {
			padding: 42px 24px;
			border-radius: 18px;
		}

		.depth-list li {
			grid-template-columns: 1fr;
			gap: 7px;
		}

		.brief-path {
			grid-template-columns: 1fr;
		}

		.brief-path i {
			width: 1px;
			height: 20px;
			margin-left: 3px;
		}

		.final-cta {
			min-height: 470px;
			border-radius: 18px;
		}

		.landing-footer {
			grid-template-columns: 1fr;
		}

		.landing-footer > div {
			justify-content: flex-start;
		}
	}

	@media (prefers-reduced-motion: reduce) {
		:global(html) {
			scroll-behavior: auto;
		}
	}
</style>
