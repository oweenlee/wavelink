import { getPlaybackState } from './playback.svelte';
import { parseLrc } from '$lib/utils/lyrics';
import type { Track } from '$lib/audio/types';

const playback = getPlaybackState();

let _lines = $state<{ time: number; text: string }[]>([]);
let _loading = $state(false);
let _error = $state('');

/** 组件在其 $effect 中调用，触发歌词加载 */
export function loadForTrack(track: Track | null) {
	if (!track) { _lines = []; _error = ''; return; }

	_lines = [];
	_error = '';
	_loading = true;

	const lrcPath = track.path.replace(/\.[^.]+$/, '.lrc');
	(async () => {
		const { invoke } = await import('@tauri-apps/api/core');
		try {
			try {
				const text: string = await invoke('read_text_file', { path: lrcPath });
				const parsed = parseLrc(text);
				if (parsed.length > 0) { _lines = parsed; _loading = false; return; }
			} catch {}

			const title = track.title || '';
			const artist = track.artist || '';
			if (!title && !artist) { _error = '无歌词'; _loading = false; return; }

			const lrcText: string | null = await invoke('lrc_lookup', { title, artist, album: track.album });
			if (lrcText) {
				const parsed = parseLrc(lrcText);
				if (parsed.length > 0) {
					_lines = parsed;
				} else {
					_lines = lrcText.split('\n').filter(l => l.trim()).map((text, i) => ({
						time: i * 10, text: text.trim()
					}));
				}
				try { await invoke('save_text_file', { path: lrcPath, content: lrcText }); } catch {}
			} else {
				_error = '未找到歌词';
			}
		} catch (e: unknown) {
			console.error('[lyrics] error:', e);
			_error = '查询失败';
		} finally {
			_loading = false;
		}
	})();
}

let _currentIndex = $derived.by(() => {
	if (_lines.length === 0) return -1;
	const ct = playback.currentTime;
	let idx = -1;
	for (let i = 0; i < _lines.length; i++) {
		if (_lines[i].time <= ct) idx = i;
	}
	return idx;
});

export function getLyricsState() {
	return {
		get lines() { return _lines; },
		get loading() { return _loading; },
		get error() { return _error; },
		get currentIndex() { return _currentIndex; },
		progress() {
			if (_lines.length === 0 || _currentIndex < 0) return 0;
			const cur = _lines[_currentIndex].time;
			const next = _currentIndex < _lines.length - 1 ? _lines[_currentIndex + 1].time : playback.duration;
			const dur = next - cur;
			return dur <= 0 ? 1 : Math.min(1, (playback.currentTime - cur) / dur);
		},
	};
}
