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
	<div class="library-prose prose max-w-none text-inherit! [font-family:inherit]! [&_a]:text-primary! [&_blockquote]:border-border! [&_blockquote]:text-muted-foreground! [&_code]:bg-muted! [&_code]:bg-none! [&_code]:text-foreground! [&_code]:font-mono! [&_h1]:text-inherit! [&_h2]:text-inherit! [&_h3]:text-inherit! [&_h4]:text-inherit! [&_h5]:text-inherit! [&_h6]:text-inherit! [&_hr]:border-border! [&_li]:text-inherit! [&_p]:text-inherit! [&_pre]:bg-muted! [&_pre]:bg-none! [&_pre]:text-foreground! [&_pre]:font-mono! [&_strong]:text-inherit! [&_td]:border-border! [&_th]:border-border!">
		{#each paragraphs as paragraph}
			<p>{paragraph}</p>
		{/each}
	</div>
{:else}
	<div class="library-prose prose max-w-none text-inherit! [font-family:inherit]! [&_a]:text-primary! [&_blockquote]:border-border! [&_blockquote]:text-muted-foreground! [&_code]:bg-muted! [&_code]:bg-none! [&_code]:text-foreground! [&_code]:font-mono! [&_h1]:text-inherit! [&_h2]:text-inherit! [&_h3]:text-inherit! [&_h4]:text-inherit! [&_h5]:text-inherit! [&_h6]:text-inherit! [&_hr]:border-border! [&_li]:text-inherit! [&_p]:text-inherit! [&_pre]:bg-muted! [&_pre]:bg-none! [&_pre]:text-foreground! [&_pre]:font-mono! [&_strong]:text-inherit! [&_td]:border-border! [&_th]:border-border!">
		{@html html}
	</div>
{/if}
