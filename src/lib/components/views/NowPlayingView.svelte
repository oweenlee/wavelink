<script lang="ts">
	import { browser } from '$app/environment';
	import { fly } from 'svelte/transition';
	import { cubicOut } from 'svelte/easing';
	import { getPlaybackState } from '$lib/stores/playback.svelte';
	import { getUiState } from '$lib/stores/ui.svelte';
	import { getPlaylistState } from '$lib/stores/playlist.svelte';
	import { getLyricsState, loadForTrack } from '$lib/stores/lyrics.svelte';
	import VolumeSlider from '$lib/components/controls/VolumeSlider.svelte';
	import ProgressBar from '$lib/components/controls/ProgressBar.svelte';
	import SpectrumAnalyzer from '$lib/components/controls/SpectrumAnalyzer.svelte';
	import { X, Disc3, Shuffle, Repeat1, Repeat, List, SkipBack, SkipForward, Play, Pause, ChevronDown } from 'lucide-svelte';
	const playback = getPlaybackState();
	const ui = getUiState();
	const playlist = getPlaylistState();
	const lyrics = getLyricsState();

	let coverDataUrl = $state('');
	let coverCancelled = $state(false);
	let showInfo = $state(false);
	let showQueue = $state(false);
	let lyricsScrollEl: HTMLDivElement | undefined = $state();

	// ── Derived ──
	let trackFormat = $derived.by(() => {
		const t = playback.currentTrack;
		if (!t) return '';
		const parts: string[] = [];
		if (t.format) parts.push(t.format.toUpperCase());
		if (t.sample_rate) parts.push((t.sample_rate / 1000).toFixed(1) + 'kHz');
		if (t.channels) parts.push(t.channels === 1 ? 'Mono' : 'Stereo');
		return parts.join(' · ');
	});

	let fileSize = $derived.by(() => {
		const s = playback.currentTrack?.file_size;
		if (!s) return '';
		if (s < 1024) return s + ' B';
		if (s < 1024 * 1024) return (s / 1024).toFixed(1) + ' KB';
		return (s / (1024 * 1024)).toFixed(1) + ' MB';
	});

	let upcomingTracks = $derived.by(() => {
		const t = playback.currentTrack;
		const q = playlist.queue;
		if (!t || q.length <= 1) return [];
		const idx = q.findIndex((tr) => tr.id === t.id);
		if (idx < 0 || idx >= q.length - 1) return [];
		return q.slice(idx + 1);
	});

	let currentQueueIndex = $derived.by(() => {
		const t = playback.currentTrack;
		if (!t) return -1;
		return playlist.queue.findIndex(tr => tr.id === t.id);
	});

	let nextTrack = $derived.by(() => {
		const t = playback.currentTrack;
		const q = playlist.queue;
		if (!t || q.length <= 1) return null;
		const idx = q.findIndex((tr) => tr.id === t.id);
		if (idx < 0 || idx >= q.length - 1) return null;
		return q[idx + 1];
	});

	// ── Cover loading ──
	$effect(() => {
		const track = playback.currentTrack;
		coverDataUrl = '';
		coverCancelled = false;
		loadForTrack(track);
		if (!track || !browser) return;

		let cancelled = false;
		(async () => {
			const { invoke } = await import('@tauri-apps/api/core');
			try {
				const data: unknown = await invoke('get_file_cover_cmd', { path: track.path });
				if (cancelled) return;
				if (data && typeof data === 'string') coverDataUrl = data;
			} catch { console.warn('[NowPlayingView] 封面加载失败'); /* 无封面正常 */ }
		})();

		return () => { cancelled = true; };
	});

	// ── Lyrics scroll ──
	$effect(() => {
		if (!ui.showNowPlaying || !lyricsScrollEl || lyrics.lines.length === 0) return;
		if (lyrics.currentIndex < 0) return;
		const lines = lyricsScrollEl.querySelectorAll('.lyric-line');
		if (lines[lyrics.currentIndex]) {
			lines[lyrics.currentIndex].scrollIntoView({ behavior: 'smooth', block: 'center' });
		}
	});

	// ── Handlers ──
	function close() { ui.showNowPlaying = false; }

	function handleKeydown(e: KeyboardEvent) {
		if (e.key === 'Escape') close();
	}

	async function playQueueItem(index: number) {
		await playback.playFromQueue(index);
		showQueue = false;
	}
</script>

<!-- svelte-ignore a11y_no_static_element_interactions -->
<div class="np" onkeydown={handleKeydown} onclick={(e) => { if (e.target === e.currentTarget) close(); }}>
	<!-- Close button -->
	<button class="np-close" onclick={close} aria-label="关闭">
		<X size={16} stroke-width={2.5} />
	</button>

	<div class="np-body">
		<!-- Left: cover art + spectrum -->
		<div class="np-side">
			<div class="np-art-wrap">
				<div class="np-art" style={coverDataUrl ? `background-image: url(${coverDataUrl})` : ''}>
					{#if !coverDataUrl}
						<Disc3 class="np-no-cover" size={80} />
					{/if}
				</div>
				<div class="np-art-glow" style={coverDataUrl ? `background-image: url(${coverDataUrl})` : ''}></div>
			</div>
			<div class="np-spectrum-wrap">
				<SpectrumAnalyzer />
			</div>
		</div>

		<!-- Right: content -->
		<div class="np-main">
			<!-- Track info -->
			{#key playback.currentTrack?.id}
				<div class="np-meta">
					<h1 class="np-title">{playback.currentTrack?.title || '未选择曲目'}</h1>
					<p class="np-artist">{playback.currentTrack?.artist || '未知艺术家'}</p>
					{#if trackFormat}<p class="np-format">{trackFormat}</p>{/if}
				</div>
			{/key}

			<!-- Lyrics -->
			<div class="np-lyrics" bind:this={lyricsScrollEl}>
				{#if lyrics.loading}
					<p class="np-lyrics-status">加载歌词中...</p>
				{:else if lyrics.lines.length > 0}
					<div class="np-lyrics-scroll">
						{#each lyrics.lines as line, i}
							<div class="lyric-line" class:active={i === lyrics.currentIndex} class:past={i < lyrics.currentIndex}>
								<span class="lyric-text" style={i === lyrics.currentIndex ? `--progress: ${lyrics.progress()}` : ''}>{line.text}</span>
							</div>
						{/each}
					</div>
				{:else}
					<p class="np-lyrics-status">{lyrics.error || '暂无歌词'}</p>
				{/if}
			</div>

			<!-- Controls -->
			<div class="np-ctrl">
				<ProgressBar
					value={playback.currentTime}
					currentTime={playback.currentTime}
					max={playback.duration}
					ondrag={(ratio: number) => { playback.currentTime = ratio * playback.duration; }}
				/>

				<div class="np-btns">
			<button class="np-btn" onclick={() => playback.cyclePlayMode()} class:on={playback.playMode !== 'normal'} aria-label="播放模式" title={playback.playMode === 'shuffle' ? '随机播放' : playback.playMode === 'repeat_one' ? '单曲循环' : playback.playMode === 'repeat_all' ? '列表循环' : '顺序播放'}>
				{#if playback.playMode === 'shuffle'}
					<Shuffle size={18} />
				{:else if playback.playMode === 'repeat_one'}
					<Repeat1 size={18} />
				{:else if playback.playMode === 'repeat_all'}
					<Repeat size={18} />
				{:else}
					<List size={18} />
				{/if}
			</button>
				<button class="np-btn" onclick={() => playback.previous()} aria-label="上一首">
					<SkipBack size={22} fill="currentColor" />
				</button>
				<button class="np-btn np-btn-play" onclick={() => playback.togglePlay()} aria-label={playback.isPlaying ? '暂停' : '播放'}>
					<div class="icon-wrap">
						<div class="icon-layer" class:show={playback.isPlaying}><Pause size={28} fill="currentColor" /></div>
						<div class="icon-layer" class:show={!playback.isPlaying}><Play size={28} fill="currentColor" /></div>
					</div>
				</button>
				<button class="np-btn" onclick={() => playback.next()} aria-label="下一首">
					<SkipForward size={22} fill="currentColor" />
				</button>
			</div>

				<div class="np-vol-wrap">
					<VolumeSlider value={playback.volume} oninput={(v: number) => { playback.volume = v; }} />
				</div>
			</div>

			<!-- Info toggle / panel -->
			<div class="np-info-section">
				<button class="np-info-toggle" onclick={() => showInfo = !showInfo} aria-expanded={showInfo}>
					<span>{showInfo ? '收起详情' : '详细信息'}</span>
					<ChevronDown size={12} class={showInfo ? 'rotated' : ''} />
				</button>

				{#if showInfo}
				<div class="np-info-panel" transition:fly={{ y: -8, duration: 200 }}>
					<div class="np-info-grid">
						{#if playback.currentTrack?.format}
							<div class="np-info-item"><span class="np-info-k">格式</span><span class="np-info-v">{playback.currentTrack!.format!.toUpperCase()}</span></div>
						{/if}
						{#if playback.currentTrack?.sample_rate}
							<div class="np-info-item"><span class="np-info-k">采样率</span><span class="np-info-v">{(playback.currentTrack!.sample_rate! / 1000).toFixed(1)} kHz</span></div>
						{/if}
						{#if playback.currentTrack?.channels}
							<div class="np-info-item"><span class="np-info-k">声道</span><span class="np-info-v">{playback.currentTrack!.channels === 1 ? 'Mono' : 'Stereo'}</span></div>
						{/if}
						{#if playback.currentTrack?.bitrate}
							<div class="np-info-item"><span class="np-info-k">比特率</span><span class="np-info-v">{playback.currentTrack!.bitrate} kbps</span></div>
						{/if}
						{#if fileSize}
							<div class="np-info-item"><span class="np-info-k">文件大小</span><span class="np-info-v">{fileSize}</span></div>
						{/if}
						{#if playback.currentTrack?.year}
							<div class="np-info-item"><span class="np-info-k">年份</span><span class="np-info-v">{playback.currentTrack!.year}</span></div>
						{/if}
						{#if playback.currentTrack?.genre}
							<div class="np-info-item"><span class="np-info-k">流派</span><span class="np-info-v">{playback.currentTrack!.genre}</span></div>
						{/if}
						{#if playback.currentTrack?.track_number}
							<div class="np-info-item"><span class="np-info-k">音轨号</span><span class="np-info-v">{playback.currentTrack!.track_number}</span></div>
						{/if}
						{#if playback.currentTrack?.album_artist}
							<div class="np-info-item"><span class="np-info-k">专辑艺术家</span><span class="np-info-v">{playback.currentTrack!.album_artist}</span></div>
						{/if}
					</div>
					</div>
				{/if}
			</div>
		</div>
	</div>

	<!-- Next up — bottom-left -->
	{#if nextTrack}
		<div class="np-nextup">
			<span class="np-nextup-label">下一首</span>
			<span class="np-nextup-title">{nextTrack.title || nextTrack.path.split(/[/\\]/).pop()}</span>
		</div>
	{/if}

	<!-- Queue button — bottom-right -->
	<button class="np-queue-btn" onclick={() => showQueue = !showQueue} aria-label="播放列表">
		<List size={18} />
	</button>

	<!-- Queue panel — slides in from right -->
	{#if showQueue && upcomingTracks.length > 0}
		<div class="np-queue-overlay" onclick={() => showQueue = false}></div>
		<div class="np-queue-panel" transition:fly={{ x: 420, duration: 250, easing: cubicOut }}>
			<div class="np-queue-header">
				<span>播放列表 ({upcomingTracks.length})</span>
				<button class="np-queue-close" onclick={() => showQueue = false}><X size={14} /></button>
			</div>
			<div class="np-queue-scroll">
				{#each upcomingTracks as track, i}
					<button class="np-queue-item" onclick={() => playQueueItem(currentQueueIndex + 1 + i)}>
						<span class="np-queue-idx">{i + 1}</span>
						<div class="np-queue-meta">
							<span class="np-queue-title">{track.title || track.path.split(/[/\\]/).pop()}</span>
							<span class="np-queue-artist">{track.artist || '未知艺术家'}</span>
						</div>
					</button>
				{/each}
			</div>
		</div>
	{/if}
</div>

<style>
	/* ── Root ── */
	.np {
		position: fixed; inset: 0; z-index: 999;
		background: rgba(8, 8, 16, 0.97);
		backdrop-filter: blur(24px); -webkit-backdrop-filter: blur(24px);
		display: flex; align-items: center; justify-content: center;
		animation: npFadeIn 0.25s ease-out;
	}
	@keyframes npFadeIn { from { opacity: 0; } to { opacity: 1; } }

	/* ── Close ── */
	.np-close {
		position: absolute; top: 24px; right: 24px; z-index: 10;
		width: 36px; height: 36px; border-radius: 50%;
		border: 0.5px solid rgba(255,255,255,0.08);
		background: rgba(255,255,255,0.04); backdrop-filter: blur(16px);
		-webkit-backdrop-filter: blur(16px);
		color: var(--fg-secondary); cursor: pointer;
		display: flex; align-items: center; justify-content: center;
		transition: all 0.15s;
	}
	.np-close:hover { background: rgba(255,255,255,0.1); color: var(--fg-primary); transform: scale(1.08); }
	.np-close:active { transform: scale(0.94); }

	/* ── Body ── */
	.np-body {
		display: flex; gap: 48px; align-items: center;
		max-width: 960px; width: 100%; padding: 0 24px;
	}

	/* ── Cover art ── */
	.np-side { flex-shrink: 0; display: flex; flex-direction: column; align-items: center; gap: 16px; }
	.np-spectrum-wrap { width: 100%; opacity: 0.85; }
	.np-art-wrap { position: relative; }
	.np-art {
		width: 320px; height: 320px; border-radius: 16px;
		background: linear-gradient(135deg, #1a1a24, #2a2438);
		background-size: cover; background-position: center;
		box-shadow: 0 16px 48px rgba(0,0,0,0.4);
		display: flex; align-items: center; justify-content: center;
		animation: npCoverIn 0.5s cubic-bezier(0.22, 1, 0.36, 1);
	}
	@keyframes npCoverIn { from { opacity: 0; transform: scale(0.92); } to { opacity: 1; transform: scale(1); } }
	.np-no-cover { width: 80px; height: 80px; color: rgba(255,255,255,0.08); }
	.np-art-glow {
		position: absolute; inset: -24px; border-radius: 32px;
		background-size: cover; background-position: center;
		filter: blur(40px); opacity: 0.15; z-index: -1;
		pointer-events: none;
	}

	/* ── Main content ── */
	.np-main { flex: 1; min-width: 0; display: flex; flex-direction: column; gap: 16px; max-height: 80vh; }

	/* ── Track meta ── */
	.np-meta { animation: npMetaIn 0.3s ease-out; }
	@keyframes npMetaIn { from { opacity: 0; transform: translateY(6px); } to { opacity: 1; transform: translateY(0); } }
	.np-title { font-size: 22px; font-weight: 600; color: var(--fg-primary); margin: 0; line-height: 1.3; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
	.np-artist { font-size: 14px; color: var(--fg-secondary); margin: 4px 0 0; }
	.np-format { font-size: 11px; color: var(--fg-tertiary); margin: 2px 0 0; font-variant-numeric: tabular-nums; }

	/* ── Lyrics ── */
	.np-lyrics { flex: 1; overflow-y: auto; min-height: 0; }
	.np-lyrics::-webkit-scrollbar { width: 3px; }
	.np-lyrics::-webkit-scrollbar-thumb { background: var(--bg-active); border-radius: 2px; }
	.np-lyrics-scroll { display: flex; flex-direction: column; gap: 12px; padding: 8px 0; }
	.np-lyrics-status { color: var(--fg-tertiary); font-size: 13px; text-align: center; padding: 40px 0; }

	.lyric-line { text-align: left; transition: all 0.35s ease; }
	.lyric-text { font-size: 14px; font-weight: 400; color: var(--fg-tertiary); line-height: 1.7; transition: all 0.35s ease; }
	.lyric-line.active .lyric-text { font-size: 18px; font-weight: 600; color: var(--fg-primary); }
	.lyric-line.past .lyric-text { color: var(--fg-quaternary); font-size: 12px; }

	/* ── Next up ── */
	.np-nextup {
		position: absolute; bottom: 20px; left: 24px;
		display: flex; align-items: baseline; gap: 6px;
		opacity: 0.35; transition: opacity 0.2s;
	}
	.np-nextup:hover { opacity: 0.6; }
	.np-nextup-label { font-size: 10px; color: var(--fg-tertiary); letter-spacing: 0.3px; }
	.np-nextup-title { font-size: 11px; color: var(--fg-tertiary); overflow: hidden; text-overflow: ellipsis; white-space: nowrap; max-width: 200px; }

	/* ── Queue button — bottom-right ── */
	.np-queue-btn {
		position: absolute; bottom: 20px; right: 24px; z-index: 10;
		width: 36px; height: 36px; border-radius: 50%;
		border: 0.5px solid rgba(255,255,255,0.08);
		background: rgba(255,255,255,0.04); backdrop-filter: blur(16px);
		-webkit-backdrop-filter: blur(16px);
		color: var(--fg-secondary); cursor: pointer;
		display: flex; align-items: center; justify-content: center;
		transition: all 0.15s;
	}
	.np-queue-btn:hover { background: rgba(255,255,255,0.1); color: var(--fg-primary); transform: scale(1.08); }
	.np-queue-btn:active { transform: scale(0.94); }

	/* ── Queue panel — slide from right ── */
	.np-queue-overlay {
		position: absolute; inset: 0; z-index: 19;
		background: rgba(0,0,0,0.3);
	}
	.np-queue-panel {
		position: absolute; top: 0; right: 0; bottom: 0; z-index: 20;
		width: 320px;
		background: rgba(12, 12, 22, 0.96);
		backdrop-filter: blur(20px); -webkit-backdrop-filter: blur(20px);
		border-left: 0.5px solid rgba(255,255,255,0.06);
		display: flex; flex-direction: column;
	}
	.np-queue-header {
		display: flex; align-items: center; justify-content: space-between;
		padding: 16px 16px 12px;
		font-size: 13px; font-weight: 500; color: var(--fg-primary);
	}
	.np-queue-close {
		width: 28px; height: 28px; border-radius: 50%;
		border: none; background: transparent;
		color: var(--fg-secondary); cursor: pointer;
		display: flex; align-items: center; justify-content: center;
		transition: all 0.12s;
	}
	.np-queue-close:hover { background: rgba(255,255,255,0.08); color: var(--fg-primary); }
	.np-queue-scroll {
		flex: 1; overflow-y: auto; padding: 0 8px 12px;
	}
	.np-queue-scroll::-webkit-scrollbar { width: 3px; }
	.np-queue-scroll::-webkit-scrollbar-thumb { background: var(--bg-active); border-radius: 2px; }
	.np-queue-item {
		display: flex; align-items: center; gap: 8px;
		width: 100%; padding: 8px;
		border: none; border-radius: 6px;
		background: transparent; color: var(--fg-secondary);
		cursor: pointer; text-align: left;
		transition: all 0.12s;
	}
	.np-queue-item:hover { background: rgba(255,255,255,0.06); color: var(--fg-primary); }
	.np-queue-item:active { transform: scale(0.98); }
	.np-queue-idx {
		flex-shrink: 0; width: 20px; height: 20px;
		display: flex; align-items: center; justify-content: center;
		border-radius: 4px;
		background: rgba(255,255,255,0.06);
		font-size: 10px; color: var(--fg-tertiary);
		font-variant-numeric: tabular-nums;
	}
	.np-queue-meta { flex: 1; min-width: 0; }
	.np-queue-title { font-size: 12px; display: block; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
	.np-queue-artist { font-size: 10px; color: var(--fg-tertiary); display: block; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }

	/* ── Controls ── */
	.np-ctrl { display: flex; flex-direction: column; gap: 10px; }
	.np-btns { display: flex; align-items: center; justify-content: center; gap: 16px; }
	.np-btn {
		width: 36px; height: 36px; border-radius: 50%;
		border: none; background: transparent;
		color: var(--fg-secondary); cursor: pointer;
		display: flex; align-items: center; justify-content: center;
		transition: all 0.12s; position: relative;
	}
	.np-btn:hover { color: var(--fg-primary); }
	.np-btn:active { transform: scale(0.9); }
	.np-btn.on { color: var(--accent); }
	.np-btn-play {
		width: 52px; height: 52px;
		background: var(--accent); color: #fff; border-radius: 50%;
		box-shadow: 0 4px 20px rgba(var(--accent-rgb, 99, 102, 241), 0.3);
	}
	.np-btn-play:hover { transform: scale(1.06); color: #fff; }
	.np-btn-play:active { transform: scale(0.95); }
	.np-btn-play .icon-wrap { position: relative; width: 28px; height: 28px; }
	.np-btn-play .icon-layer { position: absolute; inset: 0; display: flex; align-items: center; justify-content: center; opacity: 0; transition: opacity 0.15s; }
	.np-btn-play .icon-layer.show { opacity: 1; }
	.np-vol-wrap { display: flex; justify-content: center; }

	/* ── Info panel ── */
	.np-info-section { flex-shrink: 0; }
	.np-info-toggle {
		display: inline-flex; align-items: center; gap: 6px;
		padding: 6px 0; border: none; background: transparent;
		color: var(--fg-tertiary); cursor: pointer; font-size: 12px;
		transition: color 0.15s;
	}
	.np-info-toggle:hover { color: var(--fg-secondary); }
	.np-info-toggle svg { transition: transform 0.2s; }
	.np-info-toggle svg.rotated { transform: rotate(180deg); }

	.np-info-panel {
		margin-top: 8px; padding: 12px 14px;
		border-radius: 10px;
		background: rgba(255,255,255,0.03); border: 0.5px solid rgba(255,255,255,0.05);
	}
	.np-info-grid { display: grid; grid-template-columns: repeat(3, 1fr); gap: 8px 16px; }
	.np-info-item { display: flex; flex-direction: column; gap: 2px; }
	.np-info-k { font-size: 10px; color: var(--fg-tertiary); text-transform: uppercase; letter-spacing: 0.3px; }
	.np-info-v { font-size: 12px; color: var(--fg-secondary); font-variant-numeric: tabular-nums; }

	/* ── Responsive ── */
	@media (max-width: 720px) {
		.np-body { flex-direction: column; gap: 24px; max-width: 100%; }
		.np-art { width: 200px; height: 200px; }
		.np-main { max-height: none; }
	}
</style>
