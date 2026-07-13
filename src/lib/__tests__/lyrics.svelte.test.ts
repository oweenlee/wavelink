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

// lyrics 模块使用了 $derived，只能在 import 后检查初始值
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
		// 等待异步完成
		await vi.waitFor(() => {
			expect(state.lines.length).toBeGreaterThan(0);
		});
		expect(state.lines[0].text).toBe('Line 1');
		expect(state.error).toBe('');
		expect(state.loading).toBe(false);
	});

	it('loadForTrack falls back to network lookup when no .lrc file', async () => {
		const { getLyricsState, loadForTrack } = await import('$lib/stores/lyrics.svelte');
		const state = getLyricsState();
		// 第一次 invoke 失败（读文件失败）
		mockInvoke.mockRejectedValueOnce(new Error('not found'));
		// 第二次 invoke 成功（查询歌词）
		mockInvoke.mockResolvedValueOnce('[00:05.00]Found lyric');
		// 第三次 invoke 成功（缓存歌词）
		mockInvoke.mockResolvedValueOnce(undefined);

		loadForTrack(mockTrack);
		await vi.waitFor(() => {
			expect(state.lines.length).toBe(1);
		});
		expect(state.lines[0].text).toBe('Found lyric');
	});

	it('loadForTrack shows error when no title/artist on lookup failure', async () => {
		const { getLyricsState, loadForTrack } = await import('$lib/stores/lyrics.svelte');
		const state = getLyricsState();
		mockInvoke.mockRejectedValueOnce(new Error('not found'));
		// 空 title 和 artist → 直接报错
		loadForTrack(mockTrackNoTitle);
		// 第一个 invoke 是读 .lrc 文件失败
		// 然后检查 title/artist 都为空 → 设置 _error = '无歌词'
		await vi.waitFor(() => {
			expect(state.error).toBe('无歌词');
		});
	});

	it('currentIndex tracks current time', async () => {
		const { getLyricsState, loadForTrack } = await import('$lib/stores/lyrics.svelte');
		const state = getLyricsState();
		mockInvoke.mockResolvedValueOnce('[00:10.00]First\n[00:20.00]Second\n[00:30.00]Third');
		loadForTrack(mockTrack);
		await vi.waitFor(() => {
			expect(state.lines.length).toBe(3);
		});
		// 初始 currentTime=0，应该在所有行之前 → index = -1
		expect(state.currentIndex).toBe(-1);
	});

	it('progress returns 0 when no lines', async () => {
		const { getLyricsState } = await import('$lib/stores/lyrics.svelte');
		const state = getLyricsState();
		expect(state.progress()).toBe(0);
	});
});
