<script lang="ts">
	import '../app.css';
	import SplashScreen from '$lib/components/SplashScreen.svelte';
	import { browser } from '$app/environment';

	let { children } = $props();
	let showSplash = $state(true);

	$effect(() => {
		if (!browser) return;
		import('@tauri-apps/api/window').then(({ getCurrentWindow }) => {
			const win = getCurrentWindow();
			if (win.label === 'main') win.show();
		});
	});
</script>

{#if showSplash}
	<SplashScreen done={() => showSplash = false} />
{:else}
	{@render children()}
{/if}
