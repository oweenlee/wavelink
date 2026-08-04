import { browser, lazyInvoke } from '$lib/tauri';
import type { Track, AlbumBrief } from '$lib/audio/types';

let _tracks = $state<Track[]>([]);
let _searchQuery = $state('');
let _viewMode = $state<'list' | 'grid'>('list');
let _sortBy = $state<'title' | 'artist' | 'album' | 'duration'>('title');
let _loading = $state(false);

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
			try {
				const invoke = await lazyInvoke();
				return await invoke('get_artists') as string[];
			} catch { return []; }
		},

		async loadAlbumsByArtist(artist: string): Promise<string[]> {
			if (!browser) return [];
			try {
				const invoke = await lazyInvoke();
				return await invoke('get_albums_by_artist', { artist }) as string[];
			} catch { return []; }
		},

		async loadTracksByAlbum(artist: string, album: string): Promise<Track[]> {
			if (!browser) return [];
			try {
				const invoke = await lazyInvoke();
				return await invoke('get_tracks_by_album', { artist, album }) as Track[];
			} catch { return []; }
		},

		async loadAllAlbums(): Promise<AlbumBrief[]> {
			if (!browser) return [];
			try {
				const invoke = await lazyInvoke();
				return await invoke('get_all_albums') as AlbumBrief[];
			} catch { return []; }
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
