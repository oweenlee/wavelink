<script lang="ts">
	import { fly, fade } from 'svelte/transition';
	import { browser } from '$app/environment';
	import { getPlaybackState } from '$lib/stores/playback.svelte';
	import { getPlaylistState } from '$lib/stores/playlist.svelte';
	import { getUiState } from '$lib/stores/ui.svelte';
	import { getSettingsState } from '$lib/stores/settings.svelte';
	import { getLyricsState, loadForTrack } from '$lib/stores/lyrics.svelte';
	import { formatTime } from '$lib/data/music';
	import VolumeSlider from '$lib/components/controls/VolumeSlider.svelte';
	import ProgressBar from '$lib/components/controls/ProgressBar.svelte';

	const playback = getPlaybackState();
	const playlist = getPlaylistState();
	const ui = getUiState();
	const settings = getSettingsState();
	const lyrics = getLyricsState();

	let coverDataUrl = $state('');
	let coverLoaded = $state(false);
	let _lastTrackPath = '';

	$effect(() => {
		const track = playback.currentTrack;
		coverDataUrl = '';
		coverLoaded = false;
		if (!track || !browser) { loadForTrack(null); return; }

		if (track.path !== _lastTrackPath) {
			_lastTrackPath = track.path;
			loadForTrack(track);
		}

		let cancelled = false;
		(async () => {
			const { invoke } = await import('@tauri-apps/api/core');
			try {
				const data: unknown = await invoke('get_file_cover_cmd', { path: track.path });
				if (cancelled) return;
				if (data && typeof data === 'string') { coverDataUrl = data; coverLoaded = true; }
			} catch {}
		})();
		return () => { cancelled = true; };
	});

	function handleSeek(ratio: number) { playback.currentTime = ratio * playback.duration; }

	let lyricsContainer: HTMLDivElement | undefined = $state();

	$effect(() => {
		if (!lyricsContainer || lyrics.lines.length === 0) return;
		const _t = playback.currentTime;
		if (lyrics.currentIndex < 0) return;
		const lines = lyricsContainer.querySelectorAll('.lr');
		if (lines && lines[lyrics.currentIndex]) {
			lines[lyrics.currentIndex].scrollIntoView({ behavior: 'smooth', block: 'center' });
		}
	});

	let trackTitle = $derived.by(() => playback.currentTrack?.title ?? '');
	let trackArtist = $derived.by(() => playback.currentTrack?.artist ?? '');
	let trackAlbum = $derived.by(() => playback.currentTrack?.album ?? '');
	let trackFormat = $derived.by(() => {
		const t = playback.currentTrack;
		if (!t) return '';
		const parts: string[] = [];
		if (t.format) parts.push(t.format.toUpperCase());
		if (t.sample_rate) parts.push(`${(t.sample_rate / 1000).toFixed(1)}kHz`);
		if (t.channels) parts.push(t.channels === 1 ? 'Mono' : 'Stereo');
		return parts.join(' · ');
	});

	let bgStyle = $derived.by(() => {
		if (coverDataUrl) return `background-image: url(${coverDataUrl})`;
		return '';
	});

	function onVolumeChange(v: number) { playback.volume = v; }
</script>

<div class="np" transition:fly={{ y: 60, duration: 350, opacity: 0 }}
	role="dialog" aria-label="全屏播放" tabindex="0"
	onkeydown={(e) => e.key === 'Escape' && (ui.showNowPlaying = false)}
	onclick={(e) => { if (e.target === e.currentTarget) ui.showNowPlaying = false; }}>

	<div class="np-bg-cover" style={bgStyle}></div>
	<div class="np-bg-gradient" style="background: radial-gradient(ellipse at 50% 30%, color-mix(in srgb, {settings.accentColor} 15%, transparent), #0a0a14);"></div>

	<button class="np-close" onclick={() => ui.showNowPlaying = false} aria-label="关闭">
		<svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><line x1="18" y1="6" x2="6" y2="18"/><line x1="6" y1="6" x2="18" y2="18"/></svg>
	</button>

	<div class="np-body">
		<div class="np-art">
			<div class="np-art-inner" class:loaded={coverLoaded}>
				<div class="np-art-img" style={coverDataUrl ? `background-image: url(${coverDataUrl})` : 'background: linear-gradient(135deg, #2a2a4e, #1a1a3e)'}></div>
			</div>
			<div class="np-art-glow" style="background: radial-gradient(ellipse, {settings.accentColor} 0%, transparent 70%);"></div>
		</div>

		<div class="np-side">
			{#key playback.currentTrack?.path}
				<div class="np-meta" transition:fade={{ duration: 250 }}>
				<h2 class="np-title">{trackTitle}</h2>
				<p class="np-artist">{trackArtist}</p>
				{#if trackAlbum}
					<p class="np-album">{trackAlbum}</p>
				{/if}
				{#if trackFormat}
					<p class="np-format">{trackFormat}</p>
				{/if}
			</div>
			{/key}

			<div class="np-lyrics" bind:this={lyricsContainer}>
				{#if lyrics.loading}
					<div class="np-status">加载歌词...</div>
				{:else if lyrics.lines.length > 0}
					<div class="np-lyrics-scroll">
						{#each lyrics.lines as line, i}
							<div class="lr" class:active={i === lyrics.currentIndex} class:past={i < lyrics.currentIndex}>
								<span class="lr-text" style={i === lyrics.currentIndex ? `--p: ${lyrics.progress()}` : ''}>{line.text}</span>
							</div>
						{/each}
					</div>
				{:else}
					<div class="np-status">{lyrics.error || '暂无歌词'}</div>
				{/if}
			</div>

			{#if playlist.currentIndex >= 0 && playlist.currentIndex + 1 < playlist.queue.length}
				{@const next = playlist.queue[playlist.currentIndex + 1]}
				<div class="np-next">
					<span class="np-next-label">下一首</span>
					<span class="np-next-title">{next.title || next.path.split(/[/\\]/).pop()}</span>
					<span class="np-next-artist">{next.artist || '未知'}</span>
				</div>
			{/if}

			<div class="np-ctrl">
				<ProgressBar value={playback.currentTime} max={playback.duration} currentTime={playback.currentTime} ondrag={handleSeek} color={settings.accentColor || 'var(--accent)'} />

				<div class="np-btns">
					<button class="np-btn" onclick={() => playback.prev()} disabled={!playback.hasTrack} aria-label="上一首">
						<svg width="16" height="16" viewBox="0 0 24 24" fill="currentColor"><polygon points="19,20 9,12 19,4"/><line x1="5" y1="4" x2="5" y2="20" stroke="currentColor" stroke-width="2"/></svg>
					</button>
					<button class="np-play" onclick={() => playback.togglePlay()} disabled={!playback.hasTrack} aria-label={playback.isPlaying ? '暂停' : '播放'}>
						{#if playback.isPlaying}
							<svg width="20" height="20" viewBox="0 0 24 24" fill="currentColor"><rect x="6" y="4" width="4" height="16" rx="1"/><rect x="14" y="4" width="4" height="16" rx="1"/></svg>
						{:else}
							<svg width="20" height="20" viewBox="0 0 24 24" fill="currentColor"><polygon points="8,5 19,12 8,19"/></svg>
						{/if}
					</button>
					<button class="np-btn" onclick={() => playback.next()} disabled={!playback.hasTrack} aria-label="下一首">
						<svg width="16" height="16" viewBox="0 0 24 24" fill="currentColor"><polygon points="5,4 15,12 5,20"/><line x1="19" y1="4" x2="19" y2="20" stroke="currentColor" stroke-width="2"/></svg>
					</button>
				</div>

				<div class="np-volume">
					<VolumeSlider value={playback.volume} oninput={onVolumeChange} />
				</div>
			</div>
		</div>
	</div>
</div>

<style>
	.np { position: fixed; inset: 0; z-index: 151; display: flex; align-items: center; justify-content: center; background: #0a0a14; overflow: hidden; }

	.np-bg-cover {
		position: absolute; inset: -40px;
		background-size: cover; background-position: center;
		opacity: 0.25; filter: blur(80px) saturate(1.5);
		transition: background-image 0.8s ease;
	}
	.np-bg-gradient { position: absolute; inset: 0; pointer-events: none; }

	.np-close { position: absolute; top: 24px; right: 24px; z-index: 2; width: 36px; height: 36px; border-radius: 50%; border: 0.5px solid rgba(255,255,255,0.06); background: rgba(255,255,255,0.04); backdrop-filter: blur(16px); -webkit-backdrop-filter: blur(16px); color: var(--fg-secondary); cursor: pointer; display: flex; align-items: center; justify-content: center; transition: all 0.15s; }
	.np-close:hover { background: rgba(255,255,255,0.08); color: var(--fg-primary); }

	.np-body { display: flex; align-items: center; gap: 64px; position: relative; z-index: 1; }

	.np-art { position: relative; flex-shrink: 0; }
	.np-art-inner { width: 340px; height: 340px; border-radius: 20px; overflow: hidden; position: relative; box-shadow: 0 20px 60px rgba(0,0,0,0.5); opacity: 0; transform: scale(0.92); transition: all 0.5s cubic-bezier(0.22, 1, 0.36, 1); }
	.np-art-inner.loaded { opacity: 1; transform: scale(1); }
	.np-art-img { width: 100%; height: 100%; background-size: cover; background-position: center; }
	.np-art-glow { position: absolute; inset: -40px; opacity: 0.3; filter: blur(40px); pointer-events: none; }

	.np-side { flex: 1; min-width: 0; max-width: 480px; display: flex; flex-direction: column; gap: 24px; }

	.np-meta { display: flex; flex-direction: column; gap: 2px; }
	.np-title { font-size: 22px; font-weight: 700; color: var(--fg-primary); margin: 0; letter-spacing: -0.3px; }
	.np-artist { font-size: 14px; color: var(--fg-secondary); margin: 0; }
	.np-album { font-size: 13px; color: var(--fg-tertiary); margin: 4px 0 0; }
	.np-format { font-size: 11px; color: var(--fg-quaternary); margin: 6px 0 0; letter-spacing: 0.5px; }

	.np-lyrics { flex: 1; min-height: 100px; max-height: 340px; overflow-y: auto; }
	.np-lyrics::-webkit-scrollbar { width: 3px; }
	.np-lyrics::-webkit-scrollbar-thumb { background: rgba(255,255,255,0.04); border-radius: 2px; }
	.np-lyrics-scroll { display: flex; flex-direction: column; gap: 16px; padding: 12px 0; }
	.np-next { display: flex; align-items: center; gap: 8px; padding: 8px 12px; border-radius: var(--radius-md); background: rgba(255,255,255,0.03); border: 0.5px solid rgba(255,255,255,0.04); }
	.np-next-label { font-size: 10px; color: var(--fg-tertiary); text-transform: uppercase; letter-spacing: 0.5px; }
	.np-next-title { font-size: 12px; color: var(--fg-secondary); font-weight: 500; }
	.np-next-artist { font-size: 11px; color: var(--fg-quaternary); }
	.np-status { color: var(--fg-tertiary); font-size: 14px; text-align: center; padding: 60px 0; }
	.lr { transition: all 0.35s ease; }
	.lr-text { font-size: 16px; font-weight: 400; line-height: 1.7; color: var(--fg-quaternary); transition: all 0.35s ease; }
	.lr.active .lr-text { font-size: 20px; font-weight: 600; background: linear-gradient(to right, var(--fg-primary) 0%, var(--fg-primary) calc(var(--p, 0) * 100%), var(--fg-quaternary) calc(var(--p, 0) * 100%)); -webkit-background-clip: text; -webkit-text-fill-color: transparent; background-clip: text; }
	.lr.past .lr-text { font-size: 13px; color: var(--fg-tertiary); }

	.np-ctrl { display: flex; flex-direction: column; gap: 12px; }
	.np-btns { display: flex; align-items: center; justify-content: center; gap: 20px; }
	.np-btn { width: 40px; height: 40px; border-radius: 50%; border: none; background: transparent; color: var(--fg-secondary); cursor: pointer; display: flex; align-items: center; justify-content: center; transition: all 0.12s; }
	.np-btn:hover:not(:disabled) { background: var(--bg-hover); color: var(--fg-primary); }
	.np-btn:disabled { opacity: 0.15; cursor: default; }
	.np-play { width: 52px; height: 52px; border-radius: 50%; border: none; background: var(--bg-hover); color: var(--fg-primary); cursor: pointer; display: flex; align-items: center; justify-content: center; transition: all 0.12s; }
	.np-play:hover:not(:disabled) { background: var(--bg-active); }
	.np-play:disabled { opacity: 0.15; cursor: default; }

	.np-volume { display: flex; align-items: center; gap: 10px; padding: 0 4px; color: var(--fg-tertiary); }
</style>
