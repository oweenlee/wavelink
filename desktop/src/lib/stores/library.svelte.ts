import { browser, lazyInvoke } from '$lib/tauri';
import type { Track, AlbumBrief } from '$lib/audio/types';

let _tracks = $state<Track[]>([]);
let _searchQuery = $state('');
let _viewMode = $state<'list' | 'grid'>('list');
let _sortBy = $state<'title' | 'artist' | 'album' | 'duration'>('title');
let _loading = $state(false);

// 浏览数据缓存：艺术家 / 专辑列表 / 专辑曲目，避免每次切换视图都重新查库
const _artistsCache = new Map<string, string[]>();
const _albumsByArtistCache = new Map<string, string[]>();
const _tracksByAlbumCache = new Map<string, Track[]>();
let _allAlbumsCache: AlbumBrief[] | null = null;
// 专辑封面缓存（key = first_track_id）：避免每次进入专辑网格都重新从磁盘读封面
const _albumCoverCache = new Map<number, string>();

/** Sorted tracks — recomputed only when _tracks or _sortBy change */
const _sortedTracks = $derived.by(() => {
	const result = [..._tracks];
	switch (_sortBy) {
		case 'title':
			result.sort((a, b) => (a.title || '').localeCompare(b.title || ''));
			break;
		case 'artist':
			result.sort((a, b) => (a.artist || '').localeCompare(b.artist || ''));
			break;
		case 'album':
			result.sort((a, b) => (a.album || '').localeCompare(b.album || ''));
			break;
		case 'duration':
			result.sort((a, b) => (a.duration || 0) - (b.duration || 0));
			break;
	}
	return result;
});

export function getLibraryState() {
	return {
		// ── State ──
		get tracks() { return _sortedTracks; },
		get rawTracks() { return _tracks; },
		get trackCount() { return _tracks.length; },
		get searchQuery() { return _searchQuery; },
		set searchQuery(v: string) { _searchQuery = v; },
		get viewMode() { return _viewMode; },
		set viewMode(v: 'list' | 'grid') { _viewMode = v; },
		get sortBy() { return _sortBy; },
		set sortBy(v: typeof _sortBy) { _sortBy = v; },
		get loading() { return _loading; },

		// ── Library loading ──
		async loadTracks(limit = 50000, offset = 0) {
			if (!browser) return [];
			_loading = true;
			try {
				const invoke = await lazyInvoke();
				const tracks: Track[] = await invoke('get_tracks', { limit, offset });
				_tracks = tracks;
				return tracks;
			} catch (err) {
				console.error('Failed to load tracks:', err);
				return [];
			} finally {
				_loading = false;
			}
		},

		async scanDirectory() {
			if (!browser) return;
			const { scanDirectory: scanDir } = await import('$lib/audio/loader');
			await scanDir();
			await this.loadTracks();
		},

		// ── Search ──
		async search(query: string): Promise<Track[]> {
			if (!browser || !query.trim()) return [];
			try {
				const invoke = await lazyInvoke();
				return await invoke('search_tracks', { keyword: query, limit: 50, offset: 0 }) as Track[];
			} catch {
				return [];
			}
		},

		// ── Browse ──
		async loadArtists(): Promise<string[]> {
			if (!browser) return [];
			if (_artistsCache.has('')) return _artistsCache.get('')!;
			try {
				const invoke = await lazyInvoke();
				const artists = await invoke('get_artists') as string[];
				_artistsCache.set('', artists);
				return artists;
			} catch { return []; }
		},

		async loadAlbumsByArtist(artist: string): Promise<string[]> {
			if (!browser) return [];
			const key = artist;
			if (_albumsByArtistCache.has(key)) return _albumsByArtistCache.get(key)!;
			try {
				const invoke = await lazyInvoke();
				const albums = await invoke('get_albums_by_artist', { artist }) as string[];
				_albumsByArtistCache.set(key, albums);
				return albums;
			} catch { return []; }
		},

		async loadTracksByAlbum(artist: string, album: string): Promise<Track[]> {
			if (!browser) return [];
			const key = `${artist}\u0000${album}`;
			if (_tracksByAlbumCache.has(key)) return _tracksByAlbumCache.get(key)!;
			try {
				const invoke = await lazyInvoke();
				const tracks = await invoke('get_tracks_by_album', { artist, album }) as Track[];
				_tracksByAlbumCache.set(key, tracks);
				return tracks;
			} catch { return []; }
		},

		async loadAllAlbums(): Promise<AlbumBrief[]> {
			if (!browser) return [];
			if (_allAlbumsCache) return _allAlbumsCache;
			try {
				const invoke = await lazyInvoke();
				const albums = await invoke('get_all_albums') as AlbumBrief[];
				_allAlbumsCache = albums;
				return albums;
			} catch { return []; }
		},

		/** 清空浏览缓存（重扫后调用） */
		clearBrowseCache() {
			_artistsCache.clear();
			_albumsByArtistCache.clear();
			_tracksByAlbumCache.clear();
			_allAlbumsCache = null;
			_albumCoverCache.clear();
		},

		/** 读取已缓存的专辑封面（同步），未缓存返回 null */
		getAlbumCoverCached(firstTrackId: number): string | null {
			return _albumCoverCache.get(firstTrackId) ?? null;
		},

		/** 加载专辑封面：优先用数据库里已存的封面，miss 时才回退到从磁盘读音频文件 */
		async loadAlbumCover(firstTrackId: number, fallbackPath: string): Promise<string | null> {
			if (!browser) return null;
			if (_albumCoverCache.has(firstTrackId)) return _albumCoverCache.get(firstTrackId)!;
			try {
				const invoke = await lazyInvoke();
				let data = await invoke('get_cover', { trackId: firstTrackId }) as string | null;
				if (!data) {
					data = await invoke('get_file_cover_cmd', { path: fallbackPath }) as string | null;
				}
				if (data) _albumCoverCache.set(firstTrackId, data);
				return data;
			} catch { return null; }
		},

	async deleteTrack(trackId: number) {
		if (!browser) return;
		try {
			const invoke = await lazyInvoke();
			await invoke('delete_track', { trackId });
			_tracks = _tracks.filter(t => t.id !== trackId);
		} catch (err) {
			console.error('[store] deleteTrack error:', err);
		}
	},

	clearTracks() {
		_tracks = [];
	},

		async importPlaylist(): Promise<string[]> {
			if (!browser) return [];
			const { importPlaylist: doImport } = await import('$lib/audio/loader');
			return await doImport();
		},

		async getScanFolders(): Promise<string[]> {
			if (!browser) return [];
			const { getScanFolders: getFolders } = await import('$lib/audio/loader');
			return await getFolders();
		},

		async removeScanFolder(path: string): Promise<number> {
			if (!browser) return 0;
			const { removeScanFolder: doRemove } = await import('$lib/audio/loader');
			return await doRemove(path);
		},
	};
}

export type LibraryState = ReturnType<typeof getLibraryState>;
