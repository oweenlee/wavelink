<script lang="ts">
	import '../app.css';
	import { browser } from '$app/environment';
	import DesktopLyrics from '$lib/components/panels/DesktopLyrics.svelte';

	let { children } = $props();

	let isLyricsWindow = $state(false);

	$effect(() => {
		if (!browser) return;
		import('@tauri-apps/api/window').then(({ getCurrentWindow }) => {
			isLyricsWindow = getCurrentWindow().label === 'lyrics';
		});
	});
</script>

{#if isLyricsWindow}
	<DesktopLyrics />
{:else}
	{@render children()}
{/if}
