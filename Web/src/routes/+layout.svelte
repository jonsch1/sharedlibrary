<script lang="ts">
	import './layout.css';
	import { onMount } from 'svelte';
	import { initializeTheme } from '../../../Shared/themes';

	let { children } = $props();

	onMount(initializeTheme);
</script>

<svelte:head>
	<link rel="manifest" href="/manifest.webmanifest" />
	<link rel="icon" type="image/png" sizes="192x192" href="/icons/icon-192.png" />
	<link rel="apple-touch-icon" sizes="180x180" href="/icons/apple-touch-icon.png" />
	<meta name="theme-color" content="#ffffff" />
	<meta name="apple-mobile-web-app-status-bar-style" content="default" />
	<meta name="apple-mobile-web-app-title" content="Briefly" />
</svelte:head>
{@render children()}
