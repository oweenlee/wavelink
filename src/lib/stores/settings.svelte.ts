import { browser } from '$app/environment';

/**
 * Settings store — manages app preferences and engine configuration.
 * Persists via save_settings / load_settings backend commands.
 */

let _theme = $state<'dark' | 'light'>('dark');
let _accentColor = $state('#8888cc');
let _sampleRate = $state(44100);
let _bufferMs = $state(80);
let _replaygainEnabled = $state(false);
let _loaded = $state(false);

/** Lazy-load Tauri invoke (SSR safe) */
async function lazyInvoke() {
	const { invoke } = await import('@tauri-apps/api/core');
	return invoke;
}

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

		get replaygainEnabled() { return _replaygainEnabled; },
		set replaygainEnabled(v: boolean) { _replaygainEnabled = v; },

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
				if (typeof saved.replaygainEnabled === 'boolean') _replaygainEnabled = saved.replaygainEnabled;
				if (typeof saved.volume === 'number') {
					// Sync volume to engine
					const { setVolume } = await import('$lib/audio/engine.svelte');
					await setVolume(saved.volume);
				}
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
						replaygainEnabled: _replaygainEnabled,
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
				} catch {}
			}
		},

		async setAccentColor(color: string) {
			_accentColor = color;
			await this.save();
		},
	};
}

export type SettingsState = ReturnType<typeof getSettingsState>;
