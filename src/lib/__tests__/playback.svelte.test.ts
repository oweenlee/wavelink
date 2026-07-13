import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import type { Track } from '$lib/audio/types';
import type { PlayMode } from '$lib/stores/playback.svelte';

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
const mockEngine = vi.hoisted(() => ({
	currentTrack: null as Track | null,
	isPlaying: false,
	currentTime: 0,
	duration: 0,
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
	playQueue: vi.fn(),
	pause: vi.fn(() => { mockEngine.isPlaying = false; }),
	resume: vi.fn(() => { mockEngine.isPlaying = true; }),
	togglePlay: vi.fn(() => { mockEngine.isPlaying = !mockEngine.isPlaying; }),
	seek: vi.fn((t: number) => { mockEngine.currentTime = t; }),
	setVolume: vi.fn((v: number) => { mockEngine.volume = v; }),
	stop: vi.fn(() => { mockEngine.isPlaying = false; mockEngine.currentTrack = null; }),
	nextTrack: vi.fn(),
	destroy: vi.fn(),
}));

vi.mock('$lib/audio/engine.svelte', () => ({
	getEngineRef: mockEngineFn.getEngineRef,
	setOnEnded: mockEngineFn.setOnEnded,
	setOnTrackChanged: mockEngineFn.setOnTrackChanged,
	playTrack: mockEngineFn.playTrack,
	playQueue: mockEngineFn.playQueue,
	pause: mockEngineFn.pause,
	resume: mockEngineFn.resume,
	togglePlay: mockEngineFn.togglePlay,
	seek: mockEngineFn.seek,
	setVolume: mockEngineFn.setVolume,
	stop: mockEngineFn.stop,
	nextTrack: mockEngineFn.nextTrack,
	destroy: mockEngineFn.destroy,
}));

vi.mock('$app/environment', () => ({ browser: true }));

const mockInvoke = vi.hoisted(() => vi.fn());
vi.mock('@tauri-apps/api/core', () => ({ invoke: mockInvoke }));

describe('getPlaybackState', () => {
	let state: ReturnType<typeof import('$lib/stores/playback.svelte')['getPlaybackState']>;
	let playlist: ReturnType<typeof import('$lib/stores/playlist.svelte')['getPlaylistState']>;

	beforeEach(async () => {
		vi.clearAllMocks();
		// 重置 engine 状态
		mockEngine.currentTrack = null;
		mockEngine.isPlaying = false;
		mockEngine.currentTime = 0;
		mockEngine.duration = 0;
		mockEngine.volume = 1.0;
		mockEngine.loading = false;

		// 重新 import 获取干净 store 实例
		const pbMod = await import('$lib/stores/playback.svelte');
		const plMod = await import('$lib/stores/playlist.svelte');
		state = pbMod.getPlaybackState();
		playlist = plMod.getPlaylistState();
	});

	it('has default values', () => {
		expect(state.isPlaying).toBe(false);
		expect(state.currentTime).toBe(0);
		expect(state.duration).toBe(0);
		expect(state.volume).toBe(1.0);
		expect(state.loading).toBe(false);
		expect(state.playMode).toBe('normal');
		expect(state.hasTrack).toBe(false);
		expect(state.progress).toBe(0);
	});

	it('progress returns 0 when duration is 0', () => {
		expect(state.progress).toBe(0);
	});

	it('progress calculates correctly', () => {
		mockEngine.currentTime = 50;
		mockEngine.duration = 200;
		expect(state.progress).toBe(0.25);
	});

	it('togglePlay starts from queue index 0 when no current track', () => {
		playlist.setQueue([mockTrack]);
		state.togglePlay();
		expect(playlist.currentIndex).toBe(0);
		expect(mockEngineFn.playTrack).toHaveBeenCalledWith(mockTrack);
	});

	it('togglePlay calls engine toggle when track exists', () => {
		playlist.setQueue([mockTrack]);
		playlist.setIndex(0);
		mockEngine.currentTrack = mockTrack;
		state.togglePlay();
		expect(mockEngineFn.togglePlay).toHaveBeenCalledOnce();
	});

	it('playTrack plays from queue if track exists', async () => {
		playlist.setQueue([mockTrack, mockTrack2]);
		await state.playTrack(mockTrack2);
		expect(playlist.currentIndex).toBe(1);
		expect(mockEngineFn.playTrack).toHaveBeenCalledWith(mockTrack2);
	});

	it('playTrack adds to queue if not present', async () => {
		playlist.setQueue([mockTrack]);
		await state.playTrack(mockTrack2);
		expect(playlist.queue).toHaveLength(2);
		expect(playlist.currentIndex).toBe(1);
		expect(mockEngineFn.playTrack).toHaveBeenCalledWith(mockTrack2);
	});

	it('playFromQueue plays at specified index', async () => {
		playlist.setQueue([mockTrack, mockTrack2, mockTrack3]);
		await state.playFromQueue(2);
		expect(playlist.currentIndex).toBe(2);
		expect(mockEngineFn.playTrack).toHaveBeenCalledWith(mockTrack3);
	});

	it('playFromQueue ignores invalid index', async () => {
		await state.playFromQueue(-1);
		expect(mockEngineFn.playTrack).not.toHaveBeenCalled();
	});

	it('playAllAsQueue replaces queue and plays from start index', async () => {
		await state.playAllAsQueue([mockTrack, mockTrack2, mockTrack3], 1);
		expect(playlist.queue).toHaveLength(3);
		expect(playlist.currentIndex).toBe(1);
		expect(mockEngineFn.playQueue).toHaveBeenCalledWith([mockTrack2, mockTrack3]);
	});

	it('next advances within queue', async () => {
		playlist.setQueue([mockTrack, mockTrack2, mockTrack3]);
		playlist.setIndex(0);
		await state.next();
		expect(playlist.currentIndex).toBe(1);
		expect(mockEngineFn.playTrack).toHaveBeenCalledWith(mockTrack2);
	});

	it('next calls nextTrack at end of queue', async () => {
		playlist.setQueue([mockTrack]);
		playlist.setIndex(0);
		await state.next();
		expect(mockEngineFn.nextTrack).toHaveBeenCalledOnce();
	});

	it('prev seeks to 0 if currentTime > 3', async () => {
		mockEngine.currentTime = 10;
		playlist.setQueue([mockTrack, mockTrack2]);
		playlist.setIndex(1);
		await state.prev();
		expect(mockEngineFn.seek).toHaveBeenCalledWith(0);
		expect(playlist.currentIndex).toBe(1); // index unchanged
	});

	it('prev goes to previous track if currentTime <= 3', async () => {
		mockEngine.currentTime = 2;
		playlist.setQueue([mockTrack, mockTrack2]);
		playlist.setIndex(1);
		await state.prev();
		expect(playlist.currentIndex).toBe(0);
		expect(mockEngineFn.playTrack).toHaveBeenCalledWith(mockTrack);
	});

	it('stop calls engineStop and resets index', () => {
		playlist.setQueue([mockTrack]);
		playlist.setIndex(0);
		state.stop();
		expect(mockEngineFn.stop).toHaveBeenCalledOnce();
		expect(playlist.currentIndex).toBe(-1);
	});

	it('cycles playMode', () => {
		expect(state.cyclePlayMode()).toBe('repeat_all');
		expect(state.cyclePlayMode()).toBe('repeat_one');
		expect(state.cyclePlayMode()).toBe('shuffle');
		expect(state.cyclePlayMode()).toBe('normal');
	});

	it('setPlayMode updates mode and calls invoke', async () => {
		mockInvoke.mockResolvedValueOnce(undefined);
		await state.setPlayMode('shuffle');
		expect(state.playMode).toBe('shuffle');
		expect(mockInvoke).toHaveBeenCalledWith('set_play_mode', { mode: 'shuffle' });
	});

	it('setVolume calls engine setVolume', () => {
		state.volume = 0.5;
		expect(mockEngineFn.setVolume).toHaveBeenCalledWith(0.5);
	});

	it('currentTime setter calls seek', () => {
		state.currentTime = 42;
		expect(mockEngineFn.seek).toHaveBeenCalledWith(42);
	});
});
