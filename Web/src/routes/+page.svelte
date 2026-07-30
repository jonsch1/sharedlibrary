<script lang="ts">
  import { onMount } from 'svelte';
  import BrieflyApp from '../../../Shared/App.svelte';
  import { webCapabilities } from '../../../Shared/app';
  import PublicShareReader from '$lib/PublicShareReader.svelte';
  import { createWebAppBridge } from '$lib/web-app.js';

  const bridge = createWebAppBridge();
  let publicShareToken = $state('');

  onMount(() => {
    const token = new URL(window.location.href).searchParams.get('shared') ?? '';
    if (/^[A-Za-z0-9_-]{32}$/.test(token)) publicShareToken = token;
    return bridge.start();
  });
</script>

{#if publicShareToken}
  <PublicShareReader token={publicShareToken} />
{:else}
  <BrieflyApp
    api={bridge.api}
    capabilities={webCapabilities}
    appIcon="/icons/icon-192.png"
    loadDemo={bridge.loadDemo}
  />
{/if}
