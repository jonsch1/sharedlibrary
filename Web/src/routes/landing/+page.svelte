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
		content="Save articles, videos, podcasts, PDFs, and notes. Get clear summaries at the depth you choose, then read or listen on Mac, iPhone, and iPad."
	/>
	<link rel="canonical" href="https://www.readbriefly.fyi/landing" />
	<meta property="og:type" content="website" />
	<meta property="og:title" content="Briefly — Stay curious. Skip the feed." />
	<meta
		property="og:description"
		content="A quiet, private library for everything you want to understand."
	/>
	<meta property="og:url" content="https://www.readbriefly.fyi/landing" />
	<meta property="og:image" content="https://www.readbriefly.fyi/og-landing-v2.png" />
	<meta property="og:image:width" content="1200" />
	<meta property="og:image:height" content="630" />
	<meta property="og:image:alt" content="Briefly on Mac and iPhone" />
	<meta name="twitter:card" content="summary_large_image" />
	<meta name="twitter:title" content="Briefly — Stay curious. Skip the feed." />
	<meta
		name="twitter:description"
		content="A quiet, private library for everything you want to understand."
	/>
	<meta name="twitter:image" content="https://www.readbriefly.fyi/og-landing-v2.png" />
</svelte:head>

<div class="landing">
	<header class="site-nav page-shell">
		<a class="brand" href="/landing" aria-label="Briefly home">
			<img class="brand-icon" src="/brand/briefly-app-icon.png" alt="" width="240" height="240" />
			<span class="brand-name">Briefly</span>
		</a>

		<nav aria-label="Main navigation">
			<a href="#how-it-works">How it works</a>
			<a href="#product">Product</a>
			<a href="#privacy">Privacy</a>
		</nav>

		<a class="nav-cta" href="#get-briefly">Get Briefly</a>
	</header>

	<main>
		<section class="hero page-shell">
			<div class="hero-copy">
				<p class="eyebrow">Native on Mac · iPhone · iPad</p>
				<h1>Stay curious.<br />Skip the feed.</h1>
				<p class="hero-lede">
					Save anything worth understanding. Briefly turns it into a clear summary at the
					depth you choose, ready to read or listen to when you are.
				</p>
				<div class="hero-actions">
					<a class="button button-primary" href="#product">See Briefly in action</a>
					<span>Launching on the App Store</span>
				</div>
			</div>

			<div class="hero-art" aria-label="Briefly library on Mac and iPad">
				<img
					src="/landing-library.jpg"
					alt="Briefly showing one private library across Mac and iPad"
					width="1100"
					height="1466"
					fetchpriority="high"
				/>
			</div>
		</section>

		<section class="promise page-shell" aria-labelledby="promise-title">
			<p class="eyebrow">Your attention, back in your hands</p>
			<h2 id="promise-title">One place for everything<br />worth keeping.</h2>
			<p>
				Articles, videos, podcasts, PDFs, and notes become a calm library you control—not
				another timeline asking to be refreshed.
			</p>
		</section>

		<section class="steps page-shell" id="how-it-works" aria-labelledby="steps-title">
			<div class="section-intro">
				<p class="eyebrow">How it works</p>
				<h2 id="steps-title">Save now.<br />Understand later.</h2>
			</div>

			<ol class="step-grid">
				<li class="step-card step-coral">
					<div class="step-top"><span>01</span><i aria-hidden="true">⌘ G</i></div>
					<h3>Capture from anywhere.</h3>
					<p>Send a link, add a note, import a PDF, or save a podcast or video.</p>
				</li>
				<li class="step-card step-blue">
					<div class="step-top"><span>02</span><i aria-hidden="true">Brief → Full</i></div>
					<h3>Choose the depth.</h3>
					<p>Get the point first. Add context only when the subject deserves more time.</p>
				</li>
				<li class="step-card step-yellow">
					<div class="step-top"><span>03</span><i aria-hidden="true">▶</i></div>
					<h3>Read or listen.</h3>
					<p>Move through your library in text or audio, at the pace that fits your day.</p>
				</li>
			</ol>
		</section>

		<section class="product-section" id="product" aria-labelledby="product-title">
			<div class="product-heading page-shell">
				<div>
					<p class="eyebrow">Built for Apple platforms</p>
					<h2 id="product-title">Your library.<br />Everywhere.</h2>
				</div>
				<p>Save on Mac. Pick it up on iPhone or iPad. Keep the same private library close.</p>
			</div>

			<div class="screenshot-rail page-shell" aria-label="Briefly product screenshots">
				<figure class="screenshot-card screenshot-wide">
					<img
						src="/landing-library.jpg"
						alt="Briefly library shared across Mac and iPad"
						width="1100"
						height="1466"
						loading="lazy"
					/>
					<figcaption><span>Mac + iPad</span><strong>One private library</strong></figcaption>
				</figure>
				<figure class="screenshot-card">
					<img
						src="/landing-capture.jpg"
						alt="Briefly Mac shortcut for saving anything with Command G"
						width="820"
						height="1774"
						loading="lazy"
					/>
					<figcaption><span>Mac shortcut</span><strong>Capture in a keystroke</strong></figcaption>
				</figure>
				<figure class="screenshot-card">
					<img
						src="/landing-depth.jpg"
						alt="Briefly reading depths shown on iPhone"
						width="820"
						height="1774"
						loading="lazy"
					/>
					<figcaption><span>Reading depth</span><strong>The right amount of detail</strong></figcaption>
				</figure>
			</div>
		</section>

		<section class="channels page-shell" aria-labelledby="channels-title">
			<div class="channel-orbit" aria-hidden="true">
				<span>RSS</span>
				<span>Podcasts</span>
				<span>YouTube</span>
				<span>Reddit</span>
				<strong>One brief</strong>
			</div>
			<div class="channels-copy">
				<p class="eyebrow">Channels</p>
				<h2 id="channels-title">Follow sources.<br />Not feeds.</h2>
				<p>
					Choose the sources you trust. Briefly gathers what is new into cited briefs you can
					read or listen to on your own terms.
				</p>
			</div>
		</section>

		<section class="privacy page-shell" id="privacy" aria-labelledby="privacy-title">
			<div class="privacy-mark" aria-hidden="true">Private<br />by default</div>
			<div>
				<p class="eyebrow">Your library is yours</p>
				<h2 id="privacy-title">Keep what you read<br />to yourself.</h2>
				<p>
					Your library is local-first and can sync privately through your iCloud account.
					Nothing becomes public unless you deliberately create a share link.
				</p>
			</div>
		</section>

		<section class="final-cta page-shell" id="get-briefly">
			<img src="/brand/briefly-app-icon.png" alt="Briefly" width="240" height="240" />
			<p class="eyebrow">Mac · iPhone · iPad</p>
			<h2>Stay curious.<br />Build a library.</h2>
			<p>Briefly is launching soon on the App Store.</p>
			<span class="availability">Coming to the App Store</span>
		</section>
	</main>

	<footer class="site-footer page-shell">
		<a class="brand" href="/landing" aria-label="Briefly home">
			<img class="brand-icon" src="/brand/briefly-app-icon.png" alt="" width="240" height="240" />
			<span class="brand-name">Briefly</span>
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
		background: #f8f5ed;
		color: #171715;
	}

	:global(body.landing-body *) {
		box-sizing: border-box;
	}

	.landing {
		--ink: #171715;
		--muted: #64625d;
		--paper: #f8f5ed;
		--cream: #fffaf0;
		--blue: #1677ff;
		--navy: #0c245d;
		--coral: #f3a080;
		--yellow: #f9d96e;
		--sky: #bad8f1;
		--line: rgb(23 23 21 / 13%);
		min-height: 100vh;
		overflow: clip;
		background:
			radial-gradient(circle at 8% 15%, rgb(243 160 128 / 12%), transparent 21rem),
			var(--paper);
		color: var(--ink);
		font-family: 'DM Sans Variable', 'DM Sans', sans-serif;
	}

	.landing :global(*) {
		box-sizing: border-box;
	}

	.landing a {
		color: inherit;
		text-decoration: none;
		-webkit-tap-highlight-color: transparent;
	}

	.page-shell {
		width: min(100% - 48px, 1320px);
		margin-inline: auto;
	}

	.site-nav {
		position: relative;
		z-index: 10;
		display: grid;
		grid-template-columns: 1fr auto 1fr;
		align-items: center;
		padding-block: 18px;
	}

	.brand {
		display: inline-flex;
		width: fit-content;
		align-items: center;
		gap: 10px;
	}

	.brand-icon {
		display: block;
		width: 38px;
		height: 38px;
		border-radius: 9px;
	}

	.brand-name {
		font-size: 21px;
		font-weight: 780;
		letter-spacing: -0.055em;
	}

	.site-nav nav {
		display: flex;
		align-items: center;
		gap: 30px;
		font-size: 13px;
		font-weight: 650;
	}

	.site-nav nav a,
	.site-footer a {
		transition: opacity 160ms ease;
	}

	.site-nav nav a:hover,
	.site-footer a:hover {
		opacity: 0.55;
	}

	.nav-cta {
		justify-self: end;
		padding: 11px 17px;
		border-radius: 999px;
		background: var(--ink);
		color: white !important;
		font-size: 13px;
		font-weight: 750;
	}

	.hero {
		display: grid;
		min-height: 760px;
		grid-template-columns: minmax(0, 0.88fr) minmax(440px, 0.72fr);
		gap: clamp(36px, 6vw, 90px);
		align-items: center;
		padding-block: clamp(54px, 7vw, 96px);
	}

	.hero-copy {
		position: relative;
		z-index: 1;
	}

	.eyebrow {
		margin: 0 0 18px;
		color: #97620d;
		font-size: 11px;
		font-weight: 800;
		letter-spacing: 0.16em;
		line-height: 1.35;
		text-transform: uppercase;
	}

	.hero h1,
	.promise h2,
	.section-intro h2,
	.product-heading h2,
	.channels h2,
	.privacy h2,
	.final-cta h2 {
		margin: 0;
		font-family: 'DM Sans Variable', 'DM Sans', sans-serif;
		font-weight: 720;
		letter-spacing: -0.07em;
		line-height: 0.92;
	}

	.hero h1 {
		max-width: 760px;
		font-size: clamp(58px, 7vw, 102px);
	}

	.hero-lede {
		max-width: 630px;
		margin: 30px 0 0;
		color: var(--muted);
		font-size: clamp(17px, 1.5vw, 20px);
		line-height: 1.6;
	}

	.hero-actions {
		display: flex;
		flex-wrap: wrap;
		align-items: center;
		gap: 18px;
		margin-top: 32px;
	}

	.hero-actions > span {
		color: var(--muted);
		font-size: 12px;
		font-weight: 650;
	}

	.button {
		display: inline-flex;
		min-height: 52px;
		align-items: center;
		justify-content: center;
		padding: 0 22px;
		border-radius: 999px;
		font-size: 14px;
		font-weight: 750;
	}

	.button-primary {
		background: var(--blue);
		box-shadow: 0 14px 30px rgb(22 119 255 / 22%);
		color: white !important;
	}

	.hero-art {
		position: relative;
		justify-self: end;
		width: min(100%, 560px);
		transform: rotate(2deg);
	}

	.hero-art::before,
	.hero-art::after {
		position: absolute;
		z-index: -1;
		border-radius: 28px;
		content: '';
		inset: 18px -18px -18px 18px;
	}

	.hero-art::before {
		background: var(--blue);
		transform: rotate(-4deg);
	}

	.hero-art::after {
		z-index: -2;
		background: var(--coral);
		inset: 36px -34px -34px 36px;
		transform: rotate(4deg);
	}

	.hero-art img {
		display: block;
		width: 100%;
		height: auto;
		border: 1px solid rgb(23 23 21 / 14%);
		border-radius: 28px;
		box-shadow: 0 30px 60px rgb(23 23 21 / 18%);
	}

	.promise {
		padding-block: clamp(130px, 15vw, 220px);
		text-align: center;
	}

	.promise h2 {
		font-size: clamp(54px, 7vw, 96px);
	}

	.promise > p:last-child {
		max-width: 690px;
		margin: 32px auto 0;
		color: var(--muted);
		font-size: 18px;
		line-height: 1.7;
	}

	.steps {
		padding-bottom: clamp(130px, 14vw, 210px);
	}

	.section-intro {
		display: flex;
		align-items: end;
		justify-content: space-between;
		padding-bottom: 44px;
		border-bottom: 1px solid var(--line);
	}

	.section-intro h2 {
		font-size: clamp(48px, 6vw, 78px);
		text-align: right;
	}

	.step-grid {
		display: grid;
		grid-template-columns: repeat(3, 1fr);
		gap: 16px;
		margin: 16px 0 0;
		padding: 0;
		list-style: none;
	}

	.step-card {
		display: flex;
		min-height: 440px;
		flex-direction: column;
		padding: clamp(26px, 3vw, 40px);
		border-radius: 24px;
		color: var(--ink);
	}

	.step-coral {
		background: var(--coral);
	}

	.step-blue {
		background: var(--sky);
	}

	.step-yellow {
		background: var(--yellow);
	}

	.step-top {
		display: flex;
		align-items: center;
		justify-content: space-between;
		font-size: 11px;
		font-weight: 800;
		letter-spacing: 0.12em;
	}

	.step-top i {
		padding: 9px 12px;
		border: 1px solid rgb(23 23 21 / 45%);
		border-radius: 999px;
		font-size: 11px;
		font-style: normal;
		letter-spacing: 0.03em;
	}

	.step-card h3 {
		margin: auto 0 14px;
		font-size: clamp(31px, 3vw, 43px);
		font-weight: 720;
		letter-spacing: -0.055em;
		line-height: 0.98;
	}

	.step-card p {
		margin: 0;
		color: rgb(23 23 21 / 72%);
		font-size: 15px;
		line-height: 1.55;
	}

	.product-section {
		padding-block: clamp(100px, 11vw, 160px);
		background: var(--ink);
		color: var(--cream);
	}

	.product-heading {
		display: grid;
		grid-template-columns: 1fr minmax(280px, 470px);
		gap: 60px;
		align-items: end;
	}

	.product-heading .eyebrow,
	.channels .eyebrow {
		color: #72a9ff;
	}

	.product-heading h2,
	.channels h2,
	.privacy h2 {
		font-size: clamp(52px, 7vw, 92px);
	}

	.product-heading > p {
		margin: 0 0 5px;
		color: rgb(255 250 240 / 65%);
		font-size: 17px;
		line-height: 1.65;
	}

	.screenshot-rail {
		display: grid;
		grid-template-columns: 1.18fr 0.82fr 0.82fr;
		gap: 18px;
		align-items: start;
		margin-top: clamp(64px, 8vw, 110px);
	}

	.screenshot-card {
		margin: 0;
		overflow: hidden;
		border: 1px solid rgb(255 255 255 / 14%);
		border-radius: 22px;
		background: #2a2926;
	}

	.screenshot-card img {
		display: block;
		width: 100%;
		height: auto;
	}

	.screenshot-card figcaption {
		display: grid;
		gap: 5px;
		padding: 20px;
		border-top: 1px solid rgb(255 255 255 / 10%);
	}

	.screenshot-card figcaption span {
		color: #72a9ff;
		font-size: 10px;
		font-weight: 800;
		letter-spacing: 0.13em;
		text-transform: uppercase;
	}

	.screenshot-card figcaption strong {
		font-size: 14px;
	}

	.channels {
		display: grid;
		grid-template-columns: minmax(400px, 0.9fr) minmax(0, 1.1fr);
		gap: clamp(60px, 10vw, 150px);
		align-items: center;
		padding-block: clamp(130px, 15vw, 220px);
	}

	.channel-orbit {
		position: relative;
		display: grid;
		width: min(100%, 520px);
		aspect-ratio: 1;
		place-items: center;
		border: 1px solid var(--line);
		border-radius: 50%;
	}

	.channel-orbit::before,
	.channel-orbit::after {
		position: absolute;
		border: 1px solid var(--line);
		border-radius: 50%;
		content: '';
	}

	.channel-orbit::before {
		inset: 18%;
	}

	.channel-orbit::after {
		inset: 35%;
		background: var(--blue);
		border: 0;
		box-shadow: 0 18px 36px rgb(22 119 255 / 23%);
	}

	.channel-orbit span,
	.channel-orbit strong {
		position: absolute;
		z-index: 1;
		padding: 11px 15px;
		border: 1px solid var(--line);
		border-radius: 999px;
		background: var(--cream);
		font-size: 12px;
		font-weight: 750;
	}

	.channel-orbit strong {
		border: 0;
		background: transparent;
		color: white;
	}

	.channel-orbit span:nth-child(1) {
		top: 4%;
		left: 39%;
	}

	.channel-orbit span:nth-child(2) {
		top: 38%;
		right: -3%;
	}

	.channel-orbit span:nth-child(3) {
		bottom: 10%;
		right: 17%;
	}

	.channel-orbit span:nth-child(4) {
		bottom: 18%;
		left: 2%;
	}

	.channels-copy > p:last-child,
	.privacy > div > p:last-child {
		max-width: 600px;
		margin: 30px 0 0;
		color: var(--muted);
		font-size: 17px;
		line-height: 1.7;
	}

	.privacy {
		display: grid;
		grid-template-columns: minmax(240px, 0.55fr) minmax(0, 1.45fr);
		gap: clamp(50px, 9vw, 130px);
		align-items: center;
		padding: clamp(50px, 7vw, 92px);
		border-radius: 28px;
		background: #ece8dd;
	}

	.privacy-mark {
		display: grid;
		aspect-ratio: 1;
		place-items: center;
		border-radius: 50%;
		background: var(--navy);
		box-shadow: inset 0 0 0 16px rgb(255 255 255 / 5%);
		color: white;
		font-size: clamp(21px, 3vw, 36px);
		font-weight: 720;
		letter-spacing: -0.045em;
		line-height: 1;
		text-align: center;
	}

	.final-cta {
		display: grid;
		min-height: 650px;
		place-items: center;
		align-content: center;
		margin-top: clamp(100px, 12vw, 180px);
		padding: 80px 24px;
		border-radius: 28px;
		background: var(--yellow);
		text-align: center;
	}

	.final-cta > img {
		width: 88px;
		height: 88px;
		margin-bottom: 24px;
		border-radius: 21px;
		box-shadow: 0 18px 35px rgb(12 36 93 / 20%);
	}

	.final-cta h2 {
		font-size: clamp(58px, 8vw, 108px);
	}

	.final-cta > p:not(.eyebrow) {
		margin: 28px 0 0;
		font-size: 16px;
	}

	.availability {
		margin-top: 30px;
		padding: 15px 22px;
		border-radius: 999px;
		background: var(--ink);
		color: white;
		font-size: 13px;
		font-weight: 750;
	}

	.site-footer {
		display: grid;
		grid-template-columns: auto 1fr auto;
		gap: 30px;
		align-items: center;
		padding-block: 36px;
	}

	.site-footer .brand-icon {
		width: 30px;
		height: 30px;
		border-radius: 7px;
	}

	.site-footer .brand-name {
		font-size: 18px;
	}

	.site-footer > p {
		margin: 0;
		color: var(--muted);
		font-size: 12px;
	}

	.site-footer > div {
		display: flex;
		flex-wrap: wrap;
		justify-content: flex-end;
		gap: 15px;
		color: var(--muted);
		font-size: 10px;
	}

	@media (max-width: 1000px) {
		.site-nav {
			grid-template-columns: 1fr auto;
		}

		.site-nav nav {
			display: none;
		}

		.hero {
			grid-template-columns: 1fr;
			padding-top: 80px;
		}

		.hero-copy {
			max-width: 780px;
		}

		.hero-art {
			justify-self: center;
			width: min(82%, 620px);
			margin-top: 32px;
		}

		.step-grid {
			grid-template-columns: 1fr;
		}

		.step-card {
			min-height: 330px;
		}

		.product-heading,
		.channels,
		.privacy {
			grid-template-columns: 1fr;
		}

		.product-heading > p {
			max-width: 620px;
		}

		.screenshot-rail {
			grid-template-columns: repeat(2, 1fr);
		}

		.screenshot-wide {
			grid-column: 1 / -1;
			width: min(100%, 620px);
			margin-inline: auto;
		}

		.channel-orbit {
			order: 2;
			justify-self: center;
		}

		.privacy-mark {
			width: min(240px, 70%);
		}
	}

	@media (max-width: 680px) {
		.page-shell {
			width: min(100% - 30px, 1320px);
		}

		.brand-icon {
			width: 34px;
			height: 34px;
			border-radius: 8px;
		}

		.brand-name {
			font-size: 19px;
		}

		.nav-cta {
			padding: 10px 14px;
			font-size: 11px;
		}

		.hero {
			min-height: auto;
			padding-block: 62px 100px;
		}

		.hero h1 {
			font-size: clamp(54px, 17vw, 76px);
		}

		.hero-lede {
			font-size: 16px;
		}

		.hero-art {
			width: 88%;
			margin-left: -8px;
		}

		.hero-art::before {
			inset: 10px -10px -10px 10px;
		}

		.hero-art::after {
			inset: 22px -18px -18px 22px;
		}

		.hero-art img,
		.step-card,
		.screenshot-card,
		.privacy,
		.final-cta {
			border-radius: 18px;
		}

		.promise {
			text-align: left;
		}

		.promise h2 {
			font-size: clamp(50px, 14vw, 72px);
		}

		.promise > p:last-child {
			font-size: 16px;
		}

		.section-intro {
			display: block;
		}

		.section-intro h2 {
			font-size: clamp(46px, 14vw, 64px);
			text-align: left;
		}

		.step-card {
			min-height: 300px;
		}

		.product-heading {
			gap: 30px;
		}

		.product-heading h2,
		.channels h2,
		.privacy h2 {
			font-size: clamp(50px, 15vw, 72px);
		}

		.screenshot-rail {
			display: flex;
			width: 100%;
			margin-top: 54px;
			overflow-x: auto;
			padding-inline: 15px;
			scroll-padding-inline: 15px;
			scroll-snap-type: x mandatory;
			scrollbar-width: none;
		}

		.screenshot-rail::-webkit-scrollbar {
			display: none;
		}

		.screenshot-card,
		.screenshot-wide {
			width: min(82vw, 360px);
			min-width: min(82vw, 360px);
			margin: 0;
			scroll-snap-align: center;
		}

		.channels {
			gap: 70px;
		}

		.channel-orbit {
			width: 92%;
		}

		.privacy {
			padding: 36px 24px;
		}

		.privacy-mark {
			width: 170px;
		}

		.final-cta {
			min-height: 560px;
		}

		.site-footer {
			grid-template-columns: 1fr;
		}

		.site-footer > div {
			justify-content: flex-start;
		}
	}

	@media (prefers-reduced-motion: reduce) {
		:global(html) {
			scroll-behavior: auto;
		}
	}
</style>
