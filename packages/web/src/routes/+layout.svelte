<script lang="ts">
	import './layout.css';
	import { onMount } from 'svelte';
	import { initializeTheme } from '$lib/reader/themes';

	let { children } = $props();

	onMount(initializeTheme);
</script>

<svelte:head>
	<link rel="icon" type="image/png" href="/brand/briefly-app-icon.png" />
	<link rel="apple-touch-icon" href="/brand/briefly-app-icon.png" />
	<meta name="theme-color" content="#ffffff" />
</svelte:head>
{@render children()}
