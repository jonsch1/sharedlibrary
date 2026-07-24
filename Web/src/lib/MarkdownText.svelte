<script lang="ts">
	import { browser } from '$app/environment';
	import DOMPurify from 'dompurify';
	import { marked } from 'marked';
	import { sourceTextParagraphs } from '$lib/source-text.js';

	let { text, plain = false }: { text: string; plain?: boolean } = $props();

	let html = $derived(
		browser && !plain
			? DOMPurify.sanitize(
					marked.parse(text, {
						gfm: true,
						breaks: false
					}) as string,
					{
						USE_PROFILES: { html: true },
						FORBID_TAGS: ['img', 'iframe', 'video', 'audio', 'style']
					}
				)
			: ''
	);
	let paragraphs = $derived(plain ? sourceTextParagraphs(text) : []);
</script>

{#if plain}
	<div class="library-prose prose prose-stone max-w-none dark:prose-invert">
		{#each paragraphs as paragraph}
			<p>{paragraph}</p>
		{/each}
	</div>
{:else}
	<div class="library-prose prose prose-stone max-w-none dark:prose-invert">
		{@html html}
	</div>
{/if}
