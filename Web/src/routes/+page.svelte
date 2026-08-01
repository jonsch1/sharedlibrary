<script lang="ts">
  import { onMount } from 'svelte';
  import PublicShareReader from '$lib/PublicShareReader.svelte';

  let publicShareToken = $state('');

  onMount(() => {
    const token = new URL(window.location.href).searchParams.get('shared') ?? '';
    if (/^[A-Za-z0-9_-]{32}$/.test(token)) {
      publicShareToken = token;
    } else {
      window.location.replace('/landing');
    }
  });
</script>

{#if publicShareToken}
  <PublicShareReader token={publicShareToken} />
{/if}
