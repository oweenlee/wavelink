<script lang="ts">
	import { browser } from '$app/environment';
	import { fly } from 'svelte/transition';
	import { cubicOut } from 'svelte/easing';
	import { getPlaybackState } from '$lib/stores/playback.svelte';
	import { getUiState } from '$lib/stores/ui.svelte';
	import { getPlaylistState } from '$lib/stores/playlist.svelte';
	import { getLyricsState, loadForTrack } from '$lib/stores/lyrics.svelte';
	import { getSettingsState } from '$lib/stores/settings.svelte';
	import VolumeSlider from '$lib/components/controls/VolumeSlider.svelte';
	import ProgressBar from '$lib/components/controls/ProgressBar.svelte';
	import SpectrumAnalyzer from '$lib/components/controls/SpectrumAnalyzer.svelte';
	import WaveformVisualizer from '$lib/components/controls/WaveformVisualizer.svelte';
	import { extractColorFromDataUrl } from '$lib/utils/colorExtractor';
	import type { AnalysisResult } from '$lib/audio/types';

	import { t } from '$lib/i18n/i18n.svelte';
	import { X, Disc3, Shuffle, Repeat1, Repeat, List, SkipBack, SkipForward, Play, Pause, ChevronDown, Waves } from 'lucide-svelte';
	const playback = getPlaybackState();
	const ui = getUiState();
	const playlist = getPlaylistState();
	const lyrics = getLyricsState();
	const settings = getSettingsState();

	let coverDataUrl = $state('');
	let coverColor = $state('');
	let coverCancelled = $state(false);
	let showInfo = $state(false);
	let showQueue = $state(false);
	let showWaveform = $state(false);
	let lyricsScrollEl: HTMLDivElement | undefined = $state();

	// 音频分析（BPM/调性/能量），随当前曲目变化查询
	let analysis = $state<AnalysisResult | null>(null);
	let analyzing = $state(false);

	$effect(() => {
		const id = playback.currentTrack?.id;
		if (!id) { analysis = null; analyzing = false; return; }
		analysis = null;
		let cancelled = false;
		(async () => {
			try {
				const { invoke } = await import('@tauri-apps/api/core');
				const res = (await invoke('get_track_analyses', { trackIds: [id] })) as Record<number, AnalysisResult>;
				if (!cancelled) analysis = res[id] ?? null;
			} catch { if (!cancelled) analysis = null; }
		})();
		return () => { cancelled = true; };
	});

	async function analyzeCurrent() {
		const tr = playback.currentTrack;
		if (!tr?.path || analyzing) return;
		analyzing = true;
		try {
			const { invoke } = await import('@tauri-apps/api/core');
			analysis = (await invoke('analyze_track', { path: tr.path })) as AnalysisResult;
		} catch { analysis = null; }
		analyzing = false;
	}

	// ── Derived ──
	let fileSize = $derived.by(() => {
		const s = playback.currentTrack?.file_size;
		if (!s) return '';
		if (s < 1024) return s + ' B';
		if (s < 1024 * 1024) return (s / 1024).toFixed(1) + ' KB';
		return (s / (1024 * 1024)).toFixed(1) + ' MB';
	});

	// 由 file_size 与 duration 估算码率（kbps），Track 本身不带 bitrate 字段
	let bitrate = $derived.by(() => {
		const tr = playback.currentTrack;
		if (!tr?.file_size || !tr.duration) return 0;
		return Math.round((tr.file_size * 8) / tr.duration / 1000);
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

	// ── 封面主色提取 → 驱动氛围光晕（无封面时回落默认琥珀色）──
	$effect(() => {
		const url = coverDataUrl;
		if (!url || !browser) { coverColor = ''; return; }
		let cancelled = false;
		extractColorFromDataUrl(url)
			.then((hex) => { if (!cancelled) coverColor = hex; })
			.catch(() => { /* 提取失败用默认色 */ });
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
<div class="np" class:np-playing={playback.isPlaying} style={`--np-glow: ${coverColor || '#e8553f'};${coverDataUrl ? ` --cover: url(${coverDataUrl})` : ''}`} onkeydown={handleKeydown} onclick={(e) => { if (e.target === e.currentTarget) close(); }}>
	<!-- Close button -->
	<button class="np-close" onclick={close} aria-label={t('nowplaying.close')}>
		<X size={16} stroke-width={2.5} />
	</button>

	<div class="np-body">
		<!-- Left: cover art + spectrum -->
		<div class="np-side">
			<div class="np-art-wrap">
				<div class="np-vinyl">
					<div class="np-vinyl-grooves"></div>
					<div class="np-art" class:spinning={playback.isPlaying} style={coverDataUrl ? `background-image: var(--cover)` : ''}>
						{#if !coverDataUrl}
							<Disc3 class="np-no-cover" size={80} />
						{/if}
					</div>
					<div class="np-vinyl-label"></div>
				</div>
			</div>
			<div class="np-spectrum-wrap">
				{#if showWaveform}
					<WaveformVisualizer width={320} height={56} />
				{:else}
					<SpectrumAnalyzer width={320} height={56} />
				{/if}
				<button class="np-viz-toggle" onclick={() => showWaveform = !showWaveform} aria-label="Toggle visualization">
					<Waves size={12} />
				</button>
			</div>
		</div>

		<!-- Right: content -->
		<div class="np-main">
			<!-- Track info -->
			{#key playback.currentTrack?.id}
				<div class="np-meta">
					<h1 class="np-title">{playback.currentTrack?.title || t('nowplaying.no_track')}</h1>
					<p class="np-artist">{playback.currentTrack?.artist || t('nowplaying.unknown_artist')}</p>
				</div>

				<!-- HiFi 规格读数条：硬件仪表面板风格，等宽字体 + 琥珀色 -->
				<div class="np-spec">
					<div class="spec-item">
						<span class="spec-v">{(playback.currentTrack?.format || '—').toUpperCase()}</span>
						<span class="spec-k">{t('nowplaying.format')}</span>
					</div>
					<div class="spec-sep"></div>
					<div class="spec-item">
						<span class="spec-v">{playback.currentTrack?.sample_rate ? `${(playback.currentTrack.sample_rate / 1000).toFixed(1)} kHz` : '—'}</span>
						<span class="spec-k">{t('nowplaying.sample_rate')}</span>
					</div>
					<div class="spec-sep"></div>
					<div class="spec-item">
						<span class="spec-v">{playback.currentTrack?.channels ? (playback.currentTrack.channels === 1 ? 'Mono' : 'Stereo') : '—'}</span>
						<span class="spec-k">{t('nowplaying.channels')}</span>
					</div>
					<div class="spec-sep"></div>
					<div class="spec-item">
						<span class="spec-v">{bitrate ? `${bitrate} kbps` : '—'}</span>
						<span class="spec-k">{t('nowplaying.bitrate')}</span>
					</div>
					{#if analysis?.bpm}
						<div class="spec-sep"></div>
						<div class="spec-item">
							<span class="spec-v">{analysis.bpm.toFixed(1)}</span>
							<span class="spec-k">BPM</span>
						</div>
					{/if}
					{#if analysis?.key}
						<div class="spec-sep"></div>
						<div class="spec-item">
							<span class="spec-v">{analysis.key}</span>
							<span class="spec-k">{t('nowplaying.key')}</span>
						</div>
					{/if}
					{#if analysis?.energy != null}
						<div class="spec-sep"></div>
						<div class="spec-item">
							<span class="spec-v">{(analysis.energy * 100).toFixed(0)}</span>
							<span class="spec-k">{t('nowplaying.energy')}</span>
						</div>
					{/if}
					<div class="spec-lamp" class:on={settings.bitPerfect}>
						<span class="lamp-dot"></span>
						<span class="lamp-text">BIT-PERFECT</span>
					</div>
				</div>
			{/key}

			<!-- Lyrics -->
			<div class="np-lyrics" bind:this={lyricsScrollEl}>
				{#if lyrics.loading}
					<p class="np-lyrics-status">{t('nowplaying.loading_lyrics')}</p>
				{:else if lyrics.lines.length > 0}
					<div class="np-lyrics-scroll">
						{#each lyrics.lines as line, i (i)}
							<div class="lyric-line" class:active={i === lyrics.currentIndex} class:past={i < lyrics.currentIndex}>
								<span class="lyric-text" style={i === lyrics.currentIndex ? `--progress: ${lyrics.progress()}` : ''}>{line.text}</span>
							</div>
						{/each}
					</div>
				{:else}
					<p class="np-lyrics-status">{lyrics.error || t('nowplaying.no_lyrics')}</p>
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
			<button class="np-btn" onclick={() => playback.cyclePlayMode()} class:on={playback.playMode !== 'normal'} aria-label={t('nowplaying.play_mode')} title={playback.playMode === 'shuffle' ? t('nowplaying.shuffle') : playback.playMode === 'repeat_one' ? t('nowplaying.repeat_one') : playback.playMode === 'repeat_all' ? t('nowplaying.repeat_all') : t('nowplaying.sequential')}>
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
				<button class="np-btn" onclick={() => playback.prev()} aria-label={t('nowplaying.prev')}>
					<SkipBack size={22} fill="currentColor" />
				</button>
				<button class="np-btn np-btn-play" onclick={() => playback.togglePlay()} aria-label={playback.isPlaying ? t('nowplaying.pause') : t('nowplaying.play')}>
					<div class="icon-wrap">
						<div class="icon-layer" class:show={playback.isPlaying}><Pause size={28} fill="currentColor" /></div>
						<div class="icon-layer" class:show={!playback.isPlaying}><Play size={28} fill="currentColor" /></div>
					</div>
				</button>
				<button class="np-btn" onclick={() => playback.next()} aria-label={t('nowplaying.next')}>
					<SkipForward size={22} fill="currentColor" />
				</button>
			</div>

				<div class="np-vol-wrap">
					<VolumeSlider value={playback.volume} oninput={(v: number) => { playback.volume = v; }} />
				</div>
			</div>

			<!-- Info toggle / panel -->
			<div class="np-info-section">
				{#if playback.currentTrack?.id && !analysis}
					<button class="np-info-toggle np-analyze" onclick={analyzeCurrent} disabled={analyzing}>
						<span>{analyzing ? t('nowplaying.analyzing') : t('nowplaying.analyze')}</span>
					</button>
				{/if}
				<button class="np-info-toggle" onclick={() => showInfo = !showInfo} aria-expanded={showInfo}>
					<span>{showInfo ? t('nowplaying.collapse_info') : t('nowplaying.expand_info')}</span>
					<ChevronDown size={12} class={showInfo ? 'rotated' : ''} />
				</button>

				{#if showInfo}
				<div class="np-info-panel" transition:fly={{ y: -8, duration: 200 }}>
					<div class="np-info-grid">
						<!-- 格式/采样率/声道/码率已移至常驻规格读数条，此处仅留文件元数据 -->
						{#if fileSize}
							<div class="np-info-item"><span class="np-info-k">{t('nowplaying.file_size')}</span><span class="np-info-v">{fileSize}</span></div>
						{/if}
						{#if playback.currentTrack?.year}
							<div class="np-info-item"><span class="np-info-k">{t('nowplaying.year')}</span><span class="np-info-v">{playback.currentTrack!.year}</span></div>
						{/if}
						{#if playback.currentTrack?.genre}
							<div class="np-info-item"><span class="np-info-k">{t('nowplaying.genre')}</span><span class="np-info-v">{playback.currentTrack!.genre}</span></div>
						{/if}
						{#if playback.currentTrack?.track_number}
							<div class="np-info-item"><span class="np-info-k">{t('nowplaying.track_number')}</span><span class="np-info-v">{playback.currentTrack!.track_number}</span></div>
						{/if}
						{#if playback.currentTrack?.album_artist}
							<div class="np-info-item"><span class="np-info-k">{t('nowplaying.album_artist')}</span><span class="np-info-v">{playback.currentTrack!.album_artist}</span></div>
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
			<span class="np-nextup-label">{t('nowplaying.next_up')}</span>
			<span class="np-nextup-title">{nextTrack.title || nextTrack.path.split(/[/\\]/).pop()}</span>
		</div>
	{/if}

	<!-- Queue button — bottom-right -->
	<button class="np-queue-btn" onclick={() => showQueue = !showQueue} aria-label={t('nowplaying.playlist')}>
		<List size={18} />
	</button>

	<!-- Queue panel — slides in from right -->
	{#if showQueue && upcomingTracks.length > 0}
		<div class="np-queue-overlay" role="button" tabindex="0" onclick={() => showQueue = false} onkeydown={(e) => e.key === 'Escape' && (showQueue = false)}></div>
		<div class="np-queue-panel" transition:fly={{ x: 420, duration: 250, easing: cubicOut }}>
			<div class="np-queue-header">
				<span>{t('nowplaying.playlist')} ({upcomingTracks.length})</span>
				<button class="np-queue-close" onclick={() => showQueue = false}><X size={14} /></button>
			</div>
			<div class="np-queue-scroll">
				{#each upcomingTracks as track, i (track.id)}
					<button class="np-queue-item" onclick={() => playQueueItem(currentQueueIndex + 1 + i)}>
						<span class="np-queue-idx">{i + 1}</span>
						<div class="np-queue-meta">
							<span class="np-queue-title">{track.title || track.path.split(/[/\\]/).pop()}</span>
							<span class="np-queue-artist">{track.artist || t('nowplaying.unknown_artist')}</span>
						</div>
					</button>
				{/each}
			</div>
		</div>
	{/if}
</div>

<style>
	/* ── Root ── */
	/* 封面主色氛围光：注册为 <color> 使其可平滑过渡（切歌时光晕随之变色） */
	@property --np-glow {
		syntax: '<color>';
		inherits: true;
		initial-value: #e8553f;
	}

	.np {
		position: fixed; inset: 0; z-index: 999;
		overflow: hidden;
		background: #080808;
		display: flex; align-items: center; justify-content: center;
		animation: npFadeIn 0.25s ease-out;
		transition: --np-glow 1.6s ease;
	}
	/* 主光晕：从黑胶/封面后方泛开；辅光晕：右上增加层次；底部压暗聚焦 */
	.np::after {
		content: '';
		position: absolute; inset: 0;
		pointer-events: none;
		background:
			radial-gradient(ellipse 65% 55% at 28% 46%, color-mix(in srgb, var(--np-glow) 26%, transparent), transparent 72%),
			radial-gradient(ellipse 45% 38% at 80% 14%, color-mix(in srgb, var(--np-glow) 10%, transparent), transparent 70%),
			radial-gradient(ellipse 130% 95% at 50% 115%, rgba(0,0,0,0.55), transparent 62%);
		opacity: 0.7;
		transition: opacity 0.9s ease;
	}
	/* 播放时光晕呼吸增亮 */
	.np.np-playing::after { opacity: 1; }
	.np::before {
		content: '';
		position: absolute; inset: 0;
		background: var(--cover, none) center/cover;
		filter: blur(80px) saturate(0.8);
		opacity: 0.18;
		transition: opacity 0.6s;
		pointer-events: none;
	}
	.np:not([style*="--cover"])::before { opacity: 0; }
	@keyframes npFadeIn { from { opacity: 0; } to { opacity: 1; } }

	/* ── Close ── */
	.np-close {
		position: absolute; top: 24px; right: 24px; z-index: 10;
		width: 36px; height: 36px; border-radius: 50%;
		border: 1px solid rgba(255,255,255,0.08);
		background: rgba(255,255,255,0.06);
		color: var(--fg-secondary); cursor: pointer;
		display: flex; align-items: center; justify-content: center;
		transition: background 0.15s, color 0.15s;
	}
	.np-close:hover { background: rgba(255,255,255,0.12); color: var(--fg-primary); }
	.np-close:active { background: rgba(255,255,255,0.15); }

	/* ── Body ── */
	.np-body {
		display: flex; gap: 48px; align-items: center;
		max-width: 960px; width: 100%; padding: 0 24px;
	}

	/* ── Vinyl record ── */
	.np-side { flex-shrink: 0; display: flex; flex-direction: column; align-items: center; gap: 16px; }
	.np-art-wrap { position: relative; }
	.np-vinyl {
		position: relative;
		width: 320px; height: 320px;
		border-radius: 50%;
		display: flex; align-items: center; justify-content: center;
		animation: npCoverIn 0.5s cubic-bezier(0.22, 1, 0.36, 1);
	}
	@keyframes npCoverIn { from { opacity: 0; transform: scale(0.92); } to { opacity: 1; transform: scale(1); } }
	.np-vinyl-grooves {
		position: absolute; inset: 0; border-radius: 50%;
		background:
			repeating-radial-gradient(circle at 50% 50%,
				transparent 0,
				transparent 2px,
				rgba(0,0,0,0.15) 2px,
				rgba(0,0,0,0.15) 3px
			),
			linear-gradient(135deg, #1a1a1a, #242420);
		box-shadow: 0 16px 48px rgba(0,0,0,0.5), inset 0 0 60px rgba(0,0,0,0.3);
	}
	.np-art {
		position: relative;
		width: 180px; height: 180px; border-radius: 50%;
		background: linear-gradient(135deg, #1a1a1a, #242420);
		background-size: cover; background-position: center;
		box-shadow: 0 0 0 4px rgba(0,0,0,0.3), 0 4px 20px rgba(0,0,0,0.4);
		display: flex; align-items: center; justify-content: center;
		z-index: 1;
		transition: transform 0.3s;
	}
	.np-art.spinning { animation: npSpin 6s linear infinite; }
	@keyframes npSpin { from { transform: rotate(0deg); } to { transform: rotate(360deg); } }
	:global(.np-no-cover) { width: 80px; height: 80px; color: rgba(255,255,255,0.08); }
	.np-vinyl-label {
		position: absolute; top: 50%; left: 50%; transform: translate(-50%, -50%);
		width: 24px; height: 24px; border-radius: 50%;
		background: rgba(255,255,255,0.06);
		border: 1px solid rgba(255,255,255,0.08);
		z-index: 2;
		pointer-events: none;
	}

	/* ── Main content ── */
	.np-main { flex: 1; min-width: 0; display: flex; flex-direction: column; gap: 16px; max-height: 80vh; }
	.np-spectrum-wrap { width: 100%; opacity: 0.85; position: relative; }
	.np-viz-toggle {
		position: absolute; top: 4px; right: 4px;
		width: 24px; height: 24px; border-radius: 50%;
		border: 1px solid rgba(255,255,255,0.08);
		background: rgba(0,0,0,0.3); color: var(--fg-tertiary);
		cursor: pointer; display: flex; align-items: center; justify-content: center;
		transition: all 0.15s; z-index: 2;
	}
	.np-viz-toggle:hover { background: rgba(255,255,255,0.1); color: var(--fg-primary); }

	/* ── Track meta ── */
	.np-meta { animation: npMetaIn 0.3s ease-out; }
	@keyframes npMetaIn { from { opacity: 0; transform: translateY(6px); } to { opacity: 1; transform: translateY(0); } }
	.np-title { font-family: var(--font-display); font-size: 22px; font-weight: 600; color: var(--fg-primary); margin: 0; line-height: 1.3; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; letter-spacing: 0.2px; }
	.np-artist { font-size: 14px; color: var(--fg-secondary); margin: 4px 0 0; }

	/* ── HiFi 规格读数条（硬件仪表面板）── */
	.np-spec {
		display: flex; align-items: center; gap: 16px;
		margin-top: 16px; padding: 10px 16px;
		background: linear-gradient(180deg, rgba(255,255,255,0.035), rgba(255,255,255,0.012));
		border: 1px solid rgba(255,255,255,0.07);
		border-radius: var(--radius-md);
		box-shadow: inset 0 1px 0 rgba(255,255,255,0.04);
	}
	.spec-item { display: flex; flex-direction: column; gap: 3px; }
	.spec-v {
		font-family: var(--font-mono); font-size: 13px; font-weight: 500;
		color: var(--accent); letter-spacing: 0.3px; font-variant-numeric: tabular-nums;
		text-shadow: 0 0 12px var(--accent-glow);
	}
	.spec-k { font-size: 9px; text-transform: uppercase; letter-spacing: 1px; color: var(--fg-tertiary); }
	.spec-sep { width: 1px; align-self: stretch; margin: 2px 0; background: rgba(255,255,255,0.08); }
	/* BIT-PERFECT 指示灯：开启时琥珀点亮 + 呼吸 */
	.spec-lamp {
		display: flex; align-items: center; gap: 7px; margin-left: auto;
		padding: 5px 12px; border-radius: 20px;
		border: 1px solid rgba(255,255,255,0.08);
		transition: border-color 0.3s, background 0.3s;
	}
	.lamp-dot { width: 6px; height: 6px; border-radius: 50%; background: rgba(255,255,255,0.12); transition: background 0.3s, box-shadow 0.3s; }
	.lamp-text { font-family: var(--font-mono); font-size: 9px; letter-spacing: 1.4px; color: var(--fg-tertiary); transition: color 0.3s; }
	.spec-lamp.on { border-color: rgba(226,166,61,0.35); background: var(--accent-dim); }
	.spec-lamp.on .lamp-dot { background: var(--accent); animation: lampPulse 2.4s ease-in-out infinite; }
	.spec-lamp.on .lamp-text { color: var(--accent); }
	@keyframes lampPulse {
		0%, 100% { box-shadow: 0 0 5px var(--accent); opacity: 1; }
		50% { box-shadow: 0 0 12px var(--accent); opacity: 0.7; }
	}

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
		border: 1px solid rgba(255,255,255,0.08);
		background: rgba(255,255,255,0.06);
		color: var(--fg-secondary); cursor: pointer;
		display: flex; align-items: center; justify-content: center;
		transition: background 0.15s, color 0.15s;
	}
	.np-queue-btn:hover { background: rgba(255,255,255,0.12); color: var(--fg-primary); }
	.np-queue-btn:active { background: rgba(255,255,255,0.15); }

	/* ── Queue panel — slide from right ── */
	.np-queue-overlay {
		position: absolute; inset: 0; z-index: 19;
		background: rgba(0,0,0,0.3);
	}
	.np-queue-panel {
		position: absolute; top: 0; right: 0; bottom: 0; z-index: 20;
		width: 320px;
		background: rgba(12, 12, 12, 0.97);
		border-left: 1px solid rgba(255,255,255,0.06);
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
		box-shadow: 0 4px 20px rgba(var(--accent-rgb, 226, 166, 61), 0.3);
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
	.np-info-toggle :global(svg) { transition: transform 0.2s; }
	.np-info-toggle :global(svg.rotated) { transform: rotate(180deg); }
	.np-info-toggle.np-analyze { margin-right: 14px; color: var(--accent); }
	.np-info-toggle.np-analyze:disabled { opacity: 0.4; cursor: default; }

	.np-info-panel {
		margin-top: 8px; padding: 12px 14px;
		border-radius: 10px;
		background: rgba(255,255,255,0.03); border: 0.5px solid rgba(255,255,255,0.05);
	}
	.np-info-grid { display: grid; grid-template-columns: repeat(3, 1fr); gap: 8px 16px; }
	.np-info-item { display: flex; flex-direction: column; gap: 2px; }
	.np-info-k { font-size: 10px; color: var(--fg-tertiary); text-transform: uppercase; letter-spacing: 0.3px; }
	.np-info-v { font-family: var(--font-mono); font-size: 12px; color: var(--fg-secondary); font-variant-numeric: tabular-nums; }

	/* ── Responsive ── */
	@media (max-width: 720px) {
		.np-body { flex-direction: column; gap: 24px; max-width: 100%; }
		.np-vinyl { width: 200px; height: 200px; }
		.np-art { width: 110px; height: 110px; }
		.np-main { max-height: none; }
	}
</style>
