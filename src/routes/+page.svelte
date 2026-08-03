<script lang="ts">
	import Sidebar from '$lib/components/layout/Sidebar.svelte';
	import Header from '$lib/components/layout/Header.svelte';
	import NowPlayingBar from '$lib/components/layout/NowPlayingBar.svelte';
	import LibraryView from '$lib/components/views/LibraryView.svelte';
	import EffectsView from '$lib/components/views/EffectsView.svelte';
	import SettingsView from '$lib/components/views/SettingsView.svelte';
	import NasView from '$lib/components/views/NasView.svelte';
	import NowPlayingView from '$lib/components/views/NowPlayingView.svelte';
	import LyricsPanel from '$lib/components/panels/LyricsPanel.svelte';

	import { onMount } from 'svelte';
	import { getPlaybackState } from '$lib/stores/playback.svelte';
	import { getUiState } from '$lib/stores/ui.svelte';
	import { getSettingsState } from '$lib/stores/settings.svelte';
	import { createKeyboardHandler } from '$lib/keyboard';

	const playback = getPlaybackState();
	const ui = getUiState();
	const settings = getSettingsState();

	// 启动时恢复并应用已保存的设置（之前只在打开设置页时才加载，导致重启后全部失效）
	onMount(async () => {
		await settings.load();
		await settings.applyEngineConfig();
		if (settings.audioDevice) await settings.setAudioDevice(settings.audioDevice);
		await settings.setReplaygain(settings.replaygainEnabled);
		// 引擎默认 limiter/dither 开启、DSD 转 PCM；仅在保存值非默认时同步
		if (!settings.limiterEnabled) await settings.setLimiter(false);
		if (!settings.ditherEnabled) await settings.setDither(false);
		if (settings.dsdMode !== 'to_pcm') await settings.setDsdMode(settings.dsdMode);
	});

	const onKeydown = createKeyboardHandler(playback);

	let accentRgb = $derived.by(() => {
		const c = settings.accentColor;
		return `${parseInt(c.slice(1, 3), 16)}, ${parseInt(c.slice(3, 5), 16)}, ${parseInt(c.slice(5, 7), 16)}`;
	});
	let accentDim = $derived(`rgba(${accentRgb}, 0.15)`);
	let accentGlow = $derived(`rgba(${accentRgb}, 0.10)`);

</script>

<svelte:window onkeydown={onKeydown} />

<div class="app" style="--accent: {settings.accentColor}; --accent-rgb: {accentRgb}; --accent-dim: {accentDim}; --accent-glow: {accentGlow};">
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
						{:else if ui.view === 'nas'}
							<NasView />
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
		padding-bottom: 74px;
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
