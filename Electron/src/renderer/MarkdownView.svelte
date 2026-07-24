<script lang="ts">
  import DOMPurify from 'dompurify';
  import { marked } from 'marked';

  let { text }: { text: string } = $props();
  let html = $derived(
    DOMPurify.sanitize(
      marked.parse(text, { gfm: true, breaks: false }) as string,
      {
        USE_PROFILES: { html: true },
        FORBID_TAGS: ['img', 'iframe', 'video', 'audio', 'style']
      }
    )
  );
</script>

<div class="library-prose">{@html html}</div>
