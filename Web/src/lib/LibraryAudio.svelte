<script lang="ts">
	import AudioPlayer from '../../../Shared/AudioPlayer.svelte';
	import { fetchICloudLibraryMediaURL, type SyncProvider } from '$lib/icloud.js';
	import type { LibraryMedia } from '$lib/library.js';

	let {
		title,
		audio,
		mediaURL,
		provider
	}: {
		title: string;
		audio?: LibraryMedia;
		mediaURL?: string;
		provider: SyncProvider | null;
	} = $props();

	let resolvedURL = $state('');
	let request = 0;

	$effect(() => {
		const current = ++request;
		if (!audio) {
			resolvedURL = mediaURL ?? '';
			return;
		}
		if (provider === 'google') {
			resolvedURL = `/api/media/audio/${audio.contentHash}`;
			return;
		}
		resolvedURL = '';
		if (provider === 'icloud') {
			void fetchICloudLibraryMediaURL(audio)
				.then((url) => {
					if (request === current) resolvedURL = url;
				})
				.catch(() => {
					if (request === current) resolvedURL = mediaURL ?? '';
				});
		}
	});
</script>

{#if resolvedURL}
	<AudioPlayer src={resolvedURL} {title} />
{/if}
