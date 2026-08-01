<script lang="ts">
	import { onMount } from 'svelte';
	import ArrowRightIcon from '@lucide/svelte/icons/arrow-right';
	import CheckCircleIcon from '@lucide/svelte/icons/check-circle-2';
	import FileTextIcon from '@lucide/svelte/icons/file-text';
	import HeadphonesIcon from '@lucide/svelte/icons/headphones';
	import LockIcon from '@lucide/svelte/icons/lock-keyhole';
	import PlayIcon from '@lucide/svelte/icons/play';
	import RssIcon from '@lucide/svelte/icons/rss';
	import ShareIcon from '@lucide/svelte/icons/share-2';
	onMount(() => {
		document.body.classList.add('landing-body');
		return () => document.body.classList.remove('landing-body');
	});
</script>

<svelte:head>
	<title>Briefly — Get the gist or go deep</title>
	<meta
		name="description"
		content="Save videos, podcasts, articles, and posts to a private library with four reading depths. Follow trusted sources and receive scheduled text and voice briefs."
	/>
	<meta property="og:type" content="website" />
	<meta property="og:title" content="Briefly — Get the gist or go deep" />
	<meta
		property="og:description"
		content="Keep what interests you. Briefly summarizes anything you save and reads ahead across the sources you follow."
	/>
	<meta property="og:url" content="https://www.readbriefly.fyi/landing" />
	<meta property="og:image" content="https://www.readbriefly.fyi/og-landing.png" />
	<meta name="twitter:card" content="summary_large_image" />
	<meta name="twitter:title" content="Briefly — Get the gist or go deep" />
	<meta
		name="twitter:description"
		content="A private library for what you save, and scheduled briefs for what you follow."
	/>
	<meta name="twitter:image" content="https://www.readbriefly.fyi/og-landing.png" />
</svelte:head>

<div class="landing">
	<header class="landing-nav section-shell">
		<a class="landing-brand" href="/landing" aria-label="Briefly home">
			<img src="/icons/icon-192.png" alt="" />
			<span>Briefly</span>
		</a>

		<nav aria-label="Main navigation">
			<a href="#library">How it works</a>
			<a href="#briefs">Briefs</a>
		</nav>

		<div class="nav-actions">
			<a class="nav-cta" href="#pricing">Get Briefly</a>
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
					<a class="button button-primary" href="#pricing">Get Briefly</a>
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

		<a class="reads-ahead" href="#briefs">
			<span>And for the sources you follow, Briefly reads ahead.</span>
			<ArrowRightIcon aria-hidden="true" />
		</a>

		<section class="library-section section-shell" id="library">
			<div class="section-copy">
				<p class="eyebrow">Saved to your library</p>
				<h2>Four summaries.<br />One source.</h2>
				<p>
					Start with 20 seconds. Go deeper when it earns your time.
				</p>
			</div>

			<div class="reader-demo">
				<img src="/product-ui-concise.png" alt="Briefly library showing a concise summary" />
			</div>
		</section>

		<section class="briefs-section" id="briefs">
			<div class="briefs-inner section-shell">
				<div class="briefs-copy">
					<p class="eyebrow">Your channels, quietly watched</p>
					<h2>Follow without<br />the feed.</h2>
					<p>
						Choose the sources. Briefly checks what’s new and delivers one cited report—on
						your schedule, in text and audio.
					</p>
					<div class="schedule-chip">
						<span>Every Friday</span>
						<b>8:00 AM</b>
						<span>Text + audio</span>
					</div>
					<div class="channel-list" aria-label="Example followed source types">
						<span class="source-youtube"><PlayIcon /> YouTube</span>
						<span class="source-podcast"><HeadphonesIcon /> Podcasts</span>
						<span class="source-reddit">r/ Reddit</span>
						<span class="source-rss"><RssIcon /> RSS</span>
						<span class="source-web">@ Profiles</span>
					</div>
				</div>

				<article class="brief-card">
					<div class="brief-card-top">
						<span>Your Friday brief</span>
						<time datetime="2026-07-24">24 July 2026</time>
					</div>

					<div class="brief-cover">
						<div class="brief-art" aria-hidden="true">
							<i class="sun"></i>
							<i class="hill hill-one"></i>
							<i class="hill hill-two"></i>
							<i class="wind wind-one"></i>
							<i class="wind wind-two"></i>
						</div>
						<div>
							<p>Climate technology</p>
							<h3>The week in<br />climate technology</h3>
							<span>8 min · 14 sources · cited</span>
						</div>
					</div>

					<p class="brief-excerpt">
						Three developments mattered this week: long-duration storage moved closer to
						commercial scale, heat-pump adoption accelerated, and a new carbon market
						standard changed how removals will be verified.
					</p>

					<div class="audio-player" aria-label="Sample voice brief player">
						<button type="button" aria-label="Play sample brief"><PlayIcon /></button>
						<span>0:00</span>
						<div class="audio-track"><i></i></div>
						<span>8:00</span>
						<b><HeadphonesIcon /> Voice brief</b>
					</div>

					<span class="read-report">
						Text report included
						<FileTextIcon aria-hidden="true" />
					</span>
				</article>
			</div>

			<div class="brief-flow section-shell" aria-label="How scheduled briefs work">
				<div>
					<span>01</span>
					<b>Follow your sources</b>
				</div>
				<i aria-hidden="true"></i>
				<div>
					<span>02</span>
					<b>Briefly reads ahead</b>
				</div>
				<i aria-hidden="true"></i>
				<div>
					<span>03</span>
					<b>Read or listen</b>
				</div>
			</div>
		</section>

		<section class="share-section section-shell">
			<div class="share-copy">
				<p class="eyebrow">Share</p>
				<h2>Share the<br />useful version.</h2>
				<p>Send a clean reader. Your captured source stays private.</p>
			</div>
			<div class="share-card">
				<div class="share-card-top">
					<span><ShareIcon /> Shared summary</span>
					<span>Source linked</span>
				</div>
				<h3>A practical guide to biological networks</h3>
				<p>Concise · 2 min read</p>
				<div class="share-link">
					<span>readbriefly.fyi/share/biological-networks</span>
					<b>Copy link</b>
				</div>
			</div>
		</section>

		<section class="pricing-section" id="pricing">
			<div class="pricing-inner section-shell">
				<div class="pricing-copy">
					<p class="eyebrow">Briefly membership</p>
					<h2>Your library.<br />Working ahead.</h2>
					<p>
						Save, follow, and let Briefly prepare the reading.
					</p>
				</div>

				<article class="plan-card">
					<div class="plan-card-top">
						<span>Briefly membership</span>
						<strong>Monthly</strong>
					</div>
					<h3>One plan. Subscribe in the app.</h3>
					<p>The App Store shows your local launch price before purchase.</p>

					<ul>
						<li><CheckCircleIcon /> Save links, files, and notes</li>
						<li><CheckCircleIcon /> Four useful reading depths</li>
						<li><CheckCircleIcon /> Follow sources and schedule briefs</li>
						<li><CheckCircleIcon /> Read or listen to every brief</li>
						<li><CheckCircleIcon /> Searchable local Markdown library</li>
						<li><CheckCircleIcon /> Sync across your devices</li>
					</ul>

					<button type="button" disabled>
						Subscribe on Mac or iPhone
						<ArrowRightIcon aria-hidden="true" />
					</button>

					<p class="pricing-note">
						Purchased and managed through Apple · Cancel anytime<br />
						High fair-use limits apply to hosted processing and public storage. By
						subscribing, you agree to the <a href="/terms">Terms</a> and acknowledge the
						<a href="/privacy">Privacy Notice</a>.
					</p>
				</article>
			</div>

			<div class="download-gate section-shell">
				<LockIcon />
				<div>
					<h3>Built for Apple platforms.</h3>
					<p>Briefly is focused on Mac and iPhone first.</p>
				</div>
				<span class="button button-secondary">Coming to the App Store</span>
			</div>
		</section>

		<section class="final-cta">
			<div class="final-cta-inner">
				<img src="/icons/icon-192.png" alt="" />
				<p>A quieter way to stay curious</p>
				<h2>Keep what matters.<br />Skip the feed.</h2>
				<a class="button button-light" href="#pricing">Get Briefly</a>
				<span>One account · Mac · iPhone</span>
			</div>
		</section>
	</main>

	<footer class="landing-footer section-shell">
		<a class="landing-brand" href="/landing">
			<img src="/icons/icon-192.png" alt="" />
			<span>Briefly</span>
		</a>
		<p>Your private library, working ahead.</p>
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
		--cream: #f4efe5;
		--paper: #fffaf1;
		--forest: #10372d;
		--forest-deep: #082a22;
		--orange: #d85312;
		--lavender: #d6c4df;
		--cobalt: #2448c7;
		--line: rgb(16 55 45 / 16%);
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

	.landing button,
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

	.landing-nav .landing-brand {
		gap: 10px;
		font-family: 'Source Serif 4 Variable', Georgia, serif;
		font-size: 27px;
		font-weight: 600;
		letter-spacing: -0.03em;
		text-transform: none;
	}

	.landing-brand {
		display: inline-flex;
		width: fit-content;
		align-items: center;
		gap: 12px;
		font-size: 20px;
		font-weight: 720;
		letter-spacing: 0.18em;
		text-transform: uppercase;
	}

	.landing-brand img {
		width: 38px;
		height: 38px;
		border-radius: 10px;
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
		gap: 18px;
	}

	.nav-cta {
		padding: 11px 17px;
		border: 1px solid var(--forest);
		border-radius: 999px;
		background: var(--forest);
		color: var(--paper) !important;
		font-weight: 650;
		transition:
			background 180ms ease,
			color 180ms ease;
	}

	.nav-cta:hover {
		background: var(--forest-deep);
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

	.eyebrow {
		margin: 0 0 20px;
		color: var(--orange);
		font-size: 12px;
		font-weight: 750;
		letter-spacing: 0.2em;
		line-height: 1.4;
		text-transform: uppercase;
	}

	.hero h1,
	.section-copy h2,
	.briefs-copy h2,
	.share-section h2,
	.pricing-copy h2,
	.final-cta h2 {
		margin: 0;
		font-family: 'Source Serif 4 Variable', Georgia, serif;
		font-weight: 480;
		letter-spacing: -0.055em;
		line-height: 0.94;
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

	.hero-message .button {
		margin-top: 27px;
	}

	.button {
		display: inline-flex;
		min-height: 52px;
		align-items: center;
		justify-content: center;
		gap: 10px;
		padding: 0 23px;
		border: 0;
		border-radius: 8px;
		font-size: 14px;
		font-weight: 700;
		transition:
			transform 180ms ease,
			box-shadow 180ms ease;
	}

	.button:hover {
		transform: translateY(-2px);
	}

	.button :global(svg) {
		width: 17px;
	}

	.button-primary {
		box-shadow: 0 12px 28px rgb(16 55 45 / 15%);
		background: var(--forest);
		color: white !important;
	}

	.button-primary:hover {
		box-shadow: 0 16px 34px rgb(16 55 45 / 22%);
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

	.reads-ahead {
		display: flex;
		min-height: 70px;
		align-items: center;
		justify-content: center;
		gap: 14px;
		padding: 18px 24px;
		background: var(--forest);
		color: var(--paper) !important;
		font-family: 'Source Serif 4 Variable', Georgia, serif;
		font-size: clamp(20px, 2vw, 28px);
		text-align: center;
	}

	.reads-ahead :global(svg) {
		width: 20px;
		transition: transform 180ms ease;
	}

	.reads-ahead:hover :global(svg) {
		transform: translateX(5px);
	}

	.library-section {
		display: grid;
		grid-template-columns: minmax(260px, 0.72fr) minmax(0, 1.5fr);
		gap: clamp(44px, 7vw, 105px);
		align-items: center;
		padding-block: clamp(90px, 11vw, 160px);
	}

	.section-copy h2,
	.briefs-copy h2,
	.share-section h2,
	.pricing-copy h2 {
		font-size: clamp(48px, 5.5vw, 78px);
	}

	.section-copy > p:not(.eyebrow),
	.briefs-copy > p:not(.eyebrow),
	.share-copy > p:not(.eyebrow),
	.pricing-copy > p:not(.eyebrow) {
		margin: 26px 0 0;
		color: rgb(16 55 45 / 70%);
		font-size: 17px;
		line-height: 1.68;
	}

	.reader-demo {
		height: 560px;
		overflow: hidden;
		border: 8px solid #211929;
		border-radius: 20px;
		box-shadow: 0 28px 80px rgb(16 55 45 / 12%);
		background: #211929;
	}

	.reader-demo img {
		display: block;
		width: 100%;
		height: 100%;
		object-fit: cover;
		object-position: top left;
	}

	.briefs-section {
		padding-block: clamp(88px, 10vw, 145px);
		background:
			radial-gradient(circle at 82% 24%, rgb(60 119 102 / 34%), transparent 25rem),
			var(--forest-deep);
		color: var(--paper);
	}

	.briefs-inner {
		display: grid;
		grid-template-columns: minmax(280px, 0.85fr) minmax(0, 1.15fr);
		gap: clamp(48px, 8vw, 120px);
		align-items: center;
	}

	.briefs-copy .eyebrow {
		color: #f07e42;
	}

	.briefs-copy > p:not(.eyebrow) {
		color: rgb(255 250 241 / 72%);
	}

	.schedule-chip {
		display: flex;
		width: fit-content;
		align-items: center;
		gap: 10px;
		margin-top: 30px;
		padding: 9px 11px;
		border: 1px solid rgb(255 250 241 / 19%);
		border-radius: 8px;
		background: rgb(255 255 255 / 5%);
		font-size: 11px;
	}

	.schedule-chip span,
	.schedule-chip b {
		padding: 5px 8px;
	}

	.schedule-chip b {
		border-radius: 5px;
		background: var(--paper);
		color: var(--forest);
	}

	.channel-list {
		display: flex;
		flex-wrap: wrap;
		gap: 8px;
		margin-top: 19px;
	}

	.channel-list span {
		display: inline-flex;
		align-items: center;
		gap: 6px;
		padding: 7px 10px;
		border-radius: 999px;
		background: rgb(255 250 241 / 9%);
		color: rgb(255 250 241 / 78%);
		font-size: 11px;
		font-weight: 650;
	}

	.channel-list :global(svg) {
		width: 13px;
	}

	.source-youtube :global(svg) {
		color: #ff645b;
	}

	.source-podcast :global(svg) {
		color: #c7a6e8;
	}

	.source-rss :global(svg) {
		color: #f29b4b;
	}

	.brief-card {
		padding: clamp(18px, 2.4vw, 30px);
		border-radius: 18px;
		box-shadow: 0 34px 90px rgb(0 0 0 / 24%);
		background: var(--paper);
		color: var(--forest);
		transform: rotate(0.7deg);
	}

	.brief-card-top {
		display: flex;
		align-items: center;
		justify-content: space-between;
		padding-bottom: 14px;
		border-bottom: 1px solid var(--line);
		color: rgb(16 55 45 / 55%);
		font-size: 10px;
		font-weight: 750;
		letter-spacing: 0.14em;
		text-transform: uppercase;
	}

	.brief-cover {
		display: grid;
		grid-template-columns: 175px 1fr;
		gap: 28px;
		align-items: center;
		padding-block: 24px 20px;
	}

	.brief-art {
		position: relative;
		min-height: 190px;
		overflow: hidden;
		border-radius: 10px;
		background: #c8d4bd;
	}

	.brief-art .sun {
		position: absolute;
		top: 25px;
		right: 28px;
		width: 28px;
		height: 28px;
		border-radius: 50%;
		background: #fff1ce;
	}

	.hill {
		position: absolute;
		right: -45px;
		bottom: -90px;
		left: -45px;
		height: 220px;
		border-radius: 50% 50% 0 0;
		background: #316a54;
		transform: rotate(-8deg);
	}

	.hill-two {
		right: -75px;
		bottom: -135px;
		left: -75px;
		background: var(--forest);
		transform: rotate(9deg);
	}

	.wind {
		position: absolute;
		z-index: 3;
		bottom: 65px;
		left: 55px;
		width: 2px;
		height: 62px;
		background: #fff4d8;
	}

	.wind::before,
	.wind::after {
		position: absolute;
		top: 0;
		left: 1px;
		width: 38px;
		height: 1px;
		background: #fff4d8;
		content: '';
		transform-origin: left;
	}

	.wind::before {
		transform: rotate(18deg);
	}

	.wind::after {
		transform: rotate(138deg);
	}

	.wind-two {
		bottom: 74px;
		left: 112px;
		height: 44px;
		transform: scale(0.76);
	}

	.brief-cover p {
		margin: 0 0 7px;
		color: var(--orange);
		font-size: 10px;
		font-weight: 750;
		letter-spacing: 0.15em;
		text-transform: uppercase;
	}

	.brief-cover h3 {
		margin: 0;
		font-family: 'Source Serif 4 Variable', Georgia, serif;
		font-size: clamp(32px, 3.3vw, 48px);
		font-weight: 500;
		letter-spacing: -0.045em;
		line-height: 0.98;
	}

	.brief-cover span {
		display: block;
		margin-top: 15px;
		color: rgb(16 55 45 / 58%);
		font-size: 11px;
	}

	.brief-excerpt {
		margin: 0;
		padding: 18px 0;
		border-block: 1px solid var(--line);
		color: rgb(16 55 45 / 77%);
		font-family: 'Source Serif 4 Variable', Georgia, serif;
		font-size: 16px;
		line-height: 1.55;
	}

	.audio-player {
		display: flex;
		align-items: center;
		gap: 10px;
		padding: 18px 0;
	}

	.audio-player button {
		display: grid;
		flex: 0 0 auto;
		width: 42px;
		height: 42px;
		place-items: center;
		border: 0;
		border-radius: 50%;
		background: var(--cobalt);
		color: white;
		cursor: pointer;
	}

	.audio-player button :global(svg) {
		width: 18px;
		fill: currentColor;
	}

	.audio-player > span {
		color: rgb(16 55 45 / 55%);
		font-size: 10px;
	}

	.audio-track {
		position: relative;
		flex: 1;
		height: 3px;
		border-radius: 999px;
		background: rgb(16 55 45 / 16%);
	}

	.audio-track i {
		position: absolute;
		inset: 0 auto 0 0;
		width: 17%;
		border-radius: inherit;
		background: var(--cobalt);
	}

	.audio-player b {
		display: inline-flex;
		align-items: center;
		gap: 5px;
		color: var(--cobalt);
		font-size: 10px;
		white-space: nowrap;
	}

	.audio-player b :global(svg) {
		width: 13px;
	}

	.read-report {
		display: inline-flex;
		align-items: center;
		gap: 7px;
		color: var(--cobalt) !important;
		font-size: 12px;
		font-weight: 750;
	}

	.read-report :global(svg) {
		width: 15px;
	}

	.brief-flow {
		display: grid;
		grid-template-columns: 1fr auto 1fr auto 1fr;
		gap: 28px;
		align-items: center;
		margin-top: clamp(64px, 8vw, 100px);
		padding-top: 32px;
		border-top: 1px solid rgb(255 250 241 / 16%);
	}

	.brief-flow > div {
		display: grid;
		gap: 7px;
	}

	.brief-flow span {
		color: #f07e42;
		font-size: 10px;
		font-weight: 800;
		letter-spacing: 0.12em;
	}

	.brief-flow b {
		font-family: 'Source Serif 4 Variable', Georgia, serif;
		font-size: 22px;
		font-weight: 530;
	}

	.brief-flow > i {
		width: 34px;
		height: 1px;
		background: rgb(255 250 241 / 24%);
	}

	.share-section {
		display: grid;
		grid-template-columns: 0.8fr 1.2fr;
		gap: clamp(50px, 9vw, 135px);
		align-items: center;
		padding-block: clamp(95px, 11vw, 160px);
	}

	.share-card {
		padding: clamp(28px, 5vw, 58px);
		border: 1px solid var(--line);
		border-radius: 18px;
		box-shadow: 0 25px 70px rgb(16 55 45 / 10%);
		background:
			linear-gradient(rgb(255 250 241 / 92%), rgb(255 250 241 / 92%)),
			repeating-linear-gradient(
				to bottom,
				transparent 0 31px,
				rgb(16 55 45 / 9%) 32px
			);
	}

	.share-card-top {
		display: flex;
		justify-content: space-between;
		gap: 20px;
		color: rgb(16 55 45 / 48%);
		font-size: 9px;
		font-weight: 750;
		letter-spacing: 0.08em;
		text-transform: uppercase;
	}

	.share-card-top span {
		display: flex;
		align-items: center;
		gap: 6px;
	}

	.share-card-top :global(svg) {
		width: 14px;
		color: var(--orange);
	}

	.share-card h3 {
		max-width: 600px;
		margin: 54px 0 12px;
		font-family: 'Source Serif 4 Variable', Georgia, serif;
		font-size: clamp(32px, 4vw, 54px);
		font-weight: 520;
		letter-spacing: -0.04em;
		line-height: 1.02;
	}

	.share-card > p {
		margin: 0;
		color: var(--cobalt);
		font-size: 10px;
		font-weight: 750;
		text-transform: uppercase;
	}

	.share-link {
		display: flex;
		align-items: center;
		justify-content: space-between;
		gap: 16px;
		margin-top: 52px;
		padding: 9px 9px 9px 13px;
		border: 1px solid var(--line);
		border-radius: 8px;
		background: rgb(255 255 255 / 70%);
		color: rgb(16 55 45 / 50%);
		font-size: 10px;
	}

	.share-link span {
		overflow: hidden;
		text-overflow: ellipsis;
		white-space: nowrap;
	}

	.share-link b {
		flex: 0 0 auto;
		padding: 8px 10px;
		border-radius: 6px;
		background: var(--forest);
		color: var(--paper);
		font-size: 9px;
	}

	.pricing-section {
		padding-block: clamp(90px, 10vw, 140px);
		background: #dfd6e3;
	}

	.pricing-inner {
		display: grid;
		grid-template-columns: minmax(280px, 0.75fr) minmax(0, 1.25fr);
		gap: clamp(45px, 8vw, 120px);
		align-items: start;
	}

	.plan-card {
		padding: clamp(25px, 4vw, 48px);
		border: 1px solid rgb(16 55 45 / 18%);
		border-radius: 18px;
		box-shadow: 0 25px 70px rgb(16 55 45 / 10%);
		background: var(--paper);
	}

	.plan-card-top {
		display: flex;
		align-items: flex-start;
		justify-content: space-between;
		gap: 20px;
		padding-bottom: 22px;
		border-bottom: 1px solid var(--line);
		color: rgb(16 55 45 / 55%);
		font-size: 11px;
		font-weight: 750;
		letter-spacing: 0.1em;
		text-transform: uppercase;
	}

	.plan-card-top strong {
		color: var(--forest);
		font-family: 'Source Serif 4 Variable', Georgia, serif;
		font-size: 40px;
		font-weight: 520;
		letter-spacing: -0.045em;
		line-height: 0.8;
	}

	.plan-card h3 {
		margin: 28px 0 9px;
		font-family: 'Source Serif 4 Variable', Georgia, serif;
		font-size: 30px;
		font-weight: 520;
		letter-spacing: -0.035em;
	}

	.plan-card > p {
		margin: 0;
		color: rgb(16 55 45 / 65%);
		font-size: 13px;
	}

	.plan-card ul {
		display: grid;
		grid-template-columns: repeat(2, 1fr);
		gap: 12px 22px;
		margin: 27px 0;
		padding: 0;
		list-style: none;
		font-size: 12px;
	}

	.plan-card li {
		display: flex;
		align-items: center;
		gap: 8px;
	}

	.plan-card li :global(svg) {
		width: 15px;
		color: var(--orange);
	}

	.plan-card > button {
		display: flex;
		width: 100%;
		min-height: 50px;
		align-items: center;
		justify-content: center;
		gap: 9px;
		border: 0;
		border-radius: 8px;
		background: var(--orange);
		color: white;
		cursor: pointer;
		font: inherit;
		font-size: 13px;
		font-weight: 750;
	}

	.plan-card > button:disabled {
		cursor: default;
		opacity: 0.62;
	}

	.plan-card > button :global(svg) {
		width: 16px;
	}

	.plan-card .pricing-note {
		margin-top: 14px;
		color: rgb(16 55 45 / 48%);
		font-size: 9px;
		line-height: 1.55;
		text-align: center;
	}

	.pricing-note a {
		text-decoration: underline;
		text-underline-offset: 2px;
	}

	.download-gate {
		display: grid;
		grid-template-columns: auto 1fr auto;
		gap: 18px;
		align-items: center;
		margin-top: 28px;
		padding: 20px 24px;
		border: 1px solid rgb(16 55 45 / 15%);
		border-radius: 12px;
		background: rgb(255 250 241 / 48%);
	}

	.download-gate > :global(svg) {
		width: 21px;
	}

	.download-gate h3 {
		margin: 0;
		font-family: 'Source Serif 4 Variable', Georgia, serif;
		font-size: 19px;
		font-weight: 550;
	}

	.download-gate p {
		margin: 3px 0 0;
		color: rgb(16 55 45 / 60%);
		font-size: 11px;
	}

	.button-secondary {
		min-height: 44px;
		border: 1px solid var(--forest);
		background: transparent;
		color: var(--forest) !important;
	}

	.final-cta {
		position: relative;
		display: grid;
		min-height: 610px;
		place-items: center;
		padding: 80px 24px;
		overflow: hidden;
		background:
			radial-gradient(circle at 50% 0, rgb(255 250 241 / 18%), transparent 28rem),
			var(--orange);
		color: white;
		text-align: center;
	}

	.final-cta::before,
	.final-cta::after {
		position: absolute;
		width: 360px;
		height: 360px;
		border: 1px solid rgb(255 255 255 / 20%);
		border-radius: 50%;
		content: '';
	}

	.final-cta::before {
		top: -180px;
		left: -120px;
	}

	.final-cta::after {
		right: -120px;
		bottom: -190px;
	}

	.final-cta-inner {
		position: relative;
		z-index: 2;
		display: grid;
		justify-items: center;
	}

	.final-cta img {
		width: 54px;
		height: 54px;
		border-radius: 14px;
	}

	.final-cta p {
		margin: 26px 0 22px;
		font-size: 11px;
		font-weight: 750;
		letter-spacing: 0.2em;
		text-transform: uppercase;
	}

	.final-cta h2 {
		font-size: clamp(58px, 7vw, 96px);
	}

	.button-light {
		margin-top: 34px;
		background: var(--paper);
		color: var(--forest) !important;
	}

	.final-cta span {
		margin-top: 18px;
		font-size: 10px;
		opacity: 0.65;
	}

	.landing-footer {
		display: grid;
		grid-template-columns: auto 1fr auto;
		gap: 30px;
		align-items: center;
		padding-block: 32px;
	}

	.landing-footer .landing-brand {
		font-size: 14px;
	}

	.landing-footer .landing-brand img {
		width: 30px;
		height: 30px;
		border-radius: 8px;
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

	.landing-footer > div a:hover {
		color: var(--forest);
	}

	@media (max-width: 1000px) {
		.landing-nav {
			grid-template-columns: 1fr auto;
		}

		.landing-nav nav {
			display: none;
		}

		.library-section,
		.briefs-inner,
		.share-section,
		.pricing-inner {
			grid-template-columns: 1fr;
		}

		.section-copy,
		.briefs-copy,
		.share-copy,
		.pricing-copy {
			max-width: 650px;
		}

		.brief-card {
			max-width: 760px;
		}
	}

	@media (max-width: 720px) {
		.section-shell {
			width: min(100% - 30px, 1280px);
		}

		.landing-brand {
			gap: 8px;
			font-size: 15px;
		}

		.landing-brand img {
			width: 32px;
			height: 32px;
		}

		.landing-nav .landing-brand {
			font-size: 22px;
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

		.reads-ahead {
			font-size: 18px;
		}

		.reader-demo {
			height: 600px;
			border-width: 5px;
			border-radius: 14px;
		}

		.brief-cover {
			grid-template-columns: 112px 1fr;
			gap: 15px;
		}

		.brief-art {
			min-height: 150px;
		}

		.brief-cover h3 {
			font-size: 29px;
		}

		.audio-player b {
			display: none;
		}

		.brief-flow {
			grid-template-columns: 1fr;
		}

		.brief-flow > i {
			width: 1px;
			height: 20px;
			margin-left: 3px;
		}

		.share-card {
			padding: 24px;
		}

		.share-card h3 {
			margin-top: 40px;
		}

		.share-link {
			margin-top: 40px;
		}

		.plan-card ul {
			grid-template-columns: 1fr;
		}

		.download-gate {
			grid-template-columns: auto 1fr;
		}

		.download-gate .button {
			grid-column: 1 / -1;
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

		.landing *,
		.landing *::before,
		.landing *::after {
			scroll-behavior: auto !important;
			transition-duration: 0.01ms !important;
		}
	}
</style>
