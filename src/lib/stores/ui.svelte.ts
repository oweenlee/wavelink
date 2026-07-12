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
let _showDesktopLyrics = $state(false);

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

		get showDesktopLyrics() { return _showDesktopLyrics; },
		set showDesktopLyrics(v: boolean) { _showDesktopLyrics = v; },

		// ── Helpers ──
		navigateTo(v: ViewName) { _view = v; },
		toggleLyrics() { _showLyricsPanel = !_showLyricsPanel; },
		toggleNowPlaying() { _showNowPlaying = !_showNowPlaying; },
		toggleSearch() { _showSearch = !_showSearch; },
		togglePlaylistPanel() { _showPlaylistPanel = !_showPlaylistPanel; },
		async toggleDesktopLyrics() {
			_showDesktopLyrics = !_showDesktopLyrics;
			if (typeof window !== 'undefined') {
				const { WebviewWindow } = await import('@tauri-apps/api/webviewWindow');
				const win = await WebviewWindow.getByLabel('lyrics');
				if (_showDesktopLyrics) {
					await win?.show();
				} else {
					await win?.hide();
				}
			}
		},
	};
}

export type UiState = ReturnType<typeof getUiState>;
