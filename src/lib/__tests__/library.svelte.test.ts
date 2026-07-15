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
vi.mock('$lib/audio/loader', () => ({
	scanDirectory: vi.fn(),
}));

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

	it('sorts tracks by title', async () => {
		mockInvoke.mockResolvedValueOnce([mockTrack2, mockTrack, mockTrack3]);
		state.sortBy = 'title';
		await state.loadTracks();
		const sorted = state.tracks;
		expect(sorted[0].title).toBe('Alpha');
		expect(sorted[1].title).toBe('Beta');
		expect(sorted[2].title).toBe('Gamma');
	});

	it('sorts tracks by artist', async () => {
		mockInvoke.mockResolvedValueOnce([mockTrack, mockTrack2, mockTrack3]);
		state.sortBy = 'artist';
		await state.loadTracks();
		const sorted = state.tracks;
		expect(sorted[0].artist).toBe('Alice');
		expect(sorted[1].artist).toBe('Bob');
		expect(sorted[2].artist).toBe('Zed');
	});

	it('sorts tracks by album', async () => {
		mockInvoke.mockResolvedValueOnce([mockTrack2, mockTrack, mockTrack3]);
		state.sortBy = 'album';
		await state.loadTracks();
		const sorted = state.tracks;
		expect(sorted[0].album).toBe('First');
		expect(sorted[1].album).toBe('First');
		expect(sorted[2].album).toBe('Second');
	});

	it('sorts tracks by duration', async () => {
		mockInvoke.mockResolvedValueOnce([mockTrack, mockTrack3, mockTrack2]);
		state.sortBy = 'duration';
		await state.loadTracks();
		const sorted = state.tracks;
		expect(sorted[0].duration).toBe(100);
		expect(sorted[1].duration).toBe(200);
		expect(sorted[2].duration).toBe(300);
	});

	it('loadTracks calls invoke get_tracks and updates state', async () => {
		mockInvoke.mockResolvedValueOnce([mockTrack, mockTrack2, mockTrack3]);
		const tracks = await state.loadTracks(100, 0);
		expect(mockInvoke).toHaveBeenCalledWith('get_tracks', { limit: 100, offset: 0 });
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
});
