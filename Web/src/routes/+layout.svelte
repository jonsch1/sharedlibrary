<script lang="ts">
	import './layout.css';
	import { onMount } from 'svelte';
	import { initializeTheme } from '../../../Shared/themes';

	let { children } = $props();

	onMount(initializeTheme);
</script>

<svelte:head>
	<link rel="icon" type="image/png" sizes="192x192" href="/icons/icon-192.png" />
	<meta name="theme-color" content="#ffffff" />
</svelte:head>
{@render children()}
