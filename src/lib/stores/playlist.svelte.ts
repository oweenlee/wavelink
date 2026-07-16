import {
	getEngineRef,
	playTrack as enginePlay,
} from '$lib/audio/engine.svelte';
import type { Track } from '$lib/audio/types';

/**
 * Playlist store — manages the play queue and current index.
 * Calls enginePlay directly when playing from the queue.
 */

let _queue = $state<Track[]>([]);
let _currentIndex = $state(-1);
const _engine = getEngineRef();

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
