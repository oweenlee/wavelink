<script lang="ts">
	import Sidebar from '$lib/components/layout/Sidebar.svelte';
	import Header from '$lib/components/layout/Header.svelte';
	import NowPlayingBar from '$lib/components/layout/NowPlayingBar.svelte';
	import LibraryView from '$lib/components/views/LibraryView.svelte';
	import EffectsView from '$lib/components/views/EffectsView.svelte';
	import SettingsView from '$lib/components/views/SettingsView.svelte';
	import NowPlayingView from '$lib/components/views/NowPlayingView.svelte';
	import LyricsPanel from '$lib/components/panels/LyricsPanel.svelte';
	import PlaylistPanel from '$lib/components/panels/PlaylistPanel.svelte';

	import { getPlaybackState } from '$lib/stores/playback.svelte';
	import { getUiState } from '$lib/stores/ui.svelte';
	import { getSettingsState } from '$lib/stores/settings.svelte';
	import { getLyricsState } from '$lib/stores/lyrics.svelte';
	import { createKeyboardHandler } from '$lib/keyboard';

	const playback = getPlaybackState();
	const ui = getUiState();
	const settings = getSettingsState();
	const lyrics = getLyricsState();

	const onKeydown = createKeyboardHandler(playback);

	// 桌面歌词：推送当前歌词行到歌词窗口
	$effect(() => {
		if (!ui.showDesktopLyrics) return;
		const idx = lyrics.currentIndex;
		const lines = lyrics.lines;
		const current = idx >= 0 ? lines[idx]?.text ?? '' : '';
		const next = idx >= 0 && idx < lines.length - 1 ? lines[idx + 1]?.text ?? '' : '';
		import('@tauri-apps/api/event').then(({ emit }) => {
			emit('lyrics:current_line', current);
			emit('lyrics:next_line', next);
		});
	});
</script>

<svelte:window onkeydown={onKeydown} />

<div class="app" style="--accent: {settings.accentColor};">
	<div class="app-layout">
		<Sidebar />
		<main class="main-panel">
			<Header />
			<div class="main-scroll">
				{#key ui.view}
					<div class="view-fade" style="animation-name: {ui.view === 'library' ? 'fadeInRight' : 'fadeInLeft'};">
						{#if ui.view === 'library'}
							<LibraryView />
						{:else if ui.view === 'effects'}
							<EffectsView />
						{:else if ui.view === 'settings'}
							<SettingsView />
						{/if}
					</div>
				{/key}
			</div>
		</main>
	</div>

	{#if ui.showNowPlaying}
		<NowPlayingView />
	{/if}

	<NowPlayingBar />
	<LyricsPanel />
	<PlaylistPanel />
</div>

<style>
	.app {
		width: 100vw; height: 100vh; overflow: hidden;
		color: var(--fg-primary);
		background: var(--bg);
		background-image: var(--bg-gradient);
		background-attachment: fixed;
	}

	.app-layout {
		display: flex;
		height: 100vh;
		width: 100vw;
		padding-bottom: 82px;
	}

	.main-panel {
		flex: 1;
		display: flex;
		flex-direction: column;
		min-width: 0;
		overflow: hidden;
	}

	.main-scroll {
		flex: 1;
		overflow-y: auto;
		overflow-x: hidden;
	}

	.view-fade {
		animation-duration: 0.25s;
		animation-timing-function: var(--ease-out);
		animation-fill-mode: both;
	}

	@keyframes fadeInRight {
		from { opacity: 0; transform: translateX(12px); }
		to { opacity: 1; transform: translateX(0); }
	}
	@keyframes fadeInLeft {
		from { opacity: 0; transform: translateX(-12px); }
		to { opacity: 1; transform: translateX(0); }
	}
</style>
