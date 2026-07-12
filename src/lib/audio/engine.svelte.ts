import { browser } from '$app/environment';
import type { Track } from './types';

/**
 * Tauri 音频引擎桥接层
 * 通过 invoke 调用 Rust 后端，通过 listen 接收引擎事件
 *
 * 注意：所有 Tauri API 只在 browser 端执行（SSR 安全）
 */

let _currentTrack = $state<Track | null>(null);
let _isPlaying = $state(false);
let _currentTime = $state(0);
let _duration = $state(0);
let _volume = $state(1.0);
let _loading = $state(false);

// 事件回调
let _onEnded: (() => void) | null = null;
let _onTrackChanged: ((path: string) => void) | null = null;

// 延迟初始化标志
let _initialized = false;

// 防回弹：seek 后忽略过期的 position 事件
let _lastSeekTime = 0;
let _lastSeekTarget = 0;

/** 在浏览器端初始化 Tauri 事件监听 */
async function ensureListeners() {
	if (_initialized || !browser) return;

	const { listen } = await import('@tauri-apps/api/event');

	await Promise.all([
		listen<number>('player:position', (event) => {
			const now = Date.now();
			if (now - _lastSeekTime < 500 && event.payload < _lastSeekTarget - 1.0) return;
			_currentTime = event.payload;
		}),
		listen<number>('player:duration', (event) => {
			_duration = event.payload;
		}),
		listen('player:stopped', () => {
			_isPlaying = false;
			_currentTime = 0;
			if (_onEnded) _onEnded();
		}),
		listen<string>('player:track_changed', (event) => {
			_isPlaying = true;
			_loading = false;
			if (_onTrackChanged) _onTrackChanged(event.payload);
		}),
		listen<string>('player:error', (event) => {
			console.error('Playback error:', event.payload);
			_isPlaying = false;
			_loading = false;
		}),
	]);

_initialized = true;
}

/** 只读 reactive getters */
export function getEngineRef() {
	// 首次调用时异步初始化（在浏览器端）
	if (!_initialized && browser) {
		ensureListeners();
	}

	return {
		get currentTrack() { return _currentTrack; },
		get isPlaying() { return _isPlaying; },
		get currentTime() { return _currentTime; },
		get duration() { return _duration; },
		get volume() { return _volume; },
		get loading() { return _loading; },
	};
}

export function setOnEnded(cb: () => void) {
	_onEnded = cb;
}

export function setOnTrackChanged(cb: (path: string) => void) {
	_onTrackChanged = cb;
}

export async function playTrack(track: Track) {
	await ensureListeners();
	_currentTrack = track;
	_currentTime = 0;
	_duration = 0;
	_loading = true;
	try {
		const { invoke } = await import('@tauri-apps/api/core');
		await invoke('play', { path: track.path });
		_isPlaying = true;
	} catch (err) {
		console.error('Play failed:', err);
		_loading = false;
	}
}

export async function playQueue(tracks: Track[]) {
	await ensureListeners();
	if (tracks.length === 0) return;
	_currentTrack = tracks[0];
	_currentTime = 0;
	_duration = 0;
	_loading = true;
	try {
		const { invoke } = await import('@tauri-apps/api/core');
		const paths = tracks.map(t => t.path);
		await invoke('play_queue', { paths });
		_isPlaying = true;
	} catch (err) {
		console.error('Play queue failed:', err);
		_loading = false;
	}
}

export async function pause() {
	try {
		const { invoke } = await import('@tauri-apps/api/core');
		await invoke('pause');
		_isPlaying = false;
	} catch (err) {
		console.error('Pause failed:', err);
	}
}

export async function resume() {
	try {
		const { invoke } = await import('@tauri-apps/api/core');
		await invoke('resume');
		_isPlaying = true;
	} catch (err) {
		console.error('Resume failed:', err);
	}
}

export async function togglePlay() {
	if (_isPlaying) await pause();
	else await resume();
}

export async function seek(time: number) {
	// 先立即更新，避免键盘连按计算陈旧值
	_currentTime = time;
	_lastSeekTime = Date.now();
	_lastSeekTarget = time;
	try {
		const { invoke } = await import('@tauri-apps/api/core');
		await invoke('seek', { pos: time });
	} catch (err) {
		console.error('Seek failed:', err);
	}
}

export async function setVolume(v: number) {
	_volume = v;
	try {
		const { invoke } = await import('@tauri-apps/api/core');
		await invoke('set_volume', { vol: v });
	} catch (err) {
		console.error('Set volume failed:', err);
	}
}

export async function stop() {
	try {
		const { invoke } = await import('@tauri-apps/api/core');
		await invoke('stop');
	} catch (err) {
		console.error('Stop failed:', err);
	}
	_currentTime = 0;
	_isPlaying = false;
	_currentTrack = null;
}

export async function nextTrack() {
	try {
		const { invoke } = await import('@tauri-apps/api/core');
		await invoke('next_track');
	} catch (err) {
		console.error('Next track failed:', err);
	}
}

export function destroy() {
	stop();
	_currentTrack = null;
	_isPlaying = false;
	_currentTime = 0;
	_duration = 0;
}
