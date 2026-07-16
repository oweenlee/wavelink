import { describe, it, expect, vi, beforeEach } from 'vitest';
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
const mockTrack3: Track = { ...mockTrack, id: 3, path: '/music/song3.mp3', title: 'Song3' };

// ---- mocks ----
const mockEngineFn = vi.hoisted(() => ({
	playTrack: vi.fn(),
	getEngineRef: vi.fn(() => ({})),
}));

vi.mock('$lib/audio/engine.svelte', () => ({
	playTrack: mockEngineFn.playTrack,
	getEngineRef: mockEngineFn.getEngineRef,
}));

vi.mock('$app/environment', () => ({ browser: true }));

// ---- tests ----
describe('getPlaylistState', () => {
	let state: ReturnType<typeof import('$lib/stores/playlist.svelte')['getPlaylistState']>;

	beforeEach(async () => {
		vi.clearAllMocks();
		mockEngineFn.playTrack.mockReset();
		const mod = await import('$lib/stores/playlist.svelte');
		state = mod.getPlaylistState();
		state.clearQueue();
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

	it('addToQueue appends a track', () => {
		state.addToQueue(mockTrack);
		expect(state.queue).toHaveLength(1);
		state.addToQueue(mockTrack2);
		expect(state.queue).toHaveLength(2);
	});

	it('removeFromQueue removes track and adjusts index', () => {
		state.setQueue([mockTrack, mockTrack2, mockTrack3]);
		state.setIndex(2);
		state.removeFromQueue(2);
		expect(state.queue).toHaveLength(2);
		expect(state.currentIndex).toBe(-1); // was current
	});

	it('removeFromQueue shifts index down when removing before current', () => {
		state.setQueue([mockTrack, mockTrack2, mockTrack3]);
		state.setIndex(2);
		state.removeFromQueue(0);
		expect(state.currentIndex).toBe(1);
	});

	it('removeFromQueue does nothing for invalid index', () => {
		state.setQueue([mockTrack]);
		state.removeFromQueue(5);
		expect(state.queue).toHaveLength(1);
	});

	it('reorderQueue moves a track and adjusts currentIndex', () => {
		state.setQueue([mockTrack, mockTrack2, mockTrack3]);
		state.setIndex(0);
		state.reorderQueue(0, 2);
		expect(state.queue[2].id).toBe(1);
		expect(state.currentIndex).toBe(2);
	});

	it('reorderQueue does nothing for invalid indices', () => {
		state.setQueue([mockTrack, mockTrack2]);
		state.reorderQueue(-1, 2);
		expect(state.queue).toHaveLength(2);
	});

	it('clearQueue empties queue and resets index', () => {
		state.setQueue([mockTrack, mockTrack2]);
		state.setIndex(0);
		state.clearQueue();
		expect(state.queue).toEqual([]);
		expect(state.currentIndex).toBe(-1);
	});

	it('playFromIndex sets index and calls enginePlay', async () => {
		state.setQueue([mockTrack, mockTrack2]);
		await state.playFromIndex(1);
		expect(state.currentIndex).toBe(1);
		expect(mockEngineFn.playTrack).toHaveBeenCalledWith(mockTrack2);
	});

	it('playFromIndex does nothing for out-of-range index', async () => {
		await state.playFromIndex(5);
		expect(mockEngineFn.playTrack).not.toHaveBeenCalled();
	});
});
