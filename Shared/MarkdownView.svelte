<script lang="ts">
  import DOMPurify from 'dompurify';
  import { marked } from 'marked';
  import { sourceTextParagraphs } from './source-text';

  let { text, plain = false }: { text: string; plain?: boolean } = $props();
  let html = $derived(
    typeof window === 'undefined' || plain
      ? ''
      : DOMPurify.sanitize(
          marked.parse(text, { gfm: true, breaks: false }) as string,
          {
            USE_PROFILES: { html: true },
            FORBID_TAGS: ['img', 'iframe', 'video', 'audio', 'style']
          }
        )
  );
  let paragraphs = $derived(plain ? sourceTextParagraphs(text) : []);
</script>

{#if plain}
  <div class="library-prose">
    {#each paragraphs as paragraph}
      <p>{paragraph}</p>
    {/each}
  </div>
{:else}
  <div class="library-prose">{@html html}</div>
{/if}
