<script lang="ts">
	import { browser } from '$app/environment';
	import { SvelteMap } from 'svelte/reactivity';
	import { getLibraryState } from '$lib/stores/library.svelte';
	import { getPlaybackState } from '$lib/stores/playback.svelte';
	import { formatTime } from '$lib/utils/time';
	import type { Track, AlbumBrief } from '$lib/audio/types';
	import TagEditor from '$lib/components/panels/TagEditor.svelte';
	import { ChevronLeft, Play, Music, Upload, Pencil, Trash2, Disc3, User, ChevronRight } from 'lucide-svelte';
	import { t } from '$lib/i18n/i18n.svelte';

	const library = getLibraryState();
	const playback = getPlaybackState();

	type BrowseMode = 'tracks' | 'artists' | 'albums' | 'album_tracks' | 'albums_grid';
	let mode = $state<BrowseMode>('tracks');
	let artists = $state<string[]>([]);
	let albums = $state<string[]>([]);
	let selectedArtist = $state('');
	let selectedAlbum = $state('');
	let albumTracks = $state<Track[]>([]);
	let browsingLoading = $state(false);
	let albumBriefs = $state<AlbumBrief[]>([]);
	let albumCovers = new SvelteMap<number, string>();

	let editTrack = $state<Track | null>(null);
	let deleteTarget = $state<Track | null>(null);

	// ── Virtual scroll (tracks mode) ──
	const ROW_HEIGHT = 40;
	const OVERSCAN = 15;
	let trackTableEl: HTMLDivElement | undefined = $state();
	let tableScrollTop = $state(0);
	let tableViewH = $state(0);

	$effect(() => {
		const el = trackTableEl;
		if (!el) return;
		const ro = new ResizeObserver((entries) => {
			tableViewH = entries[0]!.contentRect.height;
		});
		ro.observe(el);
		return () => ro.disconnect();
	});

	let totalCount = $derived(library.tracks.length);
	let visStart = $derived(Math.max(0, Math.floor(tableScrollTop / ROW_HEIGHT) - OVERSCAN));
	let visEnd = $derived(Math.min(totalCount, visStart + Math.ceil(tableViewH / ROW_HEIGHT) + OVERSCAN * 2));
	let visTracks = $derived(library.tracks.slice(visStart, visEnd));
	let topSpacerH = $derived(visStart * ROW_HEIGHT);
	let bottomSpacerH = $derived(Math.max(0, (totalCount - visEnd) * ROW_HEIGHT));

	function onTableScroll() {
		if (!trackTableEl) return;
		tableScrollTop = trackTableEl.scrollTop;
	}

	function playTrack(_track: Track, index: number) {
		playback.playAllAsQueue(library.tracks, index);
	}

	function openEditor(track: Track) {
		editTrack = track;
	}

	function closeTagEditor() {
		editTrack = null;
		library.loadTracks();
	}

	async function executeDelete() {
		if (!deleteTarget) return;
		await library.deleteTrack(deleteTarget.id);
		deleteTarget = null;
		await library.loadTracks();
	}

	async function handleScan() {
		try {
			await library.scanDirectory();
		} catch { console.error('Scan cancelled'); }
	}

	$effect(() => {
		library.loadTracks();
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
		library.loadTracks();
	}

	async function enterAlbumGrid() {
		mode = 'albums_grid';
		browsingLoading = true;
		albumBriefs = await library.loadAllAlbums();
		albumCovers = new SvelteMap();
		browsingLoading = false;
		// 封面懒加载：由 IntersectionObserver action 按需加载
	}

	let coverObserver: IntersectionObserver | null = null;
	function observeCover(node: HTMLElement, params: { id: number; path: string }) {
		if (!browser) return;
		if (!coverObserver) {
			coverObserver = new IntersectionObserver((entries) => {
				for (const entry of entries) {
					if (entry.isIntersecting) {
						const { id, path } = (entry.target as any).__coverParams;
						loadCoverForAlbum({ first_track_id: id, first_track_path: path });
						coverObserver!.unobserve(entry.target);
					}
				}
			}, { rootMargin: '200px' });
		}
		(node as any).__coverParams = params;
		coverObserver.observe(node);
		return {
			destroy() { coverObserver?.unobserve(node); }
		};
	}

	async function loadCoverForAlbum(ab: { first_track_id: number; first_track_path: string }) {
		if (albumCovers.has(ab.first_track_id)) return;
		try {
			const { invoke } = await import('@tauri-apps/api/core');
			const data = await invoke('get_file_cover_cmd', { path: ab.first_track_path }) as string | null;
			if (data) {
				albumCovers.set(ab.first_track_id, data);
			}
		} catch { console.warn('[Library] 封面加载失败:',); }
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
				<button class="back-btn" onclick={backToAlbums} aria-label={t('library.back')}>
					<ChevronLeft size={18} />
				</button>
				{selectedAlbum}
			{:else if mode === 'albums'}
				<button class="back-btn" onclick={backToArtists} aria-label={t('library.back')}>
					<ChevronLeft size={18} />
				</button>
				{selectedArtist}
			{:else if mode === 'albums_grid'}
				{t('library.track_count', { count: library.trackCount })}
			{:else}
				{t('library.track_count', { count: library.trackCount })}
			{/if}
		</h2>
		<div class="lib-actions">
			{#if mode === 'tracks' && library.trackCount > 0}
				<button class="action-btn action-play-all" onclick={() => playback.playAllAsQueue(library.tracks)}>
					<Play size={16} fill="currentColor" />
					<span>{t('library.play_all')}</span>
				</button>
			{/if}
		</div>
	</div>

	<!-- Browse mode tabs -->
	<div class="browse-tabs">
		<button class="browse-tab" class:active={mode === 'tracks'} onclick={backToTracks}>{t('library.tracks')}</button>
		<button class="browse-tab" class:active={mode === 'albums_grid'} onclick={enterAlbumGrid}>{t('library.albums')}</button>
		<button class="browse-tab" class:active={mode === 'artists' || mode === 'albums' || mode === 'album_tracks'} onclick={enterArtists}>{t('library.artists')}</button>
	</div>

	{#if browsingLoading}
		<div class="loading">
			<div class="loading-dots">
				<span class="dot"></span>
				<span class="dot"></span>
				<span class="dot"></span>
			</div>
		</div>

	{:else if mode === 'tracks' && library.trackCount === 0}
		<div class="empty-state">
			<div class="empty-icon">
				<Music size={48} stroke-width={1.5} />
			</div>
			<h3 class="empty-title">{t('library.import_title')}</h3>
			<p class="empty-hint">{t('library.import_hint')}</p>
			<button class="scan-btn" onclick={handleScan}>
				<Upload size={16} />
				<span>{t('library.scan_btn')}</span>
			</button>
		</div>

	{:else if mode === 'tracks'}
		<div class="track-table" bind:this={trackTableEl} onscroll={onTableScroll}>
			<div class="track-header">
				<span class="th-num">#</span>
				<span class="th-title">{t('library.header_title')}</span>
				<span class="th-artist">{t('library.header_artist')}</span>
				<span class="th-album">{t('library.header_album')}</span>
				<span class="th-duration">{t('library.header_duration')}</span>
			</div>
			<div class="track-list">
				<div style="height: {topSpacerH}px;"></div>
				{#each visTracks as track, vi (track.id)}
					{@const i = visStart + vi}
					<div class="track-row" class:active={playback.currentTrack?.id === track.id && playback.isPlaying} onclick={(e) => { if ((e.target as HTMLElement).closest('.td-actions')) return; playTrack(track, i); }} onkeydown={(e) => e.key === 'Enter' && playTrack(track, i)}>
						<span class="td-num">{i + 1}</span>
						<span class="td-title">
							<span class="td-title-text">{track.title || track.path.split(/[/\\]/).pop()}</span>
							<span class="td-actions">
								<button type="button" class="td-action" onclick={() => openEditor(track)} title={t('library.edit_tag')}>
									<Pencil size={12} />
								</button>
								<button type="button" class="td-action td-action-del" onclick={() => deleteTarget = track} title={t('library.delete_from_lib')}>
									<Trash2 size={12} />
								</button>
							</span>
						</span>
						<span class="td-artist">{track.artist || t('library.unknown_artist')}</span>
						<span class="td-album">{track.album || '-'}</span>
						<span class="td-duration">{track.duration ? formatTime(track.duration) : '--:--'}</span>
					</div>
				{/each}
				<div style="height: {bottomSpacerH}px;"></div>
			</div>
		</div>

	{:else if mode === 'albums_grid'}
		<div class="album-grid">
			{#if albumBriefs.length === 0}
				<div class="empty-state">
				<div class="empty-icon">
					<Disc3 size={48} stroke-width={1.5} />
				</div>
					<h3 class="empty-title">{t('library.no_albums')}</h3>
					<p class="empty-hint">{t('library.album_hint')}</p>
				</div>
			{:else}
				{#each albumBriefs as ab (ab.first_track_id)}
					<button class="album-card" use:observeCover={{ id: ab.first_track_id, path: ab.first_track_path }} onclick={() => { selectedArtist = ab.artist; selectedAlbum = ab.album; enterAlbumTracks(ab.artist, ab.album); }}>
						<div class="album-cover" style={albumCovers.has(ab.first_track_id) ? `background-image: url(${albumCovers.get(ab.first_track_id)})` : ''}>
							{#if !albumCovers.has(ab.first_track_id)}
								<Disc3 size={28} stroke-width={1.5} opacity={0.3} />
							{/if}
							<div class="album-play-overlay">
								<Play size={20} fill="currentColor" />
							</div>
						</div>
						<div class="album-info">
							<span class="album-name">{ab.album}</span>
							<span class="album-artist">{ab.artist}</span>
						</div>
					</button>
				{/each}
			{/if}
		</div>

	{:else if mode === 'artists'}
		<div class="browse-grid">
			{#each artists as artist (artist)}
				<button class="browse-card" onclick={() => enterAlbums(artist)}>
					<div class="card-icon">
						<User size={24} stroke-width={1.5} />
					</div>
					<span class="card-label">{artist}</span>
									<ChevronRight class="card-chevron" size={14} />
				</button>
			{/each}
		</div>

	{:else if mode === 'albums'}
		<div class="browse-grid">
			{#each albums as album (album)}
				<button class="browse-card" onclick={() => enterAlbumTracks(selectedArtist, album)}>
					<div class="card-icon">
						<Disc3 size={24} stroke-width={1.5} />
					</div>
					<span class="card-label">{album || t('library.unknown_album')}</span>
									<ChevronRight class="card-chevron" size={14} />
				</button>
			{/each}
		</div>

	{:else if mode === 'album_tracks'}
		<div class="track-table">
			<div class="track-header">
				<span class="th-num">#</span>
				<span class="th-title">{t('library.header_title')}</span>
				<span class="th-duration">{t('library.header_duration')}</span>
			</div>
			<div class="track-list">
				{#each albumTracks as track, i (track.id)}
					<div class="track-row" class:active={playback.currentTrack?.id === track.id && playback.isPlaying} onclick={(e) => { if ((e.target as HTMLElement).closest('.td-actions')) return; playback.playTrack(track); }} onkeydown={(e) => e.key === 'Enter' && playback.playTrack(track)}>
						<span class="td-num">{i + 1}</span>
						<span class="td-title">
							<span class="td-title-text">{track.title || track.path.split(/[/\\]/).pop()}</span>
							<span class="td-actions">
								<button type="button" class="td-action" onclick={() => openEditor(track)} title={t('library.edit_tag')}>
									<Pencil size={12} />
								</button>
								<button type="button" class="td-action td-action-del" onclick={() => deleteTarget = track} title={t('library.delete_from_lib')}>
									<Trash2 size={12} />
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
			<p class="confirm-msg">{t('library.confirm_delete', { name: deleteTarget.title || deleteTarget.path.split(/[/\\]/).pop() })}</p>
			<div class="confirm-actions">
				<button class="btn-cancel" onclick={() => deleteTarget = null}>{t('library.cancel')}</button>
				<button class="btn-danger" onclick={() => executeDelete()}>{t('library.delete')}</button>
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
	.loading { display: flex; align-items: center; justify-content: center; flex: 1; }
	.loading-dots { display: flex; gap: 6px; }
	.dot { width: 6px; height: 6px; border-radius: 50%; background: var(--accent-dim); animation: loadPulse 1.2s ease-in-out infinite; }
	.dot:nth-child(2) { animation-delay: 0.2s; }
	.dot:nth-child(3) { animation-delay: 0.4s; }
	@keyframes loadPulse { 0%, 80% { transform: scale(0.5); opacity: 0.3; } 40% { transform: scale(1); opacity: 1; } }
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
	.track-row { display: flex; align-items: center; padding: var(--space-2) var(--space-3); border: none; background: transparent; cursor: pointer; transition: all 0.12s var(--ease-out); width: 100%; text-align: left; font-family: inherit; color: var(--fg-secondary); font-size: 13px; border-radius: var(--radius-sm); margin: 1px 0; position: relative; overflow: hidden; }
	.track-row::before {
		content: ''; position: absolute; left: 0; top: 4px; bottom: 4px; width: 2px;
		background: var(--accent); border-radius: 0 2px 2px 0;
		transform: scaleY(0); transition: transform 0.15s var(--ease-out);
		transform-origin: top;
	}
	.track-row:hover::before { transform: scaleY(1); }
	.track-row:hover { background: var(--bg-hover); transform: translateX(2px); }
	.track-row.active { background: var(--accent-dim); box-shadow: inset 2px 0 0 var(--accent); }
	.track-row.active::before { display: none; }
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

	/* ── Album grid ── */
	.album-grid {
		display: grid;
		grid-template-columns: repeat(auto-fill, minmax(160px, 1fr));
		gap: 16px;
		padding: 4px 0 16px;
		flex: 1;
		overflow-y: auto;
		align-content: start;
	}

	.album-card {
		display: flex;
		flex-direction: column;
		border: none;
		background: transparent;
		cursor: pointer;
		text-align: left;
		font-family: inherit;
		padding: 0;
		border-radius: var(--radius-md);
		transition: all 0.15s var(--ease-out);
	}

	.album-card:hover {
		transform: translateY(-2px);
	}

	.album-cover {
		width: 100%;
		aspect-ratio: 1;
		border-radius: var(--radius-md);
		background: linear-gradient(135deg, #1a1a1a, #242420);
		background-size: cover;
		background-position: center;
		display: flex;
		align-items: center;
		justify-content: center;
		position: relative;
		overflow: hidden;
		box-shadow: 0 2px 12px rgba(0, 0, 0, 0.3);
		transition: box-shadow 0.15s;
	}

	.album-card:hover .album-cover {
		box-shadow: 0 6px 24px rgba(0, 0, 0, 0.4);
	}

	.album-play-overlay {
		position: absolute;
		inset: 0;
		background: rgba(0, 0, 0, 0.3);
		display: flex;
		align-items: center;
		justify-content: center;
		opacity: 0;
		transition: opacity 0.15s;
		color: white;
	}

	.album-card:hover .album-play-overlay {
		opacity: 1;
	}

	.album-info {
		padding: 8px 2px 0;
		display: flex;
		flex-direction: column;
		gap: 2px;
	}

	.album-name {
		font-size: 12px;
		font-weight: 600;
		color: var(--fg-primary);
		white-space: nowrap;
		overflow: hidden;
		text-overflow: ellipsis;
	}

	.album-artist {
		font-size: 11px;
		color: var(--fg-tertiary);
		white-space: nowrap;
		overflow: hidden;
		text-overflow: ellipsis;
	}

	.td-artist { flex: 1 1 25%; min-width: 0; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
	.td-album { flex: 1 1 25%; min-width: 0; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; color: var(--fg-tertiary); }
	.td-duration { width: 48px; text-align: right; font-variant-numeric: tabular-nums; flex-shrink: 0; color: var(--fg-tertiary); font-size: 11px; }

	/* ── Confirm dialog ── */
	.confirm-dialog {
		position: fixed; top: 50%; left: 50%; z-index: 201;
		transform: translate(-50%, -50%);
		background: rgba(18,18,18,0.97);
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
