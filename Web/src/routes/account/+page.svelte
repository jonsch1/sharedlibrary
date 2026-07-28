<script lang="ts">
	import { onMount } from 'svelte';
	import ArrowUpRightIcon from '@lucide/svelte/icons/arrow-up-right';
	import DownloadIcon from '@lucide/svelte/icons/download';
	import GlobeIcon from '@lucide/svelte/icons/globe-2';
	import LaptopIcon from '@lucide/svelte/icons/laptop';
	import LogInIcon from '@lucide/svelte/icons/log-in';
	import LogOutIcon from '@lucide/svelte/icons/log-out';
	import {
		beginBrieflyPlusCheckout,
		consumeBillingResult,
		formatMonthlyPrice,
		loadBillingStatus,
		openBillingPortal,
		type BillingStatus
	} from '$lib/billing.js';
	import {
		loadPublishedShareLinks,
		revokeShareLink,
		type PublishedShareLinks,
		type ShareLinkStatus
	} from '$lib/share-links.js';
	import {
		beginGoogleDriveConnection,
		consumeGoogleDriveConnectionResult,
		disconnectGoogleDrive
	} from '$lib/google-drive.js';
	import { disconnectICloud, emptyICloudLibraryMessage } from '$lib/icloud.js';

	type AccountStatus = {
		authenticated: boolean;
		email?: string;
		syncProvider?: 'google' | 'icloud' | null;
		providers?: { google?: boolean; apple?: boolean };
		google?: { configured?: boolean; connected?: boolean };
		icloud?: { configured?: boolean; connected?: boolean };
	};

	const downloadBase =
		'https://github.com/jonsch1/briefly-downloads/releases/latest/download';
	const desktopDownloads = [
		{ platform: 'macOS', detail: 'Apple silicon and Intel', href: `${downloadBase}/Briefly-mac-universal.dmg`, file: '.dmg' },
		{ platform: 'Windows', detail: '64-bit installer', href: `${downloadBase}/Briefly-windows-x64.exe`, file: '.exe' },
		{ platform: 'Linux', detail: 'Portable AppImage', href: `${downloadBase}/Briefly-linux-x64.AppImage`, file: 'AppImage' },
		{ platform: 'Debian / Ubuntu', detail: '64-bit package', href: `${downloadBase}/Briefly-linux-amd64.deb`, file: '.deb' }
	];

	let account = $state<AccountStatus | null>(null);
	let billing = $state<BillingStatus | null>(null);
	let published = $state<PublishedShareLinks>({ limit: 200, links: [] });
	let loading = $state(true);
	let busy = $state(false);
	let revokingToken = $state<string | null>(null);
	let message = $state('');
	let currentTier = $derived(
		billing?.tiers.find((tier) => tier.current) ?? billing?.tiers.at(-1) ?? null
	);

	onMount(() => {
		void initialize();
	});

	async function initialize(): Promise<void> {
		const billingResult = consumeBillingResult();
		const googleResult = consumeGoogleDriveConnectionResult();
		const resultURL = new URL(window.location.href);
		const iCloudResult = resultURL.searchParams.get('icloud');
		if (iCloudResult) {
			resultURL.searchParams.delete('icloud');
			window.history.replaceState(
				{},
				'',
				`${resultURL.pathname}${resultURL.search}${resultURL.hash}`
			);
		}
		try {
			const [accountResponse, nextBilling, nextPublished] = await Promise.all([
				fetch('/api/auth/status', { cache: 'no-store' }),
				loadBillingStatus(),
				loadPublishedShareLinks().catch(() => null)
			]);
			account = (await accountResponse.json()) as AccountStatus;
			billing = nextBilling;
			if (nextPublished) published = nextPublished;
			if (billingResult === 'success') {
				message = nextBilling.entitled
					? 'Your Briefly membership is active.'
					: 'Payment completed. Membership activation may take a moment.';
			} else if (googleResult === 'connected') {
				message = 'Google Drive is connected and selected for library sync.';
			} else if (iCloudResult === 'connected') {
				message = 'iCloud is selected. This device is authorized for your private library.';
			} else if (iCloudResult === 'empty') {
				message = emptyICloudLibraryMessage;
			} else if (googleResult) {
				message = 'Google Drive could not be connected.';
			} else if (billingResult === 'cancelled') {
				message = 'Checkout was cancelled.';
			} else if (account.authenticated && !nextPublished) {
				message = 'Your published links could not be loaded.';
			}
		} catch (error) {
			message = error instanceof Error ? error.message : 'Your account could not be loaded.';
		} finally {
			loading = false;
		}
	}

	async function selectGoogleDrive(): Promise<void> {
		if (busy || !account) return;
		busy = true;
		try {
			const response = await fetch('/api/sync/provider', {
				method: 'POST',
				headers: { 'Content-Type': 'application/json' },
				body: JSON.stringify({ provider: 'google' })
			});
			if (!response.ok) throw new Error('Google Drive could not be selected.');
			account = { ...account, syncProvider: 'google' };
			message = 'Google Drive is selected for library sync.';
		} catch (error) {
			message = error instanceof Error ? error.message : 'Google Drive could not be selected.';
		} finally {
			busy = false;
		}
	}

	async function removeGoogleDrive(): Promise<void> {
		if (busy || !account) return;
		busy = true;
		try {
			await disconnectGoogleDrive();
			account = {
				...account,
				syncProvider: account.syncProvider === 'google' ? null : account.syncProvider,
				google: { ...account.google, connected: false }
			};
			message = 'Google Drive was disconnected. Its existing files were not deleted.';
		} catch (error) {
			message = error instanceof Error ? error.message : 'Google Drive could not be disconnected.';
		} finally {
			busy = false;
		}
	}

	async function removeICloud(): Promise<void> {
		if (busy || !account) return;
		busy = true;
		try {
			await disconnectICloud();
			account = {
				...account,
				syncProvider: account.syncProvider === 'icloud' ? null : account.syncProvider,
				icloud: { ...account.icloud, connected: false }
			};
			message = 'iCloud sync was stopped. Its existing private data was not deleted.';
		} catch (error) {
			message = error instanceof Error ? error.message : 'iCloud sync could not be stopped.';
		} finally {
			busy = false;
		}
	}

	function connectICloud(): void {
		const returnTo = `${window.location.pathname}${window.location.search}${window.location.hash}`;
		window.location.assign(`/icloud?return_to=${encodeURIComponent(returnTo)}`);
	}

	async function subscribe(): Promise<void> {
		if (busy) return;
		busy = true;
		try {
			await beginBrieflyPlusCheckout();
		} catch (error) {
			message = error instanceof Error ? error.message : 'Checkout could not be opened.';
			busy = false;
		}
	}

	async function manageBilling(): Promise<void> {
		if (busy) return;
		busy = true;
		try {
			await openBillingPortal();
		} catch (error) {
			message = error instanceof Error ? error.message : 'Billing could not be opened.';
			busy = false;
		}
	}

	async function signOut(): Promise<void> {
		if (busy) return;
		busy = true;
		try {
			await fetch('/api/auth/logout', { method: 'POST' });
			window.location.reload();
		} catch (error) {
			message = error instanceof Error ? error.message : 'Sign out failed.';
			busy = false;
		}
	}

	async function stopPublishing(link: ShareLinkStatus): Promise<void> {
		if (!link.token || revokingToken) return;
		const title = link.metadata?.title ?? link.captureID ?? 'this document';
		if (!window.confirm(`Stop sharing “${title}”?`)) return;
		revokingToken = link.token;
		try {
			await revokeShareLink(link.token);
			published = {
				...published,
				links: published.links.filter((candidate) => candidate.token !== link.token)
			};
			message = 'The public link was revoked.';
		} catch (error) {
			message = error instanceof Error ? error.message : 'The public link could not be revoked.';
		} finally {
			revokingToken = null;
		}
	}

	function publishedDate(value?: string): string {
		if (!value) return '';
		const date = new Date(value);
		return Number.isNaN(date.getTime())
			? ''
			: date.toLocaleDateString(undefined, { dateStyle: 'medium' });
	}
</script>

<svelte:head>
	<title>Your account — Briefly</title>
	<meta name="description" content="Manage your Briefly membership, sync, and app downloads." />
</svelte:head>

<main class="account-page">
	<header>
		<a class="brand" href="/landing">
			<img src="/icons/icon-192.png" alt="" />
			<span>Briefly</span>
		</a>
	</header>

	{#if loading}
		<section class="account-state" aria-live="polite">
			<h1>Loading your account…</h1>
		</section>
	{:else if !account?.authenticated}
		<section class="account-state">
			<p class="eyebrow">Briefly account</p>
			<h1>Sign in before you start.</h1>
			<p>Your account holds membership, app downloads, and sync settings.</p>
			<div class="sign-in-actions">
				{#if account?.providers?.apple !== false}
					<a class="primary-action" href="/api/auth/apple/start?return_to=%2Faccount">
						<LogInIcon /> Continue with Apple
					</a>
				{/if}
				{#if account?.providers?.google !== false}
					<a class="secondary-action" href="/api/auth/google/start?return_to=%2Faccount">
						<LogInIcon /> Continue with Google
					</a>
				{/if}
			</div>
			<small>By signing in, you agree to the <a href="/terms">Terms</a> and acknowledge the <a href="/privacy">Privacy Notice</a>.</small>
		</section>
	{:else}
		<div class="account-shell">
			<section class="account-heading">
				<div>
					<p class="eyebrow">Your account</p>
					<h1>Welcome back.</h1>
					<p>{account.email}</p>
				</div>
				<button class="secondary-action" onclick={signOut} disabled={busy}>
					<LogOutIcon /> Sign out
				</button>
			</section>

			{#if message}<p class="account-message" role="status">{message}</p>{/if}

			<div class="account-grid">
				<section class="account-card membership-card">
					<div>
						<p class="eyebrow">Membership</p>
						<h2>{billing?.entitled ? 'Active' : 'Choose your plan'}</h2>
						{#if billing?.entitled && billing.subscription}
							<p>
								{formatMonthlyPrice(
									billing.subscription.amount,
									billing.subscription.currency
								)}/month · {billing.subscription.tierName} price
							</p>
							<button class="primary-action" onclick={manageBilling} disabled={busy}>
								Manage billing <ArrowUpRightIcon />
							</button>
						{:else if billing?.entitled}
							<p>Complimentary Plus access for this account.</p>
						{:else}
							<p>One membership for capture, reading, sync, sharing, and all Briefly apps.</p>
							<button class="primary-action" onclick={subscribe} disabled={busy || !billing?.configured}>
								{currentTier
									? `Join for ${formatMonthlyPrice(currentTier.amount)}/month`
									: 'Choose Briefly'}
								<ArrowUpRightIcon />
							</button>
						{/if}
					</div>
				</section>

				<section class="account-card sync-card" id="sync">
					<div>
						<p class="eyebrow">Library sync</p>
						<h2>
							{account.syncProvider === 'icloud'
								? 'iCloud selected'
								: account.syncProvider === 'google'
									? 'Google Drive selected'
									: 'Ready to connect'}
						</h2>
						<div class="sync-providers">
							<div>
								<span>
									<strong>iCloud</strong>
									<small>
										{account.icloud?.configured
											? account.syncProvider === 'icloud'
												? 'Selected'
												: 'Available'
											: 'Not configured'}
									</small>
								</span>
								<button
									class="secondary-action"
									onclick={connectICloud}
									disabled={busy || !account.icloud?.configured}
								>
									{account.syncProvider === 'icloud' ? 'Authorize this device' : 'Use iCloud'}
								</button>
								{#if account.syncProvider === 'icloud'}
									<button class="text-action" onclick={removeICloud} disabled={busy}>
										Stop sync
									</button>
								{/if}
							</div>
							<div>
								<span>
									<strong>Google Drive</strong>
									<small>
										{account.google?.connected
											? account.syncProvider === 'google'
												? 'Selected'
												: 'Connected'
											: account.google?.configured
												? 'Available'
												: 'Not configured'}
									</small>
								</span>
								{#if account.google?.connected}
									<button
										class="secondary-action"
										onclick={selectGoogleDrive}
										disabled={busy || account.syncProvider === 'google'}
									>
										{account.syncProvider === 'google' ? 'Selected' : 'Use Google Drive'}
									</button>
									<button class="text-action" onclick={removeGoogleDrive} disabled={busy}>
										Disconnect
									</button>
								{:else}
									<button
										class="secondary-action"
										onclick={beginGoogleDriveConnection}
										disabled={busy || !account.google?.configured}
									>
										Connect
									</button>
								{/if}
							</div>
						</div>
					</div>
				</section>
			</div>

			<section class="published-links">
				<div class="published-links-heading">
					<div>
						<p class="eyebrow">Published links</p>
						<h2>Shared from your library</h2>
					</div>
					<p>{published.links.length} of {published.limit} active</p>
				</div>

				{#if published.links.length}
					<div class="published-list">
						{#each published.links as link (link.token)}
							<article class="published-link">
								<div class="published-link-copy">
									<div>
										<h3>{link.metadata?.title ?? link.captureID ?? 'Published document'}</h3>
										<span
											class="published-status"
											class:failed={link.status === 'failed'}
											class:preparing={link.status === 'preparing'}
										>
											{link.status === 'ready'
												? 'Published'
												: link.status === 'failed'
													? 'Failed'
													: 'Preparing'}
										</span>
									</div>
									<p>{link.url}</p>
									{#if publishedDate(link.updatedAt)}
										<small>Updated {publishedDate(link.updatedAt)}</small>
									{/if}
								</div>
								<div class="published-link-actions">
									{#if link.status === 'ready' && link.url}
										<a class="secondary-action" href={link.url} target="_blank" rel="noreferrer">
											Open <ArrowUpRightIcon />
										</a>
									{/if}
									<button
										class="secondary-action danger-action"
										disabled={revokingToken !== null}
										onclick={() => stopPublishing(link)}
									>
										{revokingToken === link.token ? 'Stopping…' : 'Stop sharing'}
									</button>
								</div>
							</article>
						{/each}
					</div>
				{:else}
					<div class="published-empty">
						<p>You have no active public links.</p>
					</div>
				{/if}
			</section>

			<section class="downloads">
				<div class="downloads-heading">
					<div>
						<p class="eyebrow">Your apps</p>
						<h2>Download Briefly</h2>
					</div>
					<p>Installers are available here after your membership is active.</p>
				</div>

				{#if billing?.entitled}
					<div class="download-grid">
						{#each desktopDownloads as download}
							<a href={download.href}>
								<LaptopIcon />
								<span>
									<strong>{download.platform}</strong>
									<small>{download.detail}</small>
								</span>
								<b>{download.file}</b>
								<DownloadIcon />
							</a>
						{/each}
						<a href="/">
							<GlobeIcon />
							<span>
								<strong>Web app</strong>
								<small>Use Briefly in your browser</small>
							</span>
							<b>Open</b>
							<ArrowUpRightIcon />
						</a>
					</div>
				{:else}
					<div class="downloads-locked">
						<p>Activate your membership above to unlock app downloads.</p>
					</div>
				{/if}
			</section>

			<footer>
				<span>Need help or account deletion? <a href="mailto:hello@readbriefly.fyi">Contact support</a>.</span>
				<nav><a href="/terms">Terms</a><a href="/privacy">Privacy</a><a href="/imprint">Imprint</a></nav>
			</footer>
		</div>
	{/if}
</main>

<style>
	:global(body) {
		overflow: auto;
		background: #eeebdf;
	}

	.account-page {
		min-height: 100dvh;
		padding: 24px;
		background:
			radial-gradient(circle at 15% 0%, rgb(50 99 224 / 12%), transparent 28%),
			linear-gradient(145deg, #f4f1e7, #e5e1d5);
		color: #151512;
	}

	header,
	.account-shell {
		width: min(1100px, 100%);
		margin: 0 auto;
	}

	header,
	.brand,
	.account-heading,
	.secondary-action,
	.primary-action,
	.download-grid a,
	footer,
	footer nav {
		display: flex;
		align-items: center;
	}

	header {
		justify-content: space-between;
	}

	.brand {
		gap: 10px;
		color: inherit;
		font-size: 18px;
		font-weight: 780;
	}

	.brand img {
		width: 34px;
		height: 34px;
	}

	.secondary-action {
		gap: 7px;
		color: #4b4a44;
		font-size: 12px;
		font-weight: 680;
	}

	.secondary-action :global(svg),
	.primary-action :global(svg) {
		width: 15px;
	}

	.account-state {
		display: grid;
		width: min(540px, 100%);
		min-height: calc(100dvh - 120px);
		margin: 0 auto;
		place-content: center;
		justify-items: center;
		text-align: center;
	}

	.account-state h1,
	.account-heading h1 {
		margin: 7px 0 10px;
		font-family: "Iowan Old Style", Charter, Georgia, serif;
		font-size: clamp(38px, 7vw, 68px);
		letter-spacing: -0.055em;
		line-height: 0.96;
	}

	.account-state > p:not(.eyebrow) {
		max-width: 430px;
		margin: 0;
		color: #65635b;
		line-height: 1.6;
	}

	.account-state small {
		max-width: 430px;
		margin-top: 18px;
		color: #77746a;
		font-size: 10px;
		line-height: 1.5;
	}

	.account-state small a,
	footer a {
		text-decoration: underline;
		text-underline-offset: 2px;
	}

	.sign-in-actions {
		display: flex;
		flex-wrap: wrap;
		justify-content: center;
		gap: 10px;
		margin-top: 22px;
	}

	.sign-in-actions .primary-action {
		margin-top: 0;
	}

	.eyebrow {
		margin: 0;
		color: #5d5b53;
		font-size: 10px;
		font-weight: 780;
		letter-spacing: 0.13em;
		text-transform: uppercase;
	}

	.primary-action,
	.secondary-action {
		min-height: 42px;
		justify-content: center;
		gap: 8px;
		padding: 0 16px;
		border: 1px solid rgb(21 21 18 / 16%);
		border-radius: 999px;
		background: transparent;
		font: inherit;
		font-size: 12px;
		font-weight: 730;
		cursor: pointer;
	}

	.primary-action {
		width: fit-content;
		margin-top: 22px;
		border: 0;
		background: #102e84;
		color: white;
	}

	button:disabled {
		cursor: not-allowed;
		opacity: 0.55;
	}

	.account-shell {
		padding: clamp(70px, 10vw, 130px) 0 40px;
	}

	.account-heading {
		justify-content: space-between;
		gap: 30px;
	}

	.account-heading h1 {
		font-size: clamp(46px, 8vw, 88px);
	}

	.account-heading > div > p:last-child {
		margin: 0;
		color: #65635b;
	}

	.account-message {
		margin: 24px 0 0;
		padding: 13px 16px;
		border: 1px solid rgb(21 21 18 / 12%);
		border-radius: 12px;
		background: rgb(255 255 255 / 45%);
		font-size: 12px;
	}

	.account-grid {
		display: grid;
		grid-template-columns: 1.35fr 1fr;
		gap: 12px;
		margin-top: 48px;
	}

	.account-card,
	.published-links,
	.downloads {
		border: 1px solid rgb(21 21 18 / 14%);
		border-radius: 22px;
		background: rgb(250 248 241 / 72%);
		box-shadow: 0 20px 54px rgb(31 27 18 / 7%);
	}

	.account-card {
		min-height: 240px;
		padding: 26px;
	}

	.membership-card {
		background:
			radial-gradient(circle at 90% 10%, rgb(103 143 255 / 44%), transparent 32%),
			linear-gradient(145deg, #102f88, #071437);
		color: white;
	}

	.membership-card .eyebrow,
	.membership-card p {
		color: rgb(255 255 255 / 62%);
	}

	.account-card h2,
	.downloads h2 {
		margin: 6px 0 10px;
		font-size: 25px;
		letter-spacing: -0.04em;
	}

	.account-card p:not(.eyebrow) {
		margin: 0;
		color: #69675e;
		font-size: 12px;
		line-height: 1.55;
	}

	.sync-providers {
		display: grid;
		gap: 10px;
		margin-top: 18px;
	}

	.sync-providers > div,
	.sync-providers span {
		display: flex;
		align-items: center;
	}

	.sync-providers > div {
		flex-wrap: wrap;
		gap: 8px;
		padding-top: 10px;
		border-top: 1px solid rgb(21 21 18 / 10%);
	}

	.sync-providers span {
		min-width: 120px;
		flex: 1;
		align-items: flex-start;
		flex-direction: column;
	}

	.sync-providers small {
		color: #77746a;
		font-size: 10px;
	}

	.sync-providers .secondary-action {
		min-height: 32px;
		padding: 0 11px;
		font-size: 10px;
	}

	.text-action {
		padding: 0;
		border: 0;
		background: transparent;
		color: #69675e;
		font: inherit;
		font-size: 10px;
		text-decoration: underline;
		cursor: pointer;
	}

	.published-links {
		margin-top: 12px;
		padding: clamp(26px, 4vw, 44px);
	}

	.published-links-heading,
	.published-link,
	.published-link-copy > div,
	.published-link-actions,
	.published-empty {
		display: flex;
		align-items: center;
	}

	.published-links-heading {
		justify-content: space-between;
		gap: 30px;
	}

	.published-links h2 {
		margin: 6px 0 0;
		font-size: 25px;
		letter-spacing: -0.04em;
	}

	.published-links-heading > p {
		margin: 0;
		color: #69675e;
		font-size: 11px;
	}

	.published-list {
		display: grid;
		gap: 8px;
		margin-top: 24px;
	}

	.published-link {
		gap: 14px;
		min-width: 0;
		padding: 14px;
		border: 1px solid rgb(21 21 18 / 12%);
		border-radius: 14px;
		background: rgb(255 255 255 / 38%);
	}

	.published-link-copy {
		min-width: 0;
		flex: 1;
	}

	.published-link-copy > div {
		gap: 8px;
	}

	.published-link h3 {
		overflow: hidden;
		margin: 0;
		font-size: 13px;
		text-overflow: ellipsis;
		white-space: nowrap;
	}

	.published-link p,
	.published-link small {
		display: block;
		overflow: hidden;
		margin: 3px 0 0;
		color: #747168;
		font-size: 10px;
		text-overflow: ellipsis;
		white-space: nowrap;
	}

	.published-status {
		padding: 3px 6px;
		border-radius: 999px;
		background: rgb(33 132 83 / 10%);
		color: #1d7048;
		font-size: 8px;
		font-weight: 760;
		letter-spacing: 0.06em;
		text-transform: uppercase;
	}

	.published-status.preparing {
		background: rgb(178 120 28 / 11%);
		color: #8a5c14;
	}

	.published-status.failed {
		background: rgb(173 48 48 / 10%);
		color: #9a3030;
	}

	.published-link-actions {
		flex: 0 0 auto;
		gap: 6px;
	}

	.published-link-actions .secondary-action {
		min-height: 34px;
		padding: 0 12px;
		font-size: 10px;
	}

	.danger-action {
		color: #9a3030;
	}

	.published-empty {
		min-height: 100px;
		justify-content: center;
		gap: 9px;
		margin-top: 24px;
		border: 1px dashed rgb(21 21 18 / 24%);
		border-radius: 14px;
		color: #69675e;
		font-size: 12px;
	}

	.downloads {
		margin-top: 12px;
		padding: clamp(26px, 4vw, 44px);
	}

	.downloads-heading {
		display: flex;
		align-items: end;
		justify-content: space-between;
		gap: 30px;
	}

	.downloads-heading > p {
		max-width: 360px;
		margin: 0 0 8px;
		color: #69675e;
		font-size: 12px;
		line-height: 1.5;
	}

	.download-grid {
		display: grid;
		grid-template-columns: repeat(2, 1fr);
		gap: 8px;
		margin-top: 24px;
	}

	.download-grid a {
		min-height: 78px;
		gap: 13px;
		padding: 13px 16px;
		border: 1px solid rgb(21 21 18 / 13%);
		border-radius: 14px;
		background: rgb(255 255 255 / 38%);
		color: inherit;
	}

	.download-grid a > :global(svg:first-child) {
		width: 21px;
	}

	.download-grid a > :global(svg:last-child) {
		width: 15px;
	}

	.download-grid span {
		display: grid;
		flex: 1;
	}

	.download-grid small {
		margin-top: 3px;
		color: #747168;
	}

	.download-grid b {
		color: #747168;
		font-size: 10px;
		text-transform: uppercase;
	}

	.downloads-locked {
		display: flex;
		min-height: 110px;
		align-items: center;
		justify-content: center;
		gap: 10px;
		margin-top: 24px;
		border: 1px dashed rgb(21 21 18 / 24%);
		border-radius: 14px;
		color: #69675e;
		font-size: 12px;
	}

	footer {
		justify-content: space-between;
		gap: 20px;
		padding: 28px 4px 0;
		color: #69675e;
		font-size: 10px;
	}

	footer nav {
		gap: 14px;
	}

	@media (max-width: 850px) {
		.account-grid {
			grid-template-columns: 1fr;
		}

		.account-card {
			min-height: 240px;
		}

	}

	@media (max-width: 600px) {
		.account-page {
			padding: 16px;
		}

		.account-heading,
		.downloads-heading,
		.published-links-heading,
		footer {
			align-items: flex-start;
			flex-direction: column;
		}

		.download-grid {
			grid-template-columns: 1fr;
		}

		.published-link {
			align-items: flex-start;
			flex-wrap: wrap;
		}

		.published-link-copy {
			width: 100%;
			flex: none;
		}

		.published-link-actions {
			width: 100%;
		}
	}
</style>
