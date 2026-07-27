<script lang="ts">
	import { onMount } from 'svelte';
	import CloudIcon from '@lucide/svelte/icons/cloud';
	import {
		exposeICloudBridge,
		fetchICloudLibraryIndex,
		iCloudIdentity,
		selectICloudSync,
		waitForICloudSignIn
	} from '$lib/icloud.js';

	let message = $state('Checking iCloud…');
	let error = $state('');
	let cancelHref = $state('/account');

	onMount(() => {
		void initialize();
	});

	async function initialize(): Promise<void> {
		exposeICloudBridge();
		const parameters = new URLSearchParams(window.location.search);
		const requestedReturnTo = parameters.get('return_to');
		cancelHref =
			requestedReturnTo?.startsWith('/') && !requestedReturnTo.startsWith('//')
				? requestedReturnTo
				: '/account';
		if (parameters.get('bridge') === '1') {
			message = 'CloudKit bridge ready.';
			return;
		}
		try {
			const identity = await iCloudIdentity();
			if (identity?.userRecordName) {
				await connected();
				return;
			}
			message = 'Sign in with the Apple Account that should hold this library.';
			await waitForICloudSignIn();
			await connected();
		} catch (value) {
			error = value instanceof Error ? value.message : 'iCloud could not be connected.';
		}
	}

	async function connected(): Promise<void> {
		message = 'Checking your private iCloud library…';
		const projection = await fetchICloudLibraryIndex();
		await selectICloudSync();
		const parameters = new URLSearchParams(window.location.search);
		const requestedReturnTo = parameters.get('return_to');
		const destination = new URL(
			requestedReturnTo?.startsWith('/') && !requestedReturnTo.startsWith('//')
				? requestedReturnTo
				: '/account',
			window.location.origin
		);
		destination.searchParams.set('icloud', projection ? 'connected' : 'empty');
		window.location.replace(destination);
	}
</script>

<svelte:head>
	<title>Connect iCloud — Briefly</title>
	<meta name="robots" content="noindex" />
</svelte:head>

<main>
	<section>
		<div class="icon"><CloudIcon /></div>
		<p class="eyebrow">Library sync</p>
		<h1>Connect iCloud</h1>
		<p>{error || message}</p>
		<div id="apple-sign-in-button"></div>
		<div id="apple-sign-out-button" hidden></div>
		<a href={cancelHref}>Cancel</a>
	</section>
</main>

<style>
	main {
		min-height: 100vh;
		display: grid;
		place-items: center;
		padding: 2rem;
		background: #f3f1e9;
		color: #20231f;
	}

	section {
		width: min(28rem, 100%);
		display: grid;
		justify-items: center;
		gap: 1rem;
		padding: 2.5rem;
		text-align: center;
		border: 1px solid rgb(32 35 31 / 12%);
		border-radius: 1.5rem;
		background: #fffefa;
		box-shadow: 0 1.5rem 4rem rgb(32 35 31 / 10%);
	}

	.icon {
		width: 3rem;
		height: 3rem;
		display: grid;
		place-items: center;
		border-radius: 1rem;
		background: #e4ecdf;
		color: #40543b;
	}

	.icon :global(svg) {
		width: 1.5rem;
	}

	.eyebrow {
		margin: 0;
		font-size: 0.75rem;
		font-weight: 700;
		letter-spacing: 0.12em;
		text-transform: uppercase;
		color: #647060;
	}

	h1,
	p {
		margin: 0;
	}

	h1 {
		font-size: 2rem;
	}

	section > p:not(.eyebrow) {
		max-width: 22rem;
		line-height: 1.5;
		color: #596055;
	}

	a {
		color: inherit;
		font-size: 0.9rem;
	}
</style>
