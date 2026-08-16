import { describe, it, expect, vi, beforeEach } from 'vitest';
import type { Track } from '$lib/audio/types';

const mockTrack: Track = {
	id: 1, path: '/music/a.mp3', title: 'Alpha', artist: 'Zed',
	album: 'First', album_artist: null, track_number: 1, disc_number: 1,
	year: 2024, genre: 'Pop', duration: 200, sample_rate: 44100,
	channels: 2, format: 'mp3', file_size: 1000, file_modified: null,
	date_added: 1000, play_count: 0, last_played: null, rating: 0,
	missing: false,
};

const mockTrack2: Track = {
	...mockTrack, id: 2, path: '/music/b.mp3', title: 'Beta', artist: 'Alice',
	album: 'Second', duration: 100,
};

const mockTrack3: Track = {
	...mockTrack, id: 3, path: '/music/c.mp3', title: 'Gamma', artist: 'Bob',
	album: 'First', duration: 300,
};

// ---- mocks ----
vi.mock('$app/environment', () => ({ browser: true }));

const mockInvoke = vi.hoisted(() => vi.fn());
vi.mock('@tauri-apps/api/core', () => ({ invoke: mockInvoke }));

// mock $lib/audio/loader — scanDirectory imports it dynamically
const mockLoader = vi.hoisted(() => ({
	scanDirectory: vi.fn(),
	importPlaylist: vi.fn(),
	getScanFolders: vi.fn(),
	removeScanFolder: vi.fn(),
}));
vi.mock('$lib/audio/loader', () => mockLoader);

// ---- tests ----
describe('getLibraryState', () => {
	let state: ReturnType<typeof import('$lib/stores/library.svelte')['getLibraryState']>;

	beforeEach(async () => {
		vi.clearAllMocks();
		mockInvoke.mockReset();
		const mod = await import('$lib/stores/library.svelte');
		state = mod.getLibraryState();
		state.clearTracks();
		state.searchQuery = '';
		state.sortBy = 'title'; // 重置模块级排序状态（空列表时不触发 reload）
	});

	it('starts with empty tracks', () => {
		expect(state.trackCount).toBe(0);
		expect(state.tracks).toEqual([]);
		expect(state.loading).toBe(false);
	});

	it('setSearchQuery updates the query', () => {
		state.searchQuery = 'test';
		expect(state.searchQuery).toBe('test');
	});

	it('setViewMode changes the view', () => {
		state.viewMode = 'grid';
		expect(state.viewMode).toBe('grid');
	});

	it('setSortBy changes sort', () => {
		state.sortBy = 'artist';
		expect(state.sortBy).toBe('artist');
	});

	it('loadTracks passes sortBy to SQL and keeps returned order', async () => {
		mockInvoke.mockResolvedValueOnce([mockTrack2, mockTrack, mockTrack3]);
		state.sortBy = 'title';
		await state.loadTracks();
		// 排序由 SQL 端完成（get_tracks sortBy），前端不再自行重排
		expect(mockInvoke).toHaveBeenCalledWith('get_tracks', { limit: 50000, offset: 0, sortBy: 'title' });
		expect(state.tracks.map(t => t.title)).toEqual(['Beta', 'Alpha', 'Gamma']);
	});

	it('changing sortBy on a loaded list reloads from SQL', async () => {
		mockInvoke.mockResolvedValueOnce([mockTrack2]);
		await state.loadTracks();
		mockInvoke.mockResolvedValueOnce([mockTrack, mockTrack3]);
		state.sortBy = 'artist';
		// setter 触发的 reload 是 fire-and-forget 异步，等一轮微任务+宏任务
		await new Promise((r) => setTimeout(r, 10));
		expect(mockInvoke).toHaveBeenLastCalledWith('get_tracks', { limit: 50000, offset: 0, sortBy: 'artist' });
		expect(state.trackCount).toBe(2);
	});

	it('loadTracks calls invoke get_tracks and updates state', async () => {
		mockInvoke.mockResolvedValueOnce([mockTrack, mockTrack2, mockTrack3]);
		const tracks = await state.loadTracks(100, 0);
		expect(mockInvoke).toHaveBeenCalledWith('get_tracks', { limit: 100, offset: 0, sortBy: 'title' });
		expect(tracks).toHaveLength(3);
		expect(state.trackCount).toBe(3);
	});

	it('loadTracks returns empty on error', async () => {
		mockInvoke.mockRejectedValueOnce(new Error('fail'));
		const tracks = await state.loadTracks();
		expect(tracks).toEqual([]);
		expect(state.loading).toBe(false);
	});

	it('search calls invoke search_tracks', async () => {
		mockInvoke.mockResolvedValueOnce([mockTrack]);
		const results = await state.search('Alpha');
		expect(mockInvoke).toHaveBeenCalledWith('search_tracks', { keyword: 'Alpha', limit: 50, offset: 0 });
		expect(results).toHaveLength(1);
	});

	it('search returns empty for empty query', async () => {
		const results = await state.search('');
		expect(results).toEqual([]);
		expect(mockInvoke).not.toHaveBeenCalled();
	});

	it('loadArtists calls invoke get_artists', async () => {
		mockInvoke.mockResolvedValueOnce(['Alice', 'Bob']);
		const artists = await state.loadArtists();
		expect(artists).toEqual(['Alice', 'Bob']);
	});

	it('loadAlbumsByArtist calls invoke', async () => {
		mockInvoke.mockResolvedValueOnce(['First']);
		const albums = await state.loadAlbumsByArtist('Alice');
		expect(albums).toEqual(['First']);
	});

	it('loadTracksByAlbum calls invoke', async () => {
		mockInvoke.mockResolvedValueOnce([mockTrack]);
		const tracks = await state.loadTracksByAlbum('Alice', 'First');
		expect(tracks).toHaveLength(1);
	});

	it('loadAllAlbums calls invoke', async () => {
		mockInvoke.mockResolvedValueOnce([{ artist: 'Zed', album: 'First', first_track_id: 1, first_track_path: '/a.mp3', year: 2024 }]);
		const albums = await state.loadAllAlbums();
		expect(albums).toHaveLength(1);
	});

	it('deleteTrack calls invoke and removes from local state', async () => {
		mockInvoke.mockResolvedValueOnce([mockTrack, mockTrack2]);
		await state.loadTracks();
		mockInvoke.mockResolvedValueOnce(undefined);
		await state.deleteTrack(1);
		expect(mockInvoke).toHaveBeenCalledWith('delete_track', { trackId: 1 });
		expect(state.trackCount).toBe(1);
	});

	it('clearTracks resets the list', async () => {
		mockInvoke.mockResolvedValueOnce([mockTrack]);
		await state.loadTracks();
		state.clearTracks();
		expect(state.trackCount).toBe(0);
	});

	it('scanDirectory delegates to loader and reloads tracks', async () => {
		mockInvoke.mockResolvedValueOnce([mockTrack]);
		mockLoader.scanDirectory.mockResolvedValueOnce(undefined);
		await state.scanDirectory();
		expect(mockLoader.scanDirectory).toHaveBeenCalledOnce();
		expect(mockInvoke).toHaveBeenCalledWith('get_tracks', { limit: 50000, offset: 0, sortBy: 'title' });
	});

	it('importPlaylist delegates to loader', async () => {
		mockLoader.importPlaylist.mockResolvedValueOnce(['/music/playlist.m3u']);
		const result = await state.importPlaylist();
		expect(mockLoader.importPlaylist).toHaveBeenCalledOnce();
		expect(result).toEqual(['/music/playlist.m3u']);
	});

	it('getScanFolders delegates to loader', async () => {
		mockLoader.getScanFolders.mockResolvedValueOnce(['/music', '/audio']);
		const result = await state.getScanFolders();
		expect(mockLoader.getScanFolders).toHaveBeenCalledOnce();
		expect(result).toEqual(['/music', '/audio']);
	});

	it('removeScanFolder delegates to loader', async () => {
		mockLoader.removeScanFolder.mockResolvedValueOnce(1);
		const result = await state.removeScanFolder('/music');
		expect(mockLoader.removeScanFolder).toHaveBeenCalledWith('/music');
		expect(result).toBe(1);
	});
});
