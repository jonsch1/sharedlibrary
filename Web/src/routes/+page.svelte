<script lang="ts">
  import { page } from '$app/state';
  import { browser } from '$app/environment';
  import PublicShareReader from '$lib/PublicShareReader.svelte';

  const publicShareToken = $derived(browser ? page.url.searchParams.get('shared') ?? '' : '');
  const validToken = $derived(/^[A-Za-z0-9_-]{32}$/.test(publicShareToken));

  $effect(() => {
    if (!validToken) window.location.replace('/landing');
  });
</script>

{#if validToken}
  {#key publicShareToken}
    <PublicShareReader token={publicShareToken} />
  {/key}
{/if}
