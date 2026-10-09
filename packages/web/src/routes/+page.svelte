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

<svelte:head>
  <meta name="robots" content="noindex, nofollow, noarchive" />
  <meta name="referrer" content="no-referrer" />
  <meta property="og:type" content="article" />
  <meta property="og:site_name" content="Briefly" />
  <meta property="og:title" content="Shared with Briefly" />
  <meta property="og:description" content="Read the summary at the depth you choose." />
  <meta property="og:image" content="https://www.readbriefly.fyi/og-landing-v2.png" />
  <meta property="og:image:width" content="1200" />
  <meta property="og:image:height" content="630" />
  <meta property="og:image:alt" content="Briefly on Mac and iPhone" />
  <meta name="twitter:card" content="summary_large_image" />
</svelte:head>

{#if validToken}
  {#key publicShareToken}
    <PublicShareReader token={publicShareToken} />
  {/key}
{/if}
