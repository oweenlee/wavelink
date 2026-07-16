<script lang="ts">
	import { browser } from '$app/environment';
	import { getUiState } from '$lib/stores/ui.svelte';
	import { getPlaybackState } from '$lib/stores/playback.svelte';
	import { getLyricsState, loadForTrack } from '$lib/stores/lyrics.svelte';
	import { Disc3, X, Mic2 } from 'lucide-svelte';

	const ui = getUiState();
	const playback = getPlaybackState();
	const lyrics = getLyricsState();

	let lyricsContainer: HTMLDivElement | undefined = $state();
	let _lastTrackPath = '';
	let coverDataUrl = $state('');

	$effect(() => {
		const track = playback.currentTrack;
		if (!track || !browser) { loadForTrack(null); return; }
		if (track.path !== _lastTrackPath) {
			_lastTrackPath = track.path;
			loadForTrack(track);
		}
	});

	// Load cover for mini thumbnail
	$effect(() => {
		const track = playback.currentTrack;
		if (!track || !browser) { coverDataUrl = ''; return; }
		let cancelled = false;
		import('@tauri-apps/api/core').then(async (mod) => {
			try {
				const data: unknown = await mod.invoke('get_file_cover_cmd', { path: track.path });
				if (cancelled) return;
				if (data && typeof data === 'string') coverDataUrl = data;
			} catch { coverDataUrl = ''; }
		});
		return () => { cancelled = true; };
	});

	$effect(() => {
		if (!ui.showLyricsPanel || !lyricsContainer || lyrics.lines.length === 0) return;
		const _t = playback.currentTime;
		if (lyrics.currentIndex < 0) return;
		const lines = lyricsContainer.querySelectorAll('.lyric-line');
		if (lines && lines[lyrics.currentIndex]) {
			lines[lyrics.currentIndex].scrollIntoView({ behavior: 'smooth', block: 'center' });
		}
	});

	let progressPct = $derived.by(() =>
		playback.duration > 0 ? (playback.currentTime / playback.duration) * 100 : 0
	);

	function closePanel() { ui.showLyricsPanel = false; }

	let trackTitle = $derived.by(() => playback.currentTrack?.title ?? '');
	let trackArtist = $derived.by(() => playback.currentTrack?.artist ?? '');
</script>

{#if ui.showLyricsPanel}
	<div class="backdrop" onclick={closePanel} role="button" tabindex="0" onkeydown={(e) => e.key === 'Enter' && closePanel()}></div>
{/if}

<div class="lyrics-panel" class:visible={ui.showLyricsPanel}>
	<div class="panel-header">
		<div class="track-info">
			<div class="mini-cover" style={coverDataUrl ? `background-image: url(${coverDataUrl})` : ''}>
			{#if !coverDataUrl}
				<Disc3 size={20} stroke-width={1.2} opacity={0.25} />
			{/if}
		</div>
			<div>
				<h3 class="track-name">{trackTitle}</h3>
				<p class="track-artist">{trackArtist}</p>
			</div>
		</div>
		<button class="close-btn" onclick={closePanel} aria-label="关闭">
			<X size={18} />
		</button>
	</div>

	<div class="lyrics-body" bind:this={lyricsContainer}>
		{#if lyrics.loading}
			<div class="status"><p>加载歌词...</p></div>
		{:else if lyrics.lines.length > 0}
			<div class="lyrics-scroll">
				{#each lyrics.lines as line, i (i)}
					<div class="lyric-line" class:active={i === lyrics.currentIndex} class:past={i < lyrics.currentIndex}>
						<span class="lyric-text" style={i === lyrics.currentIndex ? `--progress: ${lyrics.progress()}` : ''}>{line.text}</span>
					</div>
				{/each}
			</div>
		{:else}
			<div class="status">
				<Mic2 size={42} stroke-width={1.5} opacity={0.25} />
				<p>{lyrics.error || '暂无歌词'}</p>
			</div>
		{/if}
	</div>

	<div class="progress-bar"><div class="progress-fill" style="width: {progressPct}%;"></div></div>
</div>

<style>
	.backdrop { position: fixed; inset: 0; background: rgba(0, 0, 0, 0.4); z-index: 80; animation: fadeIn 0.3s ease; }
	@keyframes fadeIn { from { opacity: 0; } to { opacity: 1; } }

	.lyrics-panel {
		position: fixed; top: 0; right: 0; width: 420px; max-width: 100vw;
		height: 100vh; z-index: 90;
		background: rgba(20, 20, 30, 0.85);
		backdrop-filter: blur(40px); -webkit-backdrop-filter: blur(40px);
		border-left: 1px solid var(--separator);
		display: flex; flex-direction: column;
		transform: translateX(100%);
		transition: transform 0.35s cubic-bezier(0.25, 0.1, 0.25, 1);
		box-shadow: -8px 0 40px rgba(0, 0, 0, 0.3);
	}
	.lyrics-panel.visible { transform: translateX(0); }

	.panel-header { display: flex; align-items: center; justify-content: space-between; padding: 20px 24px; border-bottom: 1px solid var(--separator); }
	.track-info { display: flex; align-items: center; gap: 14px; }
	.mini-cover { width: 44px; height: 44px; border-radius: var(--radius-md); background-image: linear-gradient(135deg, #2a2a4e, #1a1a3e); background-size: cover; background-position: center; flex-shrink: 0; display: flex; align-items: center; justify-content: center; color: var(--fg-quaternary); }
	.track-name { font-size: 15px; font-weight: 600; color: var(--fg-primary); }
	.track-artist { font-size: 12px; color: var(--fg-tertiary); margin-top: 2px; }
	.close-btn { width: 36px; height: 36px; border-radius: var(--radius-md); border: none; background: var(--bg-hover); color: var(--fg-secondary); cursor: pointer; display: flex; align-items: center; justify-content: center; transition: all 0.2s; }
	.close-btn:hover { background: var(--bg-active); color: var(--fg-primary); }

	.lyrics-body { flex: 1; overflow-y: auto; padding: 24px; display: flex; align-items: center; justify-content: center; }
	.lyrics-body::-webkit-scrollbar { width: 4px; }
	.lyrics-body::-webkit-scrollbar-thumb { background: var(--bg-active); border-radius: 2px; }

	.lyrics-scroll { display: flex; flex-direction: column; gap: 20px; width: 100%; padding: 40px 0; }
	.lyric-line { text-align: center; transition: all 0.4s ease; padding: 4px 0; }
	.lyric-text { font-size: 18px; font-weight: 400; color: var(--fg-quaternary); transition: all 0.4s ease; line-height: 1.6; letter-spacing: 0.5px; background: linear-gradient(to right, var(--fg-primary) 0%, var(--fg-primary) var(--progress, 0%), var(--fg-quaternary) var(--progress, 0%)); -webkit-background-clip: text; -webkit-text-fill-color: transparent; background-clip: text; }
	.lyric-line.active .lyric-text { font-size: 22px; font-weight: 600; }
	.lyric-line.past .lyric-text { font-size: 15px; color: var(--fg-quaternary); }

	.status { display: flex; flex-direction: column; align-items: center; gap: 16px; color: var(--fg-tertiary); }
	.status p { font-size: 14px; }

	.progress-bar { height: 2px; background: var(--bg-active); flex-shrink: 0; }
	.progress-fill { height: 100%; background: linear-gradient(90deg, var(--accent), color-mix(in srgb, var(--accent) 70%, #cc88cc)); border-radius: 1px; transition: width 0.3s linear; }
</style>
