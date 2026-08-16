import { browser, lazyInvoke, lazyListen } from '$lib/tauri';
import type { Track, PeqBand } from './types';

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
let _speed = $state(1.0);
let _loading = $state(false);

let _levels: { rms: number; peak: number; clip: boolean } | null = $state(null);
let _capturing = $state(false);

// 事件回调
let _onEnded: (() => void) | null = null;
let _onTrackChanged: ((path: string) => void) | null = null;
let _onQueueChanged: ((paths: string[], current: string) => void) | null = null;

// 延迟初始化标志
let _initialized = false;

// 防回弹：seek 后忽略过期的 position 事件
let _lastSeekTime = 0;
let _lastSeekTarget = 0;

/** 在浏览器端初始化 Tauri 事件监听 */
async function ensureListeners() {
	if (_initialized || !browser) return;

	const listen = await lazyListen();

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
		listen<{ paths: string[]; current: string }>('player:queue_changed', (event) => {
			if (_onQueueChanged) _onQueueChanged(event.payload.paths, event.payload.current);
		}),
		listen<{ rms: number; peak: number; clip: boolean }>('player:levels', (event) => {
			_levels = event.payload;
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
		get speed() { return _speed; },
		get levels() { return _levels; },
		get capturing() { return _capturing; },
	};
}

export function setOnEnded(cb: () => void) {
	_onEnded = cb;
}

export function setOnTrackChanged(cb: (path: string) => void) {
	_onTrackChanged = cb;
}

export function setOnQueueChanged(cb: (paths: string[], current: string) => void) {
	_onQueueChanged = cb;
}

export async function playTrack(track: Track) {
	await ensureListeners();
	_currentTrack = track;
	_currentTime = 0;
	_duration = 0;
	_loading = true;
	try {
		const invoke = await lazyInvoke();
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
		const invoke = await lazyInvoke();
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
		const invoke = await lazyInvoke();
		await invoke('pause');
		_isPlaying = false;
	} catch (err) {
		console.error('Pause failed:', err);
	}
}

export async function resume() {
	try {
		const invoke = await lazyInvoke();
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
		const invoke = await lazyInvoke();
		await invoke('seek', { pos: time });
	} catch (err) {
		console.error('Seek failed:', err);
	}
}

export async function setVolume(v: number) {
	_volume = v;
	try {
		const invoke = await lazyInvoke();
		await invoke('set_volume', { vol: v });
	} catch (err) {
		console.error('Set volume failed:', err);
	}
}

export async function stop() {
	try {
		const invoke = await lazyInvoke();
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
		const invoke = await lazyInvoke();
		await invoke('next_track');
	} catch (err) {
		console.error('Next track failed:', err);
	}
}

export async function prevTrack() {
	try {
		const invoke = await lazyInvoke();
		await invoke('prev_track');
	} catch (err) {
		console.error('Prev track failed:', err);
	}
}

export async function setSpeed(speed: number) {
	_speed = speed;
	try {
		const invoke = await lazyInvoke();
		await invoke('set_speed', { speed });
	} catch (err) {
		console.error('Set speed failed:', err);
	}
}

export async function startCapture(sampleRate = 44100, channels = 2) {
	try {
		const invoke = await lazyInvoke();
		await invoke('start_capture', { sampleRate, channels });
		_capturing = true;
	} catch (err) {
		console.error('Start capture failed:', err);
	}
}

export async function stopCapture() {
	try {
		const invoke = await lazyInvoke();
		await invoke('stop_capture');
	} catch (err) {
		console.error('Stop capture failed:', err);
	}
	_capturing = false;
}

// ── DSP 控制 ──

export async function setCrossfeed(enabled: boolean) {
	try {
		const invoke = await lazyInvoke();
		await invoke('set_crossfeed', { enabled });
	} catch (err) {
		console.error('Set crossfeed failed:', err);
	}
}

export async function setNoiseShaping(enabled: boolean) {
	try {
		const invoke = await lazyInvoke();
		await invoke('set_noise_shaping', { enabled });
	} catch (err) {
		console.error('Set noise shaping failed:', err);
	}
}

export async function setBufferMs(ms: number) {
	try {
		const invoke = await lazyInvoke();
		await invoke('set_buffer_ms', { ms });
	} catch (err) {
		console.error('Set buffer ms failed:', err);
	}
}

// ── AutoEQ / DSD / 限幅 / 抖动 / 输出采样率 ──

// ── EQ / 效果器 ──

export async function getEqBands(): Promise<PeqBand[]> {
	try {
		const invoke = await lazyInvoke();
		return await invoke<PeqBand[]>('get_eq_bands');
	} catch (err) {
		console.error('Get EQ bands failed:', err);
		return [];
	}
}

export async function setPeqBand(index: number, freq: number, gainDb: number, q: number) {
	try {
		const invoke = await lazyInvoke();
		await invoke('set_peq_band', { index, freq, gainDb, q });
	} catch (err) {
		console.error('Set PEQ band failed:', err);
	}
}

export async function setEqPreset(preset: string) {
	try {
		const invoke = await lazyInvoke();
		await invoke('set_eq_preset', { preset });
	} catch (err) {
		console.error('Set EQ preset failed:', err);
	}
}

export async function resetEq() {
	try {
		const invoke = await lazyInvoke();
		await invoke('reset_eq');
	} catch (err) {
		console.error('Reset EQ failed:', err);
	}
}

export async function listAutoEqProfiles(): Promise<string[]> {
	try {
		const invoke = await lazyInvoke();
		return await invoke<string[]>('list_auto_eq_profiles');
	} catch (err) {
		console.error('List AutoEQ profiles failed:', err);
		return [];
	}
}

export async function setStereoWidener(enabled: boolean, width: number) {
	try {
		const invoke = await lazyInvoke();
		await invoke('set_stereo_widener', { enabled, width });
	} catch (err) {
		console.error('Set stereo widener failed:', err);
	}
}

export async function loadIr(path: string) {
	try {
		const invoke = await lazyInvoke();
		await invoke('load_ir', { path });
	} catch (err) {
		console.error('Load IR failed:', err);
	}
}

export async function clearIr() {
	try {
		const invoke = await lazyInvoke();
		await invoke('clear_ir');
	} catch (err) {
		console.error('Clear IR failed:', err);
	}
}

export async function setAutoEq(name: string | null) {
	try {
		const invoke = await lazyInvoke();
		await invoke('set_auto_eq', { name });
	} catch (err) {
		console.error('Set AutoEQ failed:', err);
	}
}

export type DsdMode = 'to_pcm' | 'dop';

export async function setDsdMode(mode: DsdMode) {
	try {
		const invoke = await lazyInvoke();
		await invoke('set_dsd_mode', { mode });
	} catch (err) {
		console.error('Set DSD mode failed:', err);
	}
}

export async function setLimiterEnabled(enabled: boolean) {
	try {
		const invoke = await lazyInvoke();
		await invoke('set_limiter_enabled', { enabled });
	} catch (err) {
		console.error('Set limiter failed:', err);
	}
}

export async function setDitherEnabled(enabled: boolean) {
	try {
		const invoke = await lazyInvoke();
		await invoke('set_dither_enabled', { enabled });
	} catch (err) {
		console.error('Set dither failed:', err);
	}
}

export async function setOutputSampleRate(rate: number) {
	try {
		const invoke = await lazyInvoke();
		await invoke('set_output_sample_rate', { rate });
	} catch (err) {
		console.error('Set output sample rate failed:', err);
	}
}

export async function setReplaygainPeak(peak: number | null) {
	try {
		const invoke = await lazyInvoke();
		await invoke('set_replaygain_peak', { peak });
	} catch (err) {
		console.error('Set replaygain peak failed:', err);
	}
}

export async function readAudioSamples(maxSamples = 1024): Promise<number[]> {
	try {
		const invoke = await lazyInvoke();
		return await invoke('read_audio_samples', { maxSamples });
	} catch (err) {
		console.error('Read audio samples failed:', err);
		return [];
	}
}

export async function getUnderrunCount(): Promise<number> {
	try {
		const invoke = await lazyInvoke();
		return await invoke('get_underrun_count');
	} catch (err) {
		console.error('Get underrun count failed:', err);
		return 0;
	}
}

// ── 设备枚举与热插拔 ──

export async function enumerateAudioDevices(): Promise<any[]> {
	try {
		const invoke = await lazyInvoke();
		return await invoke('enumerate_audio_devices');
	} catch (err) {
		console.error('Enumerate audio devices failed:', err);
		return [];
	}
}

export async function startDeviceMonitor() {
	try {
		const invoke = await lazyInvoke();
		await invoke('start_device_monitor');
	} catch (err) {
		console.error('Start device monitor failed:', err);
	}
}

export async function stopDeviceMonitor() {
	try {
		const invoke = await lazyInvoke();
		await invoke('stop_device_monitor');
	} catch (err) {
		console.error('Stop device monitor failed:', err);
	}
}

export async function setAudioDeviceSync(name: string) {
	try {
		const invoke = await lazyInvoke();
		await invoke('set_audio_device_sync', { name });
	} catch (err) {
		console.error('Set audio device sync failed:', err);
	}
}

// ── 文件探测 ──

export async function probeSampleRate(path: string): Promise<number> {
	try {
		const invoke = await lazyInvoke();
		return await invoke('probe_sample_rate_cmd', { path });
	} catch (err) {
		console.error('Probe sample rate failed:', err);
		return 0;
	}
}

export async function probeBitDepth(path: string): Promise<number> {
	try {
		const invoke = await lazyInvoke();
		return await invoke('probe_bit_depth_cmd', { path });
	} catch (err) {
		console.error('Probe bit depth failed:', err);
		return 0;
	}
}

export async function readReplaygainTags(path: string): Promise<any | null> {
	try {
		const invoke = await lazyInvoke();
		return await invoke('read_replaygain_tags', { path });
	} catch (err) {
		console.error('Read replaygain tags failed:', err);
		return null;
	}
}

export async function decideOutput(
	deviceId: string,
	sourceSampleRate: number,
	sourceBitDepth: number,
	sourceChannels: number,
	isDsd: boolean,
	dsdRate: number | null,
	preferExclusive = false
): Promise<any | null> {
	try {
		const invoke = await lazyInvoke();
		return await invoke('decide_output_cmd', {
			deviceId,
			sourceSampleRate,
			sourceBitDepth,
			sourceChannels,
			isDsd,
			dsdRate,
			preferExclusive,
		});
	} catch (err) {
		console.error('Decide output failed:', err);
		return null;
	}
}

// ── 播放列表导出 ──

export async function parsePlaylistFile(path: string): Promise<any[]> {
	try {
		const invoke = await lazyInvoke();
		return await invoke('parse_playlist_file', { path });
	} catch (err) {
		console.error('Parse playlist failed:', err);
		return [];
	}
}

export async function exportPlaylistM3u(path: string, entries: any[]) {
	try {
		const invoke = await lazyInvoke();
		await invoke('export_playlist_m3u', { path, entries });
	} catch (err) {
		console.error('Export m3u failed:', err);
	}
}

export async function exportPlaylistPls(path: string, entries: any[]) {
	try {
		const invoke = await lazyInvoke();
		await invoke('export_playlist_pls', { path, entries });
	} catch (err) {
		console.error('Export pls failed:', err);
	}
}

export async function exportPlaylistAuto(path: string, entries: any[]) {
	try {
		const invoke = await lazyInvoke();
		await invoke('export_playlist_auto', { path, entries });
	} catch (err) {
		console.error('Export playlist failed:', err);
	}
}

export function destroy() {
	stop();
	_currentTrack = null;
	_isPlaying = false;
	_currentTime = 0;
	_duration = 0;
}
