import {
	getEngineRef,
	setOnEnded,
	setOnTrackChanged,
	playTrack as enginePlay,
	playQueue as enginePlayQueue,
	pause,
	resume,
	togglePlay as engineToggle,
	seek,
	setVolume,
	stop as engineStop,
} from '$lib/audio/engine.svelte';
import type { Track } from '$lib/audio/types';
import { browser } from '$app/environment';
import { getPlaylistState } from './playlist.svelte';

export type PlayMode = 'normal' | 'repeat_one' | 'repeat_all' | 'shuffle';

/**
 * Playback store — wraps the engine bridge and manages playback state.
 * Delegates queue management to playlist store.
 */

let _playMode = $state<PlayMode>('normal');
let _engine = getEngineRef();

// Wire up engine's onended → auto-advance queue
setOnEnded(() => {
	const pl = getPlaylistState();
	if (pl.queue.length === 0) return;

	switch (_playMode) {
		case 'repeat_one':
			if (pl.currentTrack) enginePlay(pl.currentTrack);
			break;
		case 'shuffle':
			pl.setIndex(Math.floor(Math.random() * pl.queue.length));
			if (pl.currentTrack) enginePlay(pl.currentTrack);
			break;
		case 'repeat_all':
			if (pl.currentIndex < pl.queue.length - 1) {
				pl.setIndex(pl.currentIndex + 1);
			} else {
				pl.setIndex(0);
			}
			if (pl.currentTrack) enginePlay(pl.currentTrack);
			break;
		default:
			if (pl.currentIndex < pl.queue.length - 1) {
				pl.setIndex(pl.currentIndex + 1);
				if (pl.currentTrack) enginePlay(pl.currentTrack);
			}
			break;
	}
});

// Wire up engine's track_changed → sync playlist index
setOnTrackChanged((path: string) => {
	const pl = getPlaylistState();
	const idx = pl.queue.findIndex(t => t.path === path);
	if (idx !== -1 && idx !== pl.currentIndex) {
		pl.setIndex(idx);
	}
});

export function getPlaybackState() {
	return {
		// ── Reactive getters ──
		get currentTrack(): Track | null { return getPlaylistState().currentTrack; },
		get isPlaying() { return _engine.isPlaying; },
		get currentTime() { return _engine.currentTime; },
		set currentTime(v: number) { seek(v); },
		get duration() { return _engine.duration; },
		get volume() { return _engine.volume; },
		set volume(v: number) { setVolume(v); },
		get loading() { return _engine.loading; },
		get playMode() { return _playMode; },
		set playMode(v: PlayMode) { _playMode = v; },

		get progress() {
			const d = _engine.duration;
			return d > 0 ? _engine.currentTime / d : 0;
		},

		get hasTrack() { return getPlaylistState().currentTrack !== null; },

		// ── Playback controls ──
		togglePlay() {
			const pl = getPlaylistState();
			if (pl.currentIndex < 0 && pl.queue.length > 0) {
				pl.setIndex(0);
				if (pl.currentTrack) enginePlay(pl.currentTrack);
			} else {
				engineToggle();
			}
		},

		async playTrack(track: Track) {
			const pl = getPlaylistState();
			const idx = pl.queue.findIndex(t => t.id === track.id);
			if (idx !== -1) {
				pl.setIndex(idx);
				await enginePlay(pl.queue[idx]);
			} else {
				pl.addToQueue(track);
				pl.setIndex(pl.queue.length - 1);
				await enginePlay(track);
			}
		},

		async playFromQueue(index: number) {
			const pl = getPlaylistState();
			if (index >= 0 && index < pl.queue.length) {
				pl.setIndex(index);
				await enginePlay(pl.queue[index]);
			}
		},

		async playAllAsQueue(tracks: Track[], startIndex = 0) {
			const pl = getPlaylistState();
			pl.setQueue(tracks);
			if (tracks.length > startIndex) {
				pl.setIndex(startIndex);
				await enginePlayQueue(tracks.slice(startIndex));
			}
		},

		async next() {
			const pl = getPlaylistState();
			if (pl.currentIndex < pl.queue.length - 1) {
				pl.setIndex(pl.currentIndex + 1);
				await enginePlay(pl.queue[pl.currentIndex]);
			} else {
				const { nextTrack } = await import('$lib/audio/engine.svelte');
				await nextTrack();
			}
		},

		async prev() {
			if (_engine.currentTime > 3) { seek(0); return; }
			const pl = getPlaylistState();
			if (pl.currentIndex > 0) {
				pl.setIndex(pl.currentIndex - 1);
				await enginePlay(pl.queue[pl.currentIndex]);
			}
		},

		stop() {
			engineStop();
			getPlaylistState().setIndex(-1);
		},

		// ── Play mode ──
		async setPlayMode(mode: PlayMode) {
			_playMode = mode;
			if (browser) {
				try {
					const { invoke } = await import('@tauri-apps/api/core');
					await invoke('set_play_mode', { mode });
				} catch { console.warn('[playback] 播放模式设置失败'); }
			}
		},

		cyclePlayMode(): PlayMode {
			const cycle: PlayMode[] = ['normal', 'repeat_all', 'repeat_one', 'shuffle'];
			const idx = cycle.indexOf(_playMode);
			const next = cycle[(idx + 1) % cycle.length];
			this.setPlayMode(next);
			return next;
		},
	};
}

export type PlaybackState = ReturnType<typeof getPlaybackState>;
