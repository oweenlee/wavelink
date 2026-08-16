import { describe, it, expect, beforeEach } from 'vitest';
import type { Track } from '$lib/audio/types';

const mockTrack: Track = {
	id: 1, path: '/music/song.mp3', title: 'Song', artist: 'Artist',
	album: 'Album', album_artist: null, track_number: 1, disc_number: 1,
	year: 2024, genre: 'Pop', duration: 200, sample_rate: 44100,
	channels: 2, format: 'mp3', file_size: 1000, file_modified: null,
	date_added: 1000, play_count: 0, last_played: null, rating: 0,
	missing: false,
};

const mockTrack2: Track = { ...mockTrack, id: 2, path: '/music/song2.mp3', title: 'Song2' };

// ---- tests ----
describe('getPlaylistState', () => {
	let state: ReturnType<typeof import('$lib/stores/playlist.svelte')['getPlaylistState']>;

	beforeEach(async () => {
		const mod = await import('$lib/stores/playlist.svelte');
		state = mod.getPlaylistState();
		state.setQueue([]);
	});

	it('starts with empty queue and no current index', () => {
		expect(state.queue).toEqual([]);
		expect(state.currentIndex).toBe(-1);
		expect(state.currentTrack).toBeNull();
		expect(state.hasTracks).toBe(false);
	});

	it('setQueue replaces the queue and resets index', () => {
		state.setQueue([mockTrack, mockTrack2]);
		expect(state.queue).toHaveLength(2);
		expect(state.currentIndex).toBe(-1);
	});

	it('setIndex updates current index', () => {
		state.setQueue([mockTrack, mockTrack2]);
		state.setIndex(1);
		expect(state.currentIndex).toBe(1);
		expect(state.currentTrack?.id).toBe(2);
	});
});