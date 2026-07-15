<script lang="ts">
	import '../app.css';
	import { browser } from '$app/environment';
	import DesktopLyrics from '$lib/components/panels/DesktopLyrics.svelte';

	let { children } = $props();

	let isLyricsWindow = $state(false);

	$effect(() => {
		if (!browser) return;
		import('@tauri-apps/api/window').then(({ getCurrentWindow }) => {
			const win = getCurrentWindow();
			isLyricsWindow = win.label === 'lyrics';
			// 主窗口：渲染完成后显示，消除白屏
			if (win.label === 'main') win.show();
		});
	});
</script>

{#if isLyricsWindow}
	<DesktopLyrics />
{:else}
	{@render children()}
{/if}
