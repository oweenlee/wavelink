import { browser, lazyInvoke } from '$lib/tauri';

let _theme = $state<'dark' | 'light'>('dark');
let _accentColor = $state('#e2a63d');
let _sampleRate = $state(44100);
let _bufferMs = $state(280);
let _crossfadeMs = $state(0);
let _replaygainEnabled = $state(false);
let _audioDevice = $state('');
let _autoSampleRate = $state(false);
let _exclusiveMode = $state(false);
let _bitPerfect = $state(false);
let _loaded = $state(false);

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

		get loaded() { return _loaded; },

		// ── Persistence ──
		async load() {
			if (!browser) return;
			try {
				const invoke = await lazyInvoke();
				const saved: Record<string, any> = await invoke('load_settings');
				if (typeof saved.accentColor === 'string') _accentColor = saved.accentColor;
				if (typeof saved.theme === 'string') _theme = saved.theme as 'dark' | 'light';
				if (typeof saved.sampleRate === 'number') _sampleRate = saved.sampleRate;
				if (typeof saved.bufferMs === 'number') _bufferMs = saved.bufferMs;
				if (typeof saved.crossfadeMs === 'number') _crossfadeMs = saved.crossfadeMs;
				if (typeof saved.replaygainEnabled === 'boolean') _replaygainEnabled = saved.replaygainEnabled;
				if (typeof saved.audioDevice === 'string') _audioDevice = saved.audioDevice;
				if (typeof saved.autoSampleRate === 'boolean') _autoSampleRate = saved.autoSampleRate;
				if (typeof saved.exclusiveMode === 'boolean') _exclusiveMode = saved.exclusiveMode;
				if (typeof saved.bitPerfect === 'boolean') _bitPerfect = saved.bitPerfect;
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
			try {
				const invoke = await lazyInvoke();
				await invoke('save_settings', {
					settings: {
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
						...extra,
					},
				});
			} catch (err) {
				console.error('Failed to save settings:', err);
			}
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

		async setAccentColor(color: string) {
			_accentColor = color;
			await this.save();
		},
	};
}

export type SettingsState = ReturnType<typeof getSettingsState>;
