/**
 * UI store — manages navigation state and panel visibility.
 * Separated from playback/library/settings for single responsibility.
 */

export type ViewName = 'library' | 'effects' | 'settings';

let _view = $state<ViewName>('library');
let _showLyricsPanel = $state(false);
let _showNowPlaying = $state(false);
let _showSearch = $state(false);
let _showPlaylistPanel = $state(false);

export function getUiState() {
	return {
		// ── Navigation ──
		get view() { return _view; },
		set view(v: ViewName) { _view = v; },

		// ── Panel visibility ──
		get showLyricsPanel() { return _showLyricsPanel; },
		set showLyricsPanel(v: boolean) { _showLyricsPanel = v; },

		get showNowPlaying() { return _showNowPlaying; },
		set showNowPlaying(v: boolean) { _showNowPlaying = v; },

		get showSearch() { return _showSearch; },
		set showSearch(v: boolean) { _showSearch = v; },

		get showPlaylistPanel() { return _showPlaylistPanel; },
		set showPlaylistPanel(v: boolean) { _showPlaylistPanel = v; },

		// ── Helpers ──
		navigateTo(v: ViewName) { _view = v; },
		toggleLyrics() { _showLyricsPanel = !_showLyricsPanel; },
		toggleNowPlaying() { _showNowPlaying = !_showNowPlaying; },
		toggleSearch() { _showSearch = !_showSearch; },
		togglePlaylistPanel() { _showPlaylistPanel = !_showPlaylistPanel; },
	};
}

export type UiState = ReturnType<typeof getUiState>;
