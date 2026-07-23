<script lang="ts">
	import { browser } from '$app/environment';
	import DOMPurify from 'dompurify';
	import { marked } from 'marked';

	let { text }: { text: string } = $props();

	let html = $derived(
		browser
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
</script>

<div class="library-prose prose prose-stone max-w-none dark:prose-invert">
	{@html html}
</div>
