<script lang="ts">
	import './layout.css';
	import { onMount } from 'svelte';
	import { initializeTheme } from '../../../Shared/themes';

	let { children } = $props();

	onMount(initializeTheme);
</script>

<svelte:head>
	<link rel="icon" type="image/svg+xml" href="/brand/briefly-mark.svg" />
	<meta name="theme-color" content="#ffffff" />
</svelte:head>
{@render children()}
