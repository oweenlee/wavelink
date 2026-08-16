import type { Track } from '$lib/audio/types';

/**
 * Playlist store — 前端队列镜像。
 * 队列的唯一真源是引擎队列（core）：前端通过 setQueue 写入镜像，
 * 索引由 track_changed / queue_changed 事件驱动。
 * 本地增删改（addToQueue/removeFromQueue/reorderQueue/clearQueue）已移除——
 * 之前只改前端副本、不同步引擎，是队列双状态漂移的源头之一。
 * 如将来需要 UI 级队列编辑，应新增引擎命令（按唯一键移除 + emit_queue）
 * 并让前端只做投影，而不是恢复本地增删改。
 */

let _queue = $state<Track[]>([]);
let _currentIndex = $state(-1);

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

		// ── Queue mirror ──
		setQueue(tracks: Track[]) {
			_queue = [...tracks];
			_currentIndex = -1;
		},

		setIndex(index: number) {
			_currentIndex = index;
		},
	};
}

export type PlaylistState = ReturnType<typeof getPlaylistState>;