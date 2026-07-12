<script lang="ts">
	import { browser } from '$app/environment';
	import { getLibraryState } from '$lib/stores/library.svelte';
	import { getPlaybackState } from '$lib/stores/playback.svelte';
	import { formatTime } from '$lib/data/music';
	import type { Track } from '$lib/audio/types';
	import TagEditor from '$lib/components/panels/TagEditor.svelte';

	const library = getLibraryState();
	const playback = getPlaybackState();

	type BrowseMode = 'tracks' | 'artists' | 'albums' | 'album_tracks';
	let mode = $state<BrowseMode>('tracks');
	let artists = $state<string[]>([]);
	let albums = $state<string[]>([]);
	let selectedArtist = $state('');
	let selectedAlbum = $state('');
	let albumTracks = $state<Track[]>([]);
	let browsingLoading = $state(false);

	let editTrack = $state<Track | null>(null);
	let deleteTarget = $state<Track | null>(null);

	function playTrack(_track: Track, index: number) {
		playback.playAllAsQueue(library.tracks, index);
	}

	function openEditor(track: Track) {
		editTrack = track;
	}

	function closeTagEditor() {
		editTrack = null;
		library.loadTracks(200, 0);
	}

	async function executeDelete() {
		if (!deleteTarget) return;
		await library.deleteTrack(deleteTarget.id);
		deleteTarget = null;
		await library.loadTracks(200, 0);
	}

	async function handleScan() {
		try {
			await library.scanDirectory();
		} catch { console.error('Scan cancelled'); }
	}

	$effect(() => {
		library.loadTracks(200, 0);
	});

	// ── Browse mode ──
	async function enterArtists() {
		mode = 'artists';
		browsingLoading = true;
		artists = await library.loadArtists();
		browsingLoading = false;
	}

	async function enterAlbums(artist: string) {
		selectedArtist = artist;
		mode = 'albums';
		browsingLoading = true;
		albums = await library.loadAlbumsByArtist(artist);
		browsingLoading = false;
	}

	async function enterAlbumTracks(artist: string, album: string) {
		selectedAlbum = album;
		mode = 'album_tracks';
		browsingLoading = true;
		albumTracks = await library.loadTracksByAlbum(artist, album);
		browsingLoading = false;
	}

	function backToTracks() {
		mode = 'tracks';
		library.loadTracks(200, 0);
	}

	function backToArtists() {
		mode = 'artists';
		albums = [];
		selectedArtist = '';
		enterArtists();
	}

	function backToAlbums() {
		mode = 'albums';
		selectedAlbum = '';
		enterAlbums(selectedArtist);
	}
</script>

<div class="library-view">
	<div class="lib-header">
		<h2 class="lib-title">
			{#if mode === 'album_tracks'}
				<button class="back-btn" onclick={backToAlbums} aria-label="返回">
					<svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><polyline points="15,18 9,12 15,6"/></svg>
				</button>
				{selectedAlbum}
			{:else if mode === 'albums'}
				<button class="back-btn" onclick={backToArtists} aria-label="返回">
					<svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><polyline points="15,18 9,12 15,6"/></svg>
				</button>
				{selectedArtist}
			{:else}
				{library.trackCount} 首歌曲
			{/if}
		</h2>
		<div class="lib-actions">
			{#if mode === 'tracks' && library.trackCount > 0}
				<button class="action-btn action-play-all" onclick={() => playback.playAllAsQueue(library.tracks)}>
					<svg width="16" height="16" viewBox="0 0 24 24" fill="currentColor"><polygon points="7,5 19,12 7,19"/></svg>
					<span>播放全部</span>
				</button>
			{/if}
		</div>
	</div>

	<!-- Browse mode tabs -->
	<div class="browse-tabs">
		<button class="browse-tab" class:active={mode === 'tracks'} onclick={backToTracks}>曲目</button>
		<button class="browse-tab" class:active={mode === 'artists' || mode === 'albums' || mode === 'album_tracks'} onclick={enterArtists}>艺术家</button>
	</div>

	{#if browsingLoading}
		<div class="loading">加载中...</div>

	{:else if mode === 'tracks' && library.trackCount === 0}
		<div class="empty-state">
			<div class="empty-icon">
				<svg width="48" height="48" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round"><path d="M9 18V5l12-2v13"/><circle cx="6" cy="18" r="3"/><circle cx="18" cy="16" r="3"/></svg>
			</div>
			<h3 class="empty-title">导入本地音乐</h3>
			<p class="empty-hint">点击「扫描目录」选择音乐文件夹</p>
			<button class="scan-btn" onclick={handleScan}>
				<svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"/><polyline points="17,8 12,3 7,8"/><line x1="12" y1="3" x2="12" y2="15"/></svg>
				<span>选择音乐目录</span>
			</button>
		</div>

	{:else if mode === 'tracks'}
		<div class="track-table">
			<div class="track-header">
				<span class="th-num">#</span>
				<span class="th-title">标题</span>
				<span class="th-artist">艺术家</span>
				<span class="th-album">专辑</span>
				<span class="th-duration">时长</span>
			</div>
			<div class="track-list">
				{#each library.tracks as track, i}
					<div class="track-row" class:active={playback.currentTrack?.id === track.id && playback.isPlaying} onclick={(e) => { if ((e.target as HTMLElement).closest('.td-actions')) return; playTrack(track, i); }} onkeydown={(e) => e.key === 'Enter' && playTrack(track, i)}>
						<span class="td-num">{i + 1}</span>
						<span class="td-title">
							<span class="td-title-text">{track.title || track.path.split(/[/\\]/).pop()}</span>
							<span class="td-actions">
								<button type="button" class="td-action" onclick={() => openEditor(track)} title="编辑标签">
									<svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><path d="M17 3a2.83 2.83 0 1 1 4 4L7.5 20.5 2 22l1.5-5.5Z"/><path d="m15 5 4 4"/></svg>
								</button>
								<button type="button" class="td-action td-action-del" onclick={() => deleteTarget = track} title="从曲库删除">
									<svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><polyline points="3 6 5 6 21 6"/><path d="M19 6v14a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2V6m3 0V4a2 2 0 0 1 2-2h4a2 2 0 0 1 2 2v2"/></svg>
								</button>
							</span>
						</span>
						<span class="td-artist">{track.artist || '未知艺术家'}</span>
						<span class="td-album">{track.album || '-'}</span>
						<span class="td-duration">{track.duration ? formatTime(track.duration) : '--:--'}</span>
					</div>
				{/each}
			</div>
		</div>

	{:else if mode === 'artists'}
		<div class="browse-grid">
			{#each artists as artist}
				<button class="browse-card" onclick={() => enterAlbums(artist)}>
					<div class="card-icon">
						<svg width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5"><path d="M20 21v-2a4 4 0 0 0-4-4H8a4 4 0 0 0-4 4v2"/><circle cx="12" cy="7" r="4"/></svg>
					</div>
					<span class="card-label">{artist}</span>
					<svg class="card-chevron" width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><polyline points="9,18 15,12 9,6"/></svg>
				</button>
			{/each}
		</div>

	{:else if mode === 'albums'}
		<div class="browse-grid">
			{#each albums as album}
				<button class="browse-card" onclick={() => enterAlbumTracks(selectedArtist, album)}>
					<div class="card-icon">
						<svg width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5"><circle cx="12" cy="12" r="10"/><circle cx="12" cy="12" r="3"/></svg>
					</div>
					<span class="card-label">{album || '(未知专辑)'}</span>
					<svg class="card-chevron" width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><polyline points="9,18 15,12 9,6"/></svg>
				</button>
			{/each}
		</div>

	{:else if mode === 'album_tracks'}
		<div class="track-table">
			<div class="track-header">
				<span class="th-num">#</span>
				<span class="th-title">标题</span>
				<span class="th-duration">时长</span>
			</div>
			<div class="track-list">
				{#each albumTracks as track, i}
					<div class="track-row" class:active={playback.currentTrack?.id === track.id && playback.isPlaying} onclick={(e) => { if ((e.target as HTMLElement).closest('.td-actions')) return; playback.playTrack(track); }} onkeydown={(e) => e.key === 'Enter' && playback.playTrack(track)}>
						<span class="td-num">{i + 1}</span>
						<span class="td-title">
							<span class="td-title-text">{track.title || track.path.split(/[/\\]/).pop()}</span>
							<span class="td-actions">
								<button type="button" class="td-action" onclick={() => openEditor(track)} title="编辑标签">
									<svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><path d="M17 3a2.83 2.83 0 1 1 4 4L7.5 20.5 2 22l1.5-5.5Z"/><path d="m15 5 4 4"/></svg>
								</button>
								<button type="button" class="td-action td-action-del" onclick={() => deleteTarget = track} title="从曲库删除">
									<svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><polyline points="3 6 5 6 21 6"/><path d="M19 6v14a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2V6m3 0V4a2 2 0 0 1 2-2h4a2 2 0 0 1 2 2v2"/></svg>
								</button>
							</span>
						</span>
						<span class="td-duration">{track.duration ? formatTime(track.duration) : '--:--'}</span>
					</div>
				{/each}
			</div>
		</div>
	{/if}

	{#if editTrack}
		<TagEditor track={editTrack} onclose={closeTagEditor} />
	{/if}

	{#if deleteTarget}
		<div class="backdrop" onclick={() => deleteTarget = null} role="button" tabindex="0" onkeydown={(e) => e.key === 'Escape' && (deleteTarget = null)}></div>
		<div class="confirm-dialog">
			<p class="confirm-msg">确定从曲库中删除"{deleteTarget.title || deleteTarget.path.split(/[/\\]/).pop()}"吗？</p>
			<div class="confirm-actions">
				<button class="btn-cancel" onclick={() => deleteTarget = null}>取消</button>
				<button class="btn-danger" onclick={() => executeDelete()}>删除</button>
			</div>
		</div>
	{/if}
</div>

<style>
	.library-view { padding: 0 var(--space-6) var(--space-6); display: flex; flex-direction: column; height: 100%; }
	.lib-header { display: flex; align-items: center; justify-content: space-between; margin-bottom: var(--space-3); flex-shrink: 0; }
	.lib-title { font-size: 20px; font-weight: 600; color: var(--fg-primary); display: flex; align-items: center; gap: var(--space-2); letter-spacing: -0.3px; }
	.lib-actions { display: flex; gap: var(--space-2); }
	.back-btn { width: 28px; height: 28px; border-radius: var(--radius-sm); border: none; background: var(--bg-hover); color: var(--fg-secondary); cursor: pointer; display: inline-flex; align-items: center; justify-content: center; transition: all 0.12s; }
	.back-btn:hover { background: var(--bg-active); color: var(--fg-primary); }
	.action-btn { display: flex; align-items: center; gap: var(--space-1); padding: var(--space-1) var(--space-3); border-radius: var(--radius-sm); border: none; background: var(--bg-hover); color: var(--fg-secondary); font-size: 12px; font-family: inherit; cursor: pointer; transition: all 0.12s; }
	.action-btn:hover { background: var(--bg-active); color: var(--fg-primary); }
	.browse-tabs { display: flex; gap: 1px; margin-bottom: var(--space-4); flex-shrink: 0; background: var(--bg-hover); border-radius: var(--radius-sm); padding: 2px; width: fit-content; }
	.browse-tab { padding: var(--space-1) var(--space-4); border: none; border-radius: var(--radius-sm); background: transparent; color: var(--fg-tertiary); font-size: 12px; font-weight: 500; font-family: inherit; cursor: pointer; transition: all 0.12s; }
	.browse-tab.active { background: var(--bg); color: var(--fg-primary); }
	.browse-tab:hover:not(.active) { color: var(--fg-secondary); }
	.browse-grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(180px, 1fr)); gap: var(--space-1); flex: 1; overflow-y: auto; align-content: start; }
	.browse-card { display: flex; align-items: center; gap: var(--space-2); padding: var(--space-3) var(--space-3); border: none; border-radius: var(--radius-md); background: transparent; color: var(--fg-secondary); cursor: pointer; transition: all 0.1s; text-align: left; font-family: inherit; }
	.browse-card:hover { background: var(--bg-hover); }
	.card-icon { color: var(--fg-quaternary); flex-shrink: 0; }
	.card-label { flex: 1; font-size: 13px; font-weight: 500; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
	.loading { display: flex; align-items: center; justify-content: center; flex: 1; color: var(--fg-tertiary); font-size: 13px; }
	.empty-state { flex: 1; display: flex; flex-direction: column; align-items: center; justify-content: center; gap: var(--space-4); padding: 60px 40px; }
	.empty-icon { color: var(--fg-quaternary); }
	.empty-title { font-size: 16px; font-weight: 500; color: var(--fg-secondary); }
	.empty-hint { font-size: 12px; color: var(--fg-tertiary); max-width: 360px; text-align: center; }
	.scan-btn { display: flex; align-items: center; gap: var(--space-2); padding: var(--space-3) var(--space-5); border: none; border-radius: var(--radius-md); background: var(--accent-dim); color: var(--fg-primary); font-size: 13px; font-family: inherit; cursor: pointer; }
	.scan-btn:hover { filter: brightness(1.1); }
	.track-table { flex: 1; overflow-y: auto; overflow-x: hidden; }
	.track-header { display: flex; align-items: center; padding: var(--space-2) var(--space-3); font-size: 10px; color: var(--fg-tertiary); text-transform: uppercase; letter-spacing: 1px; border-bottom: 1px solid var(--separator); position: sticky; top: 0; background: var(--bg); }
	.th-num { width: 28px; text-align: center; flex-shrink: 0; }
	.th-title { flex: 1 1 35%; min-width: 0; }
	.th-artist { flex: 1 1 25%; min-width: 0; }
	.th-album { flex: 1 1 25%; min-width: 0; }
	.th-duration { width: 48px; text-align: right; flex-shrink: 0; }
	.track-row { display: flex; align-items: center; padding: var(--space-2) var(--space-3); border: none; background: transparent; cursor: pointer; transition: all 0.12s var(--ease-out); width: 100%; text-align: left; font-family: inherit; color: var(--fg-secondary); font-size: 13px; border-radius: var(--radius-sm); margin: 1px 0; }
	.track-row:hover { background: var(--bg-hover); transform: translateX(2px); }
	.track-row.active { background: var(--accent-dim); box-shadow: inset 2px 0 0 var(--accent); }
	.track-row:active { transform: scale(0.995); }
	.td-num { width: 28px; text-align: center; color: var(--fg-tertiary); font-variant-numeric: tabular-nums; flex-shrink: 0; font-size: 11px; }
	.td-title { flex: 1 1 35%; min-width: 0; display: flex; align-items: center; gap: var(--space-2); }
	.td-title-text { font-size: 13px; font-weight: 500; color: var(--fg-primary); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
	.td-actions { display: flex; gap: 1px; opacity: 0; transition: opacity 0.1s; flex-shrink: 0; }
	.track-row:hover .td-actions { opacity: 1; }
	.td-action {
		width: 24px; height: 24px; padding: 0; border: none; border-radius: var(--radius-sm);
		background: transparent; color: var(--fg-quaternary); cursor: pointer; font: inherit;
		display: inline-flex; align-items: center; justify-content: center;
		transition: all 0.1s; position: relative; z-index: 1;
	}
	.td-action:hover { color: var(--fg-secondary); background: var(--bg-hover); }
	.td-action-del:hover { color: rgba(255, 80, 80, 0.6); background: rgba(255, 80, 80, 0.08); }
	.track-row.active .td-title-text { color: var(--accent); }
	.td-artist { flex: 1 1 25%; min-width: 0; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
	.td-album { flex: 1 1 25%; min-width: 0; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; color: var(--fg-tertiary); }
	.td-duration { width: 48px; text-align: right; font-variant-numeric: tabular-nums; flex-shrink: 0; color: var(--fg-tertiary); font-size: 11px; }

	/* ── Confirm dialog ── */
	.confirm-dialog {
		position: fixed; top: 50%; left: 50%; z-index: 201;
		transform: translate(-50%, -50%);
		background: rgba(22,22,35,0.94); backdrop-filter: blur(48px);
		border: 1px solid var(--separator); border-radius: var(--radius-xl);
		padding: 24px; max-width: 360px; width: 90vw;
	}
	.confirm-msg { font-size: 14px; color: var(--fg-primary); margin: 0 0 16px; line-height: 1.6; }
	.confirm-actions { display: flex; gap: 8px; justify-content: flex-end; }
	.btn-cancel { padding: 8px 18px; border-radius: var(--radius-md); border: 1px solid var(--separator); background: transparent; color: var(--fg-secondary); font-size: 13px; font-family: inherit; cursor: pointer; }
	.btn-cancel:hover { background: var(--bg-hover); }
	.btn-danger { padding: 8px 18px; border-radius: var(--radius-md); border: none; background: rgba(255, 80, 80, 0.15); color: rgba(255, 80, 80, 0.8); font-size: 13px; font-family: inherit; cursor: pointer; }
	.btn-danger:hover { background: rgba(255, 80, 80, 0.25); }
</style>
