<script lang="ts">
	import { browser } from '$app/environment';
	import { getPlaybackState, type PlayMode } from '$lib/stores/playback.svelte';
	import { getUiState } from '$lib/stores/ui.svelte';
	import { getSettingsState } from '$lib/stores/settings.svelte';
	import { getPlaylistState } from '$lib/stores/playlist.svelte';
	import ProgressBar from '$lib/components/controls/ProgressBar.svelte';
	import VolumeSlider from '$lib/components/controls/VolumeSlider.svelte';
	import type { Track } from '$lib/audio/types';

	const playback = getPlaybackState();
	const ui = getUiState();
	const settings = getSettingsState();
	const playlist = getPlaylistState();

	let coverDataUrl = $state('');
	let _invoke: ((cmd: string, args?: any) => Promise<any>) | null = null;

	// Load settings on mount + sync playMode
	$effect(() => {
		if (!browser) return;
		import('@tauri-apps/api/core').then(async (mod) => {
			_invoke = mod.invoke;
			try {
				const saved: Record<string, any> = await mod.invoke('load_settings');
				if (typeof saved.volume === 'number') playback.volume = saved.volume;
				if (typeof saved.playMode === 'string') {
					playback.playMode = saved.playMode as PlayMode;
					await mod.invoke('set_play_mode', { mode: saved.playMode });
				}
			} catch {}
			mod.invoke('get_play_mode').then((m: any) => { playback.playMode = m as PlayMode; }).catch(() => {});
		});
	});

	async function cyclePlayMode() {
		const next = playback.cyclePlayMode();
		if (_invoke) {
			await settings.save({ volume: playback.volume, playMode: next });
		}
	}

	function onVolumeInput(v: number) {
		playback.volume = v;
		if (_invoke) settings.save({ volume: v, playMode: playback.playMode });
	}

	function handleSeek(ratio: number) { playback.currentTime = ratio * playback.duration; }

	let hasTrack = $derived(playback.hasTrack);
	let trackTitle = $derived.by(() => {
		if (!hasTrack) return '';
		const t = playback.currentTrack;
		return t?.title || t?.path.split(/[/\\]/).pop() || '';
	});
	let trackArtist = $derived.by(() => (playback.currentTrack as Track | null)?.artist ?? '');

	// Cover loading + accent color extraction
	$effect(() => {
		const track = playback.currentTrack;
		const invoke = _invoke;
		if (!track || !invoke) { coverDataUrl = ''; return; }
		let cancelled = false;
		invoke('get_file_cover_cmd', { path: track.path }).then(async (data: any) => {
			if (cancelled) return;
			if (data && typeof data === 'string') {
				coverDataUrl = data;
				const { extractColorFromDataUrl } = await import('$lib/utils/colorExtractor');
				extractColorFromDataUrl(data).then(color => {
					if (!cancelled) {
						settings.accentColor = color;
						settings.save({ volume: playback.volume, playMode: playback.playMode });
					}
				}).catch(() => {});
			} else {
				coverDataUrl = '';
			}
		}).catch(() => { coverDataUrl = ''; });
		return () => { cancelled = true; };
	});

	let coverStyle = $derived.by(() => {
		if (coverDataUrl) return `background-image: url(${coverDataUrl})`;
		return 'background: linear-gradient(135deg, #1a1a24, #2a2438)';
	});
</script>

<div class="bar">
	<div class="bar-body">
		<div class="bar-left">
			<div class="bar-cover" style={coverStyle}>
				{#if playback.isPlaying}<div class="eq-anim"><span></span><span></span><span></span></div>{/if}
			</div>
			<div class="bar-meta">
				<span class="bar-title">{trackTitle}</span>
				<span class="bar-artist">{trackArtist}</span>
			</div>
		</div>

		<div class="bar-center">
			<div class="bar-ctrl">
				<button class="ctrl-btn" onclick={() => playback.prev()} disabled={!hasTrack} aria-label="上一首">
					<svg width="12" height="12" viewBox="0 0 24 24" fill="currentColor"><polygon points="19,20 9,12 19,4"/><line x1="5" y1="4" x2="5" y2="20" stroke="currentColor" stroke-width="2"/></svg>
				</button>
				<button class="ctrl-play" onclick={() => playback.togglePlay()} disabled={!hasTrack} aria-label={playback.isPlaying ? '暂停' : '播放'}>
					{#if playback.isPlaying}
						<svg width="14" height="14" viewBox="0 0 24 24" fill="currentColor"><rect x="6" y="4" width="4" height="16" rx="1"/><rect x="14" y="4" width="4" height="16" rx="1"/></svg>
					{:else}
						<svg width="14" height="14" viewBox="0 0 24 24" fill="currentColor"><polygon points="8,5 19,12 8,19"/></svg>
					{/if}
				</button>
				<button class="ctrl-btn" onclick={() => playback.next()} disabled={!hasTrack} aria-label="下一首">
					<svg width="12" height="12" viewBox="0 0 24 24" fill="currentColor"><polygon points="5,4 15,12 5,20"/><line x1="19" y1="4" x2="19" y2="20" stroke="currentColor" stroke-width="2"/></svg>
				</button>
			</div>
		</div>

		<div class="bar-progress">
			<ProgressBar value={hasTrack ? playback.currentTime : 0} max={hasTrack ? playback.duration : 0} currentTime={hasTrack ? playback.currentTime : 0} ondrag={handleSeek} color={settings.accentColor || 'var(--accent)'} />
		</div>

		<div class="bar-right">
			<VolumeSlider value={playback.volume} oninput={onVolumeInput} />
			<button class="bar-btn" onclick={cyclePlayMode} title="播放模式">
				{#if playback.playMode === 'normal'}
					<svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><polyline points="5,4 15,12 5,20"/></svg>
				{:else if playback.playMode === 'repeat_all'}
					<svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><polyline points="17,1 21,5 17,9"/><path d="M3 11V9a4 4 0 0 1 4-4h14"/><polyline points="7,23 3,19 7,15"/><path d="M21 13v2a4 4 0 0 1-4 4H3"/></svg>
				{:else if playback.playMode === 'repeat_one'}
					<svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><polyline points="17,1 21,5 17,9"/><path d="M3 11V9a4 4 0 0 1 4-4h14"/><polyline points="7,23 3,19 7,15"/><path d="M21 13v2a4 4 0 0 1-4 4H3"/><text x="12" y="15" text-anchor="middle" fill="currentColor" stroke="none" font-size="7">1</text></svg>
				{:else}
					<svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><path d="M16 3h5v5"/><path d="M8 3H3v5"/><path d="M8 21H3v-5"/><path d="M16 21h5v-5"/></svg>
				{/if}
			</button>
			<button class="bar-btn" onclick={() => ui.togglePlaylistPanel()} class:active={ui.showPlaylistPanel} aria-label="播放列表">
				<svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><path d="M21 15V6M18.5 18a2.5 2.5 0 1 0 0-5 2.5 2.5 0 0 0 0 5zM12 12H3M16 6H3M12 18H3"/></svg>
			</button>
			<button class="bar-btn" onclick={() => ui.toggleNowPlaying()} disabled={!hasTrack} aria-label="全屏播放">
				<svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><polyline points="15 3 21 3 21 9"/><polyline points="9 21 3 21 3 15"/><line x1="21" y1="3" x2="14" y2="10"/><line x1="3" y1="21" x2="10" y2="14"/></svg>
			</button>
			<button class="bar-btn" onclick={() => ui.toggleLyrics()} class:active={ui.showLyricsPanel} aria-label="歌词">
				<svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><path d="M12 1a3 3 0 0 0-3 3v8a3 3 0 0 0 6 0V4a3 3 0 0 0-3-3z"/><path d="M19 10v2a7 7 0 0 1-14 0v-2"/></svg>
			</button>
		</div>
	</div>
</div>

<style>
	.bar {
		position: fixed; bottom: 0; left: 0; right: 0; z-index: 50;
		background: rgba(10, 10, 14, 0.72);
		backdrop-filter: blur(40px);
		-webkit-backdrop-filter: blur(40px);
		border-top: 0.5px solid rgba(255, 255, 255, 0.06);
	}

	.bar-body {
		display: flex; align-items: center; gap: var(--space-4);
		padding: var(--space-2) var(--space-6);
		height: 66px;
	}

	/* ── Left ── */
	.bar-left { display: flex; align-items: center; gap: var(--space-3); min-width: 180px; flex: 1; }
	.bar-cover { width: 44px; height: 44px; border-radius: var(--radius-md); flex-shrink: 0; background-size: cover; background-position: center; position: relative; overflow: hidden; transition: background-image 0.4s var(--ease-spring); box-shadow: 0 2px 12px rgba(0,0,0,0.3); }
	.eq-anim { position: absolute; bottom: 4px; left: 50%; transform: translateX(-50%); display: flex; gap: 2.5px; height: 14px; align-items: flex-end; }
	.eq-anim span { width: 2.5px; background: var(--accent); border-radius: 2px 2px 0 0; animation: eq 0.45s ease-in-out infinite alternate; }
	.eq-anim span:nth-child(1) { height: 5px; animation-delay: 0s; animation-duration: 0.3s; }
	.eq-anim span:nth-child(2) { height: 9px; animation-delay: 0.1s; animation-duration: 0.4s; }
	.eq-anim span:nth-child(3) { height: 3px; animation-delay: 0.2s; animation-duration: 0.35s; }
	@keyframes eq { 0% { transform: scaleY(0.3); } 100% { transform: scaleY(1); } }

	.bar-meta { display: flex; flex-direction: column; gap: 2px; min-width: 0; }
	.bar-title { font-size: 13px; font-weight: 500; color: var(--fg-primary); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; max-width: 140px; letter-spacing: 0.01em; }
	.bar-artist { font-size: 11px; color: var(--fg-tertiary); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; max-width: 140px; }

	/* ── Center — inline progress ── */
	.bar-center { display: flex; flex-direction: column; align-items: center; gap: 2px; min-width: 200px; }
	.bar-progress { width: 100%; min-width: 150px; }

	.ctrl-btn {
		width: 30px; height: 30px; border-radius: 50%; border: none;
		background: transparent; color: var(--fg-tertiary);
		cursor: pointer; display: flex; align-items: center; justify-content: center;
		transition: all 0.15s;
	}
	.ctrl-btn:hover:not(:disabled) { background: var(--bg-hover); color: var(--fg-primary); }
	.ctrl-btn:disabled { opacity: 0.15; cursor: default; }

	.ctrl-play {
		width: 36px; height: 36px; border-radius: 50%; border: none;
		background: var(--accent-dim); color: var(--accent);
		cursor: pointer; display: flex; align-items: center; justify-content: center;
		transition: all 0.15s var(--ease-spring);
	}
	.ctrl-play:hover:not(:disabled) { background: var(--accent-dim); filter: brightness(1.15); }
	.ctrl-play:active:not(:disabled) { transform: scale(0.92); }
	.ctrl-play:disabled { opacity: 0.15; cursor: default; }

	/* ── Right ── */
	.bar-right { display: flex; align-items: center; gap: var(--space-1); flex-shrink: 0; }

	.bar-btn {
		width: 30px; height: 30px; border-radius: var(--radius-sm); border: none;
		background: transparent; color: var(--fg-quaternary);
		cursor: pointer; display: flex; align-items: center; justify-content: center;
		transition: all 0.12s;
	}
	.bar-btn:hover { background: var(--bg-hover); color: var(--fg-secondary); }
	.bar-btn:disabled { opacity: 0.15; cursor: default; }
	.bar-btn.active { color: var(--accent); }

	/* ── Bar center ── */
	.bar-ctrl { display: flex; align-items: center; gap: var(--space-2); }
</style>
