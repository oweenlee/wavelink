import { describe, it, expect, vi, beforeEach } from 'vitest';
import type { Track } from '$lib/audio/types';

const mockTrack: Track = {
	id: 1, path: '/music/song.mp3', title: 'Hello', artist: 'World',
	album: 'Album', album_artist: null, track_number: 1, disc_number: 1,
	year: 2024, genre: 'Pop', duration: 200, sample_rate: 44100,
	channels: 2, format: 'mp3', file_size: 1000, file_modified: null,
	date_added: 1000, play_count: 0, last_played: null, rating: 0,
	missing: false,
};

const mockTrackNoTitle: Track = {
	...mockTrack, id: 2, path: '/music/inst.mp3', title: '', artist: '',
};

// ---- mocks ----
vi.mock('$app/environment', () => ({ browser: true }));

const mockInvoke = vi.hoisted(() => vi.fn());
vi.mock('@tauri-apps/api/core', () => ({ invoke: mockInvoke }));

// engine mock for playback store (used by lyrics store)
const mockEngine = vi.hoisted(() => ({
	currentTrack: null,
	isPlaying: false,
	currentTime: 0,
	duration: 200,
	volume: 1.0,
	loading: false,
}));

const mockEngineFn = vi.hoisted(() => ({
	getEngineRef: vi.fn(() => ({
		get currentTrack() { return mockEngine.currentTrack; },
		get isPlaying() { return mockEngine.isPlaying; },
		get currentTime() { return mockEngine.currentTime; },
		get duration() { return mockEngine.duration; },
		get volume() { return mockEngine.volume; },
		get loading() { return mockEngine.loading; },
	})),
	setOnEnded: vi.fn(),
	setOnTrackChanged: vi.fn(),
	playTrack: vi.fn(),
	pause: vi.fn(),
	resume: vi.fn(),
	togglePlay: vi.fn(),
	seek: vi.fn(),
	setVolume: vi.fn(),
	stop: vi.fn(),
	nextTrack: vi.fn(),
	destroy: vi.fn(),
}));

vi.mock('$lib/audio/engine.svelte', () => ({
	getEngineRef: mockEngineFn.getEngineRef,
	setOnEnded: mockEngineFn.setOnEnded,
	setOnTrackChanged: mockEngineFn.setOnTrackChanged,
	playTrack: mockEngineFn.playTrack,
	pause: mockEngineFn.pause,
	resume: mockEngineFn.resume,
	togglePlay: mockEngineFn.togglePlay,
	seek: mockEngineFn.seek,
	setVolume: mockEngineFn.setVolume,
	stop: mockEngineFn.stop,
	nextTrack: mockEngineFn.nextTrack,
	destroy: mockEngineFn.destroy,
}));

describe('getLyricsState', () => {
	beforeEach(() => {
		vi.clearAllMocks();
	});

	it('starts with empty lines', async () => {
		const { getLyricsState } = await import('$lib/stores/lyrics.svelte');
		const state = getLyricsState();
		expect(state.lines).toEqual([]);
		expect(state.loading).toBe(false);
		expect(state.error).toBe('');
		expect(state.currentIndex).toBe(-1);
	});

	it('loadForTrack(null) clears state', async () => {
		const { getLyricsState, loadForTrack } = await import('$lib/stores/lyrics.svelte');
		const state = getLyricsState();
		loadForTrack(null);
		expect(state.lines).toEqual([]);
		expect(state.error).toBe('');
	});

	it('loadForTrack reads .lrc file from disk', async () => {
		const { getLyricsState, loadForTrack } = await import('$lib/stores/lyrics.svelte');
		const state = getLyricsState();
		mockInvoke.mockResolvedValueOnce('[00:10.00]Line 1\n[00:20.00]Line 2');
		loadForTrack(mockTrack);
		await vi.waitFor(() => {
			expect(state.lines.length).toBeGreaterThan(0);
		});
		expect(state.lines[0].text).toBe('Line 1');
		expect(state.error).toBe('');
		expect(state.loading).toBe(false);
	});

	it('loadForTrack sets error when .lrc file not found', async () => {
		const { getLyricsState, loadForTrack } = await import('$lib/stores/lyrics.svelte');
		const state = getLyricsState();
		mockInvoke.mockRejectedValueOnce(new Error('not found'));
		loadForTrack(mockTrack);
		await vi.waitFor(() => {
			expect(state.error).toBe('暂无歌词');
		});
		expect(state.loading).toBe(false);
	});

	it('currentIndex is -1 when no lines', async () => {
		const { getLyricsState } = await import('$lib/stores/lyrics.svelte');
		const state = getLyricsState();
		expect(state.currentIndex).toBe(-1);
	});

	it('progress returns 0 when no lines', async () => {
		const { getLyricsState } = await import('$lib/stores/lyrics.svelte');
		const state = getLyricsState();
		expect(state.progress()).toBe(0);
	});
});
