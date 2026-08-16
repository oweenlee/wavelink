import { browser, lazyInvoke } from '$lib/tauri';

// 主题色白名单：仅接受设置页色板内的 6 个色值，防止旧版本琥珀色等残留值生效
export const ACCENT_PALETTE = ['#e8553f', '#5b9bd5', '#4ec9a0', '#c8956c', '#d4728a', '#a0aab4'];
const DEFAULT_ACCENT = '#e8553f';

let _theme = $state<'dark' | 'light'>('dark');
let _accentColor = $state(DEFAULT_ACCENT);
let _sampleRate = $state(44100);
let _bufferMs = $state(280);
let _crossfadeMs = $state(0);
let _replaygainEnabled = $state(false);
let _audioDevice = $state('');
let _autoSampleRate = $state(false);
let _exclusiveMode = $state(false);
let _bitPerfect = $state(false);
let _limiterEnabled = $state(true);
let _ditherEnabled = $state(true);
let _dsdMode = $state<'to_pcm' | 'dop'>('to_pcm');
let _loaded = $state(false);
let _volume = $state(1.0);
let _playMode = $state<'normal' | 'repeat_one' | 'repeat_all' | 'shuffle'>('normal');
// 设置保存串行队列：多个组件可能同时触发 save()，避免「读-改-写」竞态导致字段互相覆盖
let _saveChain: Promise<void> = Promise.resolve();

export function getSettingsState() {
	return {
		// ── State ──
		get theme() { return _theme; },
		set theme(v: 'dark' | 'light') { _theme = v; },

		get accentColor() { return _accentColor; },
		set accentColor(v: string) { _accentColor = v; },

		get sampleRate() { return _sampleRate; },
		set sampleRate(v: number) { _sampleRate = v; },

		get bufferMs() { return _bufferMs; },
		set bufferMs(v: number) { _bufferMs = v; },

		get crossfadeMs() { return _crossfadeMs; },
		set crossfadeMs(v: number) { _crossfadeMs = v; },

		get replaygainEnabled() { return _replaygainEnabled; },
		set replaygainEnabled(v: boolean) { _replaygainEnabled = v; },

		get audioDevice() { return _audioDevice; },
		set audioDevice(v: string) { _audioDevice = v; },

		get autoSampleRate() { return _autoSampleRate; },
		set autoSampleRate(v: boolean) { _autoSampleRate = v; },

		get exclusiveMode() { return _exclusiveMode; },
		set exclusiveMode(v: boolean) { _exclusiveMode = v; },

		get bitPerfect() { return _bitPerfect; },
		set bitPerfect(v: boolean) { _bitPerfect = v; },

		get limiterEnabled() { return _limiterEnabled; },
		set limiterEnabled(v: boolean) { _limiterEnabled = v; },

		get ditherEnabled() { return _ditherEnabled; },
		set ditherEnabled(v: boolean) { _ditherEnabled = v; },

		get dsdMode() { return _dsdMode; },
		set dsdMode(v: 'to_pcm' | 'dop') { _dsdMode = v; },

		get volume() { return _volume; },
		set volume(v: number) { _volume = v; },

		get playMode() { return _playMode; },
		set playMode(v: 'normal' | 'repeat_one' | 'repeat_all' | 'shuffle') { _playMode = v; },

		get loaded() { return _loaded; },

		// ── Persistence ──
		async load() {
			if (!browser) return;
			try {
				const invoke = await lazyInvoke();
				const saved: Record<string, any> = await invoke('load_settings');
				if (typeof saved.accentColor === 'string' && ACCENT_PALETTE.includes(saved.accentColor)) _accentColor = saved.accentColor;
				else _accentColor = DEFAULT_ACCENT;
				if (typeof saved.theme === 'string') _theme = saved.theme as 'dark' | 'light';
				if (typeof saved.sampleRate === 'number') _sampleRate = saved.sampleRate;
				if (typeof saved.bufferMs === 'number') _bufferMs = saved.bufferMs;
				if (typeof saved.crossfadeMs === 'number') _crossfadeMs = saved.crossfadeMs;
				if (typeof saved.replaygainEnabled === 'boolean') _replaygainEnabled = saved.replaygainEnabled;
				if (typeof saved.audioDevice === 'string') _audioDevice = saved.audioDevice;
				if (typeof saved.autoSampleRate === 'boolean') _autoSampleRate = saved.autoSampleRate;
				if (typeof saved.exclusiveMode === 'boolean') _exclusiveMode = saved.exclusiveMode;
				if (typeof saved.bitPerfect === 'boolean') _bitPerfect = saved.bitPerfect;
				if (typeof saved.limiterEnabled === 'boolean') _limiterEnabled = saved.limiterEnabled;
				if (typeof saved.ditherEnabled === 'boolean') _ditherEnabled = saved.ditherEnabled;
				if (saved.dsdMode === 'to_pcm' || saved.dsdMode === 'dop') _dsdMode = saved.dsdMode;
				if (typeof saved.volume === 'number') _volume = saved.volume;
				if (saved.playMode === 'normal' || saved.playMode === 'repeat_one' || saved.playMode === 'repeat_all' || saved.playMode === 'shuffle') _playMode = saved.playMode;
				_loaded = true;
				return saved;
			} catch (err) {
				console.error('Failed to load settings:', err);
				_loaded = true;
				return null;
			}
		},

		async save(extra?: Record<string, any>) {
			if (!browser) return;
			// 串行化读-改-写：所有 save 调用排队执行，避免并发写设置文件时互相覆盖
			const doSave = async () => {
				try {
					const invoke = await lazyInvoke();
					// 先读已有设置再合并，避免覆盖 Effects 页持久化的字段（eqBands/autoEq 等）
					let existing: Record<string, any> = {};
					try { existing = (await invoke('load_settings')) ?? {}; } catch { /* 首次无文件 */ }
					await invoke('save_settings', {
						settings: {
							...existing,
							accentColor: _accentColor,
							theme: _theme,
							sampleRate: _sampleRate,
							bufferMs: _bufferMs,
							crossfadeMs: _crossfadeMs,
							replaygainEnabled: _replaygainEnabled,
							audioDevice: _audioDevice,
							autoSampleRate: _autoSampleRate,
							exclusiveMode: _exclusiveMode,
							bitPerfect: _bitPerfect,
							limiterEnabled: _limiterEnabled,
							ditherEnabled: _ditherEnabled,
							dsdMode: _dsdMode,
							volume: _volume,
							playMode: _playMode,
							...extra,
						},
					});
				} catch (err) {
					console.error('Failed to save settings:', err);
				}
			};
			_saveChain = _saveChain.then(doSave, doSave);
			return _saveChain;
		},

		async applyEngineConfig() {
			if (!browser) return;
			try {
				const invoke = await lazyInvoke();
				await invoke('set_engine_config', {
					sampleRate: _sampleRate,
					channels: 2,
					bufferMs: _bufferMs,
					crossfadeMs: _crossfadeMs,
					autoSampleRate: _autoSampleRate,
					exclusiveMode: _exclusiveMode,
					bitPerfect: _bitPerfect,
				});
				await this.save();
			} catch (err) {
				console.error('Failed to apply engine config:', err);
			}
		},

		async setReplaygain(enabled: boolean) {
			_replaygainEnabled = enabled;
			if (browser) {
				try {
					const invoke = await lazyInvoke();
					await invoke('set_replaygain', { enabled });
					await this.save();
				} catch { console.warn('[settings] ReplayGain 同步失败'); }
			}
		},

		async setAudioDevice(device: string) {
			_audioDevice = device;
			if (browser) {
				try {
					const invoke = await lazyInvoke();
					await invoke('set_audio_device', { name: device });
					await this.save();
				} catch { console.warn('[settings] 切换输出设备失败'); }
			}
		},

		async setLimiter(enabled: boolean) {
			_limiterEnabled = enabled;
			if (browser) {
				try {
					const invoke = await lazyInvoke();
					await invoke('set_limiter_enabled', { enabled });
					await this.save();
				} catch { console.warn('[settings] 限幅器同步失败'); }
			}
		},

		async setDither(enabled: boolean) {
			_ditherEnabled = enabled;
			if (browser) {
				try {
					const invoke = await lazyInvoke();
					await invoke('set_dither_enabled', { enabled });
					await this.save();
				} catch { console.warn('[settings] 抖动同步失败'); }
			}
		},

		async setDsdMode(mode: 'to_pcm' | 'dop') {
			_dsdMode = mode;
			if (browser) {
				try {
					const invoke = await lazyInvoke();
					await invoke('set_dsd_mode', { mode });
					await this.save();
				} catch { console.warn('[settings] DSD 模式同步失败'); }
			}
		},

		async setAccentColor(color: string) {
			_accentColor = ACCENT_PALETTE.includes(color) ? color : DEFAULT_ACCENT;
			await this.save();
		},
	};
}

export type SettingsState = ReturnType<typeof getSettingsState>;
