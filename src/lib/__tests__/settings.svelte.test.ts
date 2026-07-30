import { describe, it, expect, vi, beforeEach } from 'vitest';

// ---- mocks ----
vi.mock('$app/environment', () => ({ browser: true }));

const mockInvoke = vi.hoisted(() => vi.fn());
vi.mock('@tauri-apps/api/core', () => ({ invoke: mockInvoke }));

// engine.svelte used in load() for setVolume
vi.mock('$lib/audio/engine.svelte', () => ({
	setVolume: vi.fn(),
}));

// ---- tests ----
describe('getSettingsState', () => {
	let state: ReturnType<typeof import('$lib/stores/settings.svelte')['getSettingsState']>;

	beforeEach(async () => {
		vi.clearAllMocks();
		mockInvoke.mockReset();
		const mod = await import('$lib/stores/settings.svelte');
		state = mod.getSettingsState();
		// 手动重置 $state 到默认值
		state.theme = 'dark';
		state.accentColor = '#e2a63d';
		state.sampleRate = 44100;
		state.bufferMs = 280;
		state.crossfadeMs = 0;
		state.replaygainEnabled = false;
		state.audioDevice = '';
		state.autoSampleRate = false;
		state.exclusiveMode = false;
	});

	it('has default values', () => {
		expect(state.theme).toBe('dark');
		expect(state.accentColor).toBe('#e2a63d');
		expect(state.sampleRate).toBe(44100);
		expect(state.bufferMs).toBe(280);
		expect(state.crossfadeMs).toBe(0);
		expect(state.replaygainEnabled).toBe(false);
		expect(state.audioDevice).toBe('');
		expect(state.autoSampleRate).toBe(false);
		expect(state.exclusiveMode).toBe(false);
		expect(state.loaded).toBe(false);
	});

	it('sets theme', () => {
		state.theme = 'light';
		expect(state.theme).toBe('light');
	});

	it('sets accentColor', () => {
		state.accentColor = '#ff0000';
		expect(state.accentColor).toBe('#ff0000');
	});

	it('sets sampleRate', () => {
		state.sampleRate = 48000;
		expect(state.sampleRate).toBe(48000);
	});

	it('sets bufferMs', () => {
		state.bufferMs = 100;
		expect(state.bufferMs).toBe(100);
	});

	it('sets crossfadeMs', () => {
		state.crossfadeMs = 2000;
		expect(state.crossfadeMs).toBe(2000);
	});

	it('sets replaygainEnabled', () => {
		state.replaygainEnabled = true;
		expect(state.replaygainEnabled).toBe(true);
	});

	it('sets autoSampleRate', () => {
		state.autoSampleRate = true;
		expect(state.autoSampleRate).toBe(true);
	});

	it('sets exclusiveMode', () => {
		state.exclusiveMode = true;
		expect(state.exclusiveMode).toBe(true);
	});

	it('load fetches settings from backend', async () => {
		mockInvoke.mockResolvedValueOnce({
			accentColor: '#ff0000', theme: 'light', sampleRate: 48000,
			bufferMs: 100, crossfadeMs: 3000, replaygainEnabled: true,
			audioDevice: 'default', autoSampleRate: true, exclusiveMode: false,
		});
		await state.load();
		expect(mockInvoke).toHaveBeenCalledWith('load_settings');
		expect(state.accentColor).toBe('#ff0000');
		expect(state.theme).toBe('light');
		expect(state.sampleRate).toBe(48000);
		expect(state.bufferMs).toBe(100);
		expect(state.crossfadeMs).toBe(3000);
		expect(state.replaygainEnabled).toBe(true);
		expect(state.audioDevice).toBe('default');
		expect(state.autoSampleRate).toBe(true);
		expect(state.loaded).toBe(true);
	});

	it('load handles error gracefully', async () => {
		mockInvoke.mockRejectedValueOnce(new Error('fail'));
		await state.load();
		expect(state.loaded).toBe(true);
		expect(state.theme).toBe('dark');
	});

	it('save sends settings to backend', async () => {
		state.accentColor = '#ff0000';
		mockInvoke.mockResolvedValueOnce(undefined);
		await state.save();
		expect(mockInvoke).toHaveBeenCalledWith('save_settings', {
			settings: expect.objectContaining({ accentColor: '#ff0000' }),
		});
	});

	it('save merges extra fields', async () => {
		mockInvoke.mockResolvedValueOnce(undefined);
		await state.save({ volume: 0.8 });
		expect(mockInvoke).toHaveBeenCalledWith('save_settings', {
			settings: expect.objectContaining({ volume: 0.8 }),
		});
	});

	it('applyEngineConfig calls set_engine_config with all fields and saves', async () => {
		mockInvoke.mockResolvedValueOnce(undefined);
		mockInvoke.mockResolvedValueOnce(undefined);
		await state.applyEngineConfig();
		expect(mockInvoke).toHaveBeenCalledWith('set_engine_config', {
			sampleRate: 44100, channels: 2, bufferMs: 280, crossfadeMs: 0,
			autoSampleRate: false, exclusiveMode: false, bitPerfect: false,
		});
		expect(mockInvoke).toHaveBeenCalledTimes(2);
	});

	it('setReplaygain calls backend and saves', async () => {
		mockInvoke.mockResolvedValueOnce(undefined);
		mockInvoke.mockResolvedValueOnce(undefined);
		await state.setReplaygain(true);
		expect(state.replaygainEnabled).toBe(true);
		expect(mockInvoke).toHaveBeenCalledWith('set_replaygain', { enabled: true });
	});

	it('setAccentColor updates and saves', async () => {
		mockInvoke.mockResolvedValueOnce(undefined);
		await state.setAccentColor('#00ff00');
		expect(state.accentColor).toBe('#00ff00');
		expect(mockInvoke).toHaveBeenCalledWith('save_settings', expect.any(Object));
	});

	it('setAudioDevice updates and saves', async () => {
		mockInvoke.mockResolvedValueOnce(undefined);
		mockInvoke.mockResolvedValueOnce(undefined);
		await state.setAudioDevice('Built-in Output');
		expect(state.audioDevice).toBe('Built-in Output');
		expect(mockInvoke).toHaveBeenCalledWith('set_audio_device', { name: 'Built-in Output' });
	});
});
