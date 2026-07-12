import {
	getEngineRef,
	playTrack as enginePlay,
} from '$lib/audio/engine.svelte';
import type { Track } from '$lib/audio/types';
import { browser } from '$app/environment';

/**
 * Playlist store — manages the play queue, current index, and saved playlists.
 * Calls enginePlay directly when playing from the queue.
 */

let _queue = $state<Track[]>([]);
let _currentIndex = $state(-1);
let _savedPlaylists = $state<string[]>([]);
let _engine = getEngineRef();

/** Lazy-load Tauri invoke (SSR safe) */
async function lazyInvoke() {
	const { invoke } = await import('@tauri-apps/api/core');
	return invoke;
}

export function getPlaylistState() {
	return {
		// ── State ──
		get queue() { return _queue; },
		get currentIndex() { return _currentIndex; },
		get currentTrack(): Track | null {
			return _currentIndex >= 0 && _currentIndex < _queue.length
				? _queue[_currentIndex]
				: null;
		},
		get savedPlaylists() { return _savedPlaylists; },
		get hasTracks() { return _queue.length > 0; },

		// ── Queue management ──
		setQueue(tracks: Track[]) {
			_queue = [...tracks];
			_currentIndex = -1;
		},

		setIndex(index: number) {
			_currentIndex = index;
		},

		addToQueue(track: Track) {
			_queue = [..._queue, track];
		},

		removeFromQueue(index: number) {
			if (index < 0 || index >= _queue.length) return;
			const wasCurrent = index === _currentIndex;
			_queue = _queue.filter((_, i) => i !== index);
			if (wasCurrent) {
				_currentIndex = -1;
			} else if (index < _currentIndex) {
				_currentIndex--;
			}
		},

		reorderQueue(from: number, to: number) {
			if (from < 0 || from >= _queue.length || to < 0 || to >= _queue.length) return;
			const newQueue = [..._queue];
			const [moved] = newQueue.splice(from, 1);
			newQueue.splice(to, 0, moved);
			_queue = newQueue;
			// Adjust currentIndex
			if (from === _currentIndex) {
				_currentIndex = to;
			} else if (from < _currentIndex && to >= _currentIndex) {
				_currentIndex--;
			} else if (from > _currentIndex && to <= _currentIndex) {
				_currentIndex++;
			}
		},

		clearQueue() {
			_queue = [];
			_currentIndex = -1;
		},

		// ── Saved playlists CRUD ──
		async loadPlaylistNames() {
			if (!browser) return;
			try {
				const invoke = await lazyInvoke();
				_savedPlaylists = await invoke('list_playlists') as string[];
			} catch (err) {
				console.error('Failed to load playlist names:', err);
			}
		},

		async saveCurrentAs(name: string) {
			if (!browser || _queue.length === 0) return;
			try {
				const invoke = await lazyInvoke();
				const paths = _queue.map(t => t.path);
				await invoke('save_playlist', { name, paths });
				await this.loadPlaylistNames();
			} catch (err) {
				console.error('Failed to save playlist:', err);
				throw err;
			}
		},

		async loadPlaylist(name: string) {
			if (!browser) return;
			try {
				const invoke = await lazyInvoke();
				const tracks: Track[] = await invoke('load_playlist', { name });
				_queue = tracks;
				_currentIndex = -1;
				return tracks;
			} catch (err) {
				console.error('Failed to load playlist:', err);
				return [];
			}
		},

		async deletePlaylist(name: string) {
			if (!browser) return;
			try {
				const invoke = await lazyInvoke();
				await invoke('delete_playlist', { name });
				await this.loadPlaylistNames();
			} catch (err) {
				console.error('Failed to delete playlist:', err);
				throw err;
			}
		},

		// ── Play from queue ──
		async playFromIndex(index: number) {
			if (index >= 0 && index < _queue.length) {
				_currentIndex = index;
				await enginePlay(_queue[index]);
			}
		},
	};
}

export type PlaylistState = ReturnType<typeof getPlaylistState>;
