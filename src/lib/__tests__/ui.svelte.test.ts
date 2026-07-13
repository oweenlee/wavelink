import { describe, it, expect, vi, beforeEach } from 'vitest';
import { getUiState } from '$lib/stores/ui.svelte';

// 按测试文件隔离，每次重新 import 获取干净状态
import { getUiState as getUiState2 } from '$lib/stores/ui.svelte';

describe('getUiState', () => {
	let state: ReturnType<typeof getUiState>;

	beforeEach(() => {
		state = getUiState();
	});

	it('defaults to library view', () => {
		expect(state.view).toBe('library');
	});

	it('navigates to different views', () => {
		state.navigateTo('settings');
		expect(state.view).toBe('settings');
		state.navigateTo('effects');
		expect(state.view).toBe('effects');
	});

	it('toggles lyrics panel', () => {
		expect(state.showLyricsPanel).toBe(false);
		state.toggleLyrics();
		expect(state.showLyricsPanel).toBe(true);
		state.toggleLyrics();
		expect(state.showLyricsPanel).toBe(false);
	});

	it('toggles now playing panel', () => {
		state.toggleNowPlaying();
		expect(state.showNowPlaying).toBe(true);
		state.toggleNowPlaying();
		expect(state.showNowPlaying).toBe(false);
	});

	it('toggles search', () => {
		state.toggleSearch();
		expect(state.showSearch).toBe(true);
		state.toggleSearch();
		expect(state.showSearch).toBe(false);
	});

	it('toggles playlist panel', () => {
		state.togglePlaylistPanel();
		expect(state.showPlaylistPanel).toBe(true);
		state.togglePlaylistPanel();
		expect(state.showPlaylistPanel).toBe(false);
	});

	it('sets showPlaylistPanel', () => {
		state.showPlaylistPanel = true;
		expect(state.showPlaylistPanel).toBe(true);
	});

	it('sets showSearch', () => {
		state.showSearch = true;
		expect(state.showSearch).toBe(true);
	});
});
