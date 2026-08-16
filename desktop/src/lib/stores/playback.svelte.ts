import {
	getEngineRef,
	setOnEnded,
	setOnTrackChanged,
	playQueue as enginePlayQueue,
	pause,
	resume,
	togglePlay as engineToggle,
	seek,
	setVolume,
	nextTrack as engineNext,
	prevTrack as enginePrev,
	setSpeed as engineSetSpeed,
	startCapture as engineStartCapture,
	stopCapture as engineStopCapture,
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
const _engine = getEngineRef();

// 引擎自带队列并自行切歌（audio-core advance_queue 按 play_mode 推进），
// player:stopped 只在队列真正播完时发出，此时无需前端再自动切歌。
// 切歌 / 循环 / 随机全权由引擎负责，前端仅通过 track_changed 镜像索引。
setOnEnded(() => {
	// 自然播放结束：引擎已无当前曲目，前端索引也要复位，否则底部栏还显示最后一首
	getPlaylistState().setIndex(-1);
});

// Wire up engine's track_changed → sync playlist index
setOnTrackChanged((path: string) => {
	const pl = getPlaylistState();
	const idx = pl.queue.findIndex(t => t.path === path);
	if (idx !== -1 && idx !== pl.currentIndex) {
		pl.setIndex(idx);
	}
});

// 曲库里的 STRM http(s) URL 轨道：引擎只接受本地路径，播放前先把远端
// 下载到缓存（Rust 侧 strm_fetch 命令，纯下载不触发播放）并替换为本地路径。
// 下载失败的单条从队列剔除（保持剩余曲目可正常播放）。
// 限流并发下载：队列含大量 URL 时避免逐个串行阻塞，同时控制并发数。
async function resolveRemoteTracks(tracks: Track[]): Promise<Track[]> {
	const isUrl = (t: Track) => t.path.startsWith('http://') || t.path.startsWith('https://');
	if (!tracks.some(isUrl)) return tracks;
	const { invoke } = await import('@tauri-apps/api/core');

	// 并发窗口：最多同时下载 4 条，避免占用过多连接/带宽。
	// 先按 path 去重：队列里同一 URL 出现多次时只下载一次，避免并发写同一缓存文件。
	const CONCURRENCY = 4;
	const urlTracks = [
		...new Map(tracks.filter(isUrl).map((t) => [t.path, t] as [string, Track])).values()
	];
	const results = new Map<string, string>();
	let cursor = 0;

	async function worker() {
		while (cursor < urlTracks.length) {
			const t = urlTracks[cursor++];
			try {
				const local = await invoke<string>('strm_fetch', { url: t.path, name: t.title || t.path });
				results.set(t.path, local);
			} catch (e) {
				console.warn('[playback] STRM URL 下载失败，跳过:', t.path, e);
			}
		}
	}

	const workers = Array.from({ length: Math.min(CONCURRENCY, urlTracks.length) }, () => worker());
	await Promise.all(workers);

	const out: Track[] = [];
	for (const t of tracks) {
		if (!isUrl(t)) { out.push(t); continue; }
		const local = results.get(t.path);
		if (local) out.push({ ...t, path: local });
	}
	return out;
}

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

		get speed() { return _engine.speed; },
		get levels() { return _engine.levels; },
		get capturing() { return _engine.capturing; },

		// ── Playback controls ──
		togglePlay() {
			const pl = getPlaylistState();
			if (pl.currentIndex < 0 && pl.queue.length > 0) {
				this.playFromQueue(0);
			} else {
				engineToggle();
			}
		},

		// 单曲播放（搜索结果等独立上下文）：作为单条队列播放。
		// 走 play_queue(set_queue) 路径会重置引擎队列，避免接上旧队列残留。
		// URL 轨道先解析为本地缓存路径再交给引擎（引擎只吃本地路径）。
		async playTrack(track: Track) {
			const pl = getPlaylistState();
			const resolved = await resolveRemoteTracks([track]);
			if (resolved.length === 0) return;
			pl.setQueue(resolved);
			pl.setIndex(0);
			await enginePlayQueue(resolved);
		},

		// 在当前队列内跳转：以该索引重新轮转队列后整体交给引擎。
		async playFromQueue(index: number) {
			const pl = getPlaylistState();
			if (index >= 0 && index < pl.queue.length) {
				await this.playAllAsQueue(pl.queue, index);
			}
		},

		// 队列播放：把【完整队列轮转】后整体交给引擎，startIndex 置顶。
		// 引擎持有完整 original_queue → RepeatAll/Shuffle 可达全部曲目（修复 slice 截断 bug）；
		// 引擎自行切歌并预缓冲下一曲（gapless 生效）；前端队列与引擎保持一致。
		async playAllAsQueue(tracks: Track[], startIndex = 0) {
			const pl = getPlaylistState();
			if (tracks.length === 0) return;
			const idx = Math.min(Math.max(startIndex, 0), tracks.length - 1);
			const rotated = [...tracks.slice(idx), ...tracks.slice(0, idx)];
			if (rotated.some((t) => t.path.startsWith('http://') || t.path.startsWith('https://'))) {
				// URL 队列：先解析为本地缓存再一次性交给引擎；解析失败的单条会被剔除，
				// 全部失败则保持旧队列/旧播放状态不变，避免清空队列后引擎还在播旧曲目。
				const resolved = await resolveRemoteTracks(rotated);
				if (resolved.length === 0) return;
				pl.setQueue(resolved);
				pl.setIndex(0);
				await enginePlayQueue(resolved);
			} else {
				// 保持原有同步语义：先置位队列/索引（无 URL 时不额外异步下载，
				// 避免 togglePlay 等同步入口读到过期索引）
				pl.setQueue(rotated);
				pl.setIndex(0);
				await enginePlayQueue(rotated);
			}
		},

		// 下一首 / 上一首委托引擎：引擎按 play_mode 推进并维护播放历史
		// （prev_track 自带“>3s 回开头否则切上一曲”逻辑）。
		async next() {
			await engineNext();
		},

		async prev() {
			await enginePrev();
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

		async setSpeed(speed: number) {
			await engineSetSpeed(speed);
		},

		async startCapture(sampleRate = 44100, channels = 2) {
			await engineStartCapture(sampleRate, channels);
		},

		async stopCapture() {
			await engineStopCapture();
		},
	};
}

export type PlaybackState = ReturnType<typeof getPlaybackState>;
