<script lang="ts">
	import { fetchICloudLibraryMediaURL, type SyncProvider } from '$lib/icloud.js';
	import type { LibraryMedia } from '$lib/library.js';

	let {
		favicon,
		provider
	}: {
		favicon?: LibraryMedia;
		provider: SyncProvider | null;
	} = $props();

	let resolvedURL = $state('');
	let request = 0;

	$effect(() => {
		const current = ++request;
		if (!favicon) {
			resolvedURL = '';
			return;
		}
		if (provider === 'google') {
			resolvedURL = `/api/media/favicon/${favicon.contentHash}`;
			return;
		}
		resolvedURL = '';
		if (provider === 'icloud') {
			void fetchICloudLibraryMediaURL(favicon)
				.then((url) => {
					if (request === current) resolvedURL = url;
				})
				.catch(() => {
					if (request === current) resolvedURL = '';
				});
		}
	});
</script>

{#if resolvedURL}
	<img src={resolvedURL} alt="" aria-hidden="true" onerror={() => (resolvedURL = '')} />
{:else}
	<svg viewBox="0 0 24 24" aria-hidden="true">
		<path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8zM14 2v6h6" />
	</svg>
{/if}

<style>
	img,
	svg {
		width: 16px;
		height: 16px;
		flex: 0 0 16px;
	}

	img {
		border-radius: 3px;
		object-fit: contain;
	}

	svg {
		fill: none;
		stroke: currentColor;
		stroke-linecap: round;
		stroke-linejoin: round;
		stroke-width: 2;
	}
</style>
