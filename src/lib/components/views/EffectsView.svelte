<script lang="ts">
	import { browser } from '$app/environment';
	import { getSettingsState } from '$lib/stores/settings.svelte';
	import { getPlaybackState } from '$lib/stores/playback.svelte';
	import type { PeqBand } from '$lib/audio/types';

	const settings = getSettingsState();
	const playback = getPlaybackState();

	let eqBands = $state<PeqBand[]>([]);
	let irLoaded = $state(false);
	let stereoWidener = $state(false);
	let stereoWidth = $state(0.5);
	let _invoke: ((cmd: string, args?: any) => Promise<any>) | null = null;

	// ── Load settings ──
	$effect(() => {
		if (!browser) return;
		import('@tauri-apps/api/core').then(async (mod) => {
			_invoke = mod.invoke;
			try {
				const saved: Record<string, any> = await mod.invoke('load_settings');
				if (typeof saved.irLoaded === 'boolean') irLoaded = saved.irLoaded;
				if (typeof saved.stereoWidener === 'boolean') stereoWidener = saved.stereoWidener;
				if (typeof saved.stereoWidth === 'number') stereoWidth = saved.stereoWidth;
				if (Array.isArray(saved.eqBands) && saved.eqBands.length > 0) {
					eqBands = saved.eqBands;
					for (let i = 0; i < saved.eqBands.length; i++) {
						const b = saved.eqBands[i];
						await mod.invoke('set_peq_band', { index: i, freq: b.freq, gain_db: b.gain_db, q: b.q });
					}
					eq10 = getEq10();
				} else {
					const bands: any = await mod.invoke('get_eq_bands');
					eqBands = bands as PeqBand[];
				}
				eq10 = getEq10();
			} catch {}
		});
	});

	async function saveAll() {
		if (!_invoke) return;
		try {
			await _invoke('save_settings', {
				settings: {
					accentColor: settings.accentColor,
					volume: playback.volume,
					eqBands: eqBands.map(b => ({ freq: b.freq, gain_db: b.gain_db, q: b.q })),
					irLoaded, stereoWidener, stereoWidth,
					replaygainEnabled: settings.replaygainEnabled,
				},
			});
		} catch {}
	}

	// ── EQ ──
	const EQ_BANDS = [
		{ freq: 31, label: '31' }, { freq: 63, label: '63' }, { freq: 125, label: '125' },
		{ freq: 250, label: '250' }, { freq: 500, label: '500' }, { freq: 1000, label: '1k' },
		{ freq: 2000, label: '2k' }, { freq: 4000, label: '4k' }, { freq: 8000, label: '8k' },
		{ freq: 16000, label: '16k' },
	];
	const EQ_BAND_INDICES = [0, 3, 6, 9, 12, 15, 18, 21, 24, 27];
	const EQ_RANGES: [number, number][] = [
		[0, 2], [1, 5], [4, 8], [7, 11], [10, 14],
		[13, 17], [16, 20], [19, 23], [22, 26], [25, 30],
	];

	function getEq10(): number[] {
		if (eqBands.length < 31) return EQ_BANDS.map(() => 0);
		return EQ_BAND_INDICES.map(i => eqBands[i]?.gain_db ?? 0);
	}

	let eq10 = $state<number[]>(EQ_BANDS.map(() => 0));

	$effect(() => { eq10 = getEq10(); });

	async function onEqSlider(index: number, val: number) {
		if (!_invoke) return;
		const [lo, hi] = EQ_RANGES[index];
		eqBands = eqBands.map((b, i) => (i >= lo && i <= hi) ? { ...b, gain_db: val } : b);
		for (let i = lo; i <= hi && i < eqBands.length; i++) {
			await _invoke('set_peq_band', { index: i, freq: eqBands[i].freq, gain_db: val, q: eqBands[i].q });
		}
		saveAll();
	}

	async function updateEqFromEngine() {
		if (!_invoke) return;
		const bands: any = await _invoke('get_eq_bands');
		eqBands = bands as PeqBand[];
		saveAll();
	}

	async function setEqPreset(preset: string) {
		if (!_invoke) return;
		await _invoke('set_eq_preset', { preset });
		await updateEqFromEngine();
	}

	async function resetEq() {
		if (!_invoke) return;
		await _invoke('reset_eq');
		await updateEqFromEngine();
	}

	// ── IR ──
	async function handleLoadIr() {
		if (!_invoke) return;
		const { open } = await import('@tauri-apps/plugin-dialog');
		const path = await open({ filters: [{ name: 'IR WAV', extensions: ['wav'] }], title: '选择 IR 脉冲响应' });
		if (path) { await _invoke('load_ir', { path }); irLoaded = true; saveAll(); }
	}
	async function handleClearIr() { if (!_invoke) return; await _invoke('clear_ir'); irLoaded = false; saveAll(); }

	// ── Stereo widener ──
	async function toggleStereoWidener() {
		stereoWidener = !stereoWidener;
		if (_invoke) { await _invoke('set_stereo_widener', { enabled: stereoWidener, width: stereoWidth }); saveAll(); }
	}
	async function updateStereoWidth() { if (_invoke && stereoWidener) { await _invoke('set_stereo_widener', { enabled: true, width: stereoWidth }); saveAll(); } }

	const eqPresets = ['flat', 'rock', 'pop', 'dance', 'classical', 'soft', 'fullbass', 'fulltreble', 'techno', 'vocals'];
</script>

<div class="effects-page">
	<div class="page-title">音效设置</div>

	<!-- ── EQ ── -->
	<div class="effect-card eq-card">
		<div class="card-header">
			<h3 class="card-title">均衡器</h3>
			<div class="card-actions">
				<select class="preset-select" onchange={(e) => setEqPreset((e.currentTarget as HTMLSelectElement).value)}>
					<option value="" disabled selected>预设</option>
					{#each eqPresets as p}<option value={p}>{p}</option>{/each}
				</select>
				<button class="btn btn-sm" onclick={resetEq}>重置</button>
			</div>
		</div>
		<div class="eq-grid">
			{#each EQ_BANDS as band, i}
			<div class="eq-col">
				<span class="eq-gain-val">{eq10[i] > 0 ? '+' : ''}{eq10[i].toFixed(1)}</span>
				<div class="eq-slider-wrap">
					<input type="range" min="-12" max="12" step="0.5" value={eq10[i]} oninput={(e) => onEqSlider(i, parseFloat((e.currentTarget as HTMLInputElement).value))} class="eq-slider-v" style="--accent: {settings.accentColor};" />
				</div>
				<span class="eq-freq-label">{band.label}</span>
			</div>
			{/each}
		</div>
	</div>

	<!-- ── Audio effects grid ── -->
	<div class="effects-grid">
		<div class="effect-card small">
			<h3 class="card-title">IR 卷积混响</h3>
			<p class="card-desc">加载真实声学空间的脉冲响应，模拟混响效果</p>
			<div class="card-actions">
				<button class="btn" onclick={handleLoadIr}>
					<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"/><polyline points="17,8 12,3 7,8"/><line x1="12" y1="3" x2="12" y2="15"/></svg>
					<span>加载 WAV</span>
				</button>
				{#if irLoaded}<button class="btn danger" onclick={handleClearIr}>清除</button>{/if}
				<span class="status-dot" class:active={irLoaded}></span>
				<span class="status-text">{irLoaded ? '已加载' : '未加载'}</span>
			</div>
		</div>

		<div class="effect-card small">
			<h3 class="card-title">立体声展宽</h3>
			<p class="card-desc">扩展立体声场，提升空间感</p>
			<div class="card-body">
				<button class="toggle" class:active={stereoWidener} onclick={toggleStereoWidener}>
					<span class="toggle-knob"></span>
					<span class="toggle-label">{stereoWidener ? '开启' : '关闭'}</span>
				</button>
				{#if stereoWidener}
					<div class="slider-row">
						<span class="slider-label">宽度</span>
						<input type="range" min="0" max="1" step="0.05" bind:value={stereoWidth} oninput={updateStereoWidth} class="slider" style="--accent: {settings.accentColor};" />
						<span class="slider-val">{Math.round(stereoWidth * 100)}%</span>
					</div>
				{/if}
			</div>
		</div>

		<div class="effect-card small">
			<h3 class="card-title">ReplayGain</h3>
			<p class="card-desc">统一不同曲目的响度，避免切歌时音量突变</p>
			<div class="card-body">
				<button class="toggle" class:active={settings.replaygainEnabled} onclick={() => settings.setReplaygain(!settings.replaygainEnabled)}>
					<span class="toggle-knob"></span>
					<span class="toggle-label">{settings.replaygainEnabled ? '开启' : '关闭'}</span>
				</button>
			</div>
		</div>
	</div>
</div>

<style>
	.effects-page { padding: 8px 32px 32px; display: flex; flex-direction: column; gap: 24px; height: 100%; overflow-y: auto; }
	.page-title { font-size: 22px; font-weight: 700; color: var(--fg-primary); padding: 4px 0; flex-shrink: 0; }

	.effect-card { background: var(--bg-surface); border: 1px solid var(--separator); border-radius: 16px; padding: 20px 24px; }
	.effect-card.small { padding: 18px 20px; }
	.card-header { display: flex; align-items: center; justify-content: space-between; margin-bottom: 16px; }
	.card-title { font-size: 14px; font-weight: 600; color: var(--fg-primary); margin: 0; }
	.card-desc { font-size: 12px; color: var(--fg-tertiary); margin: 4px 0 12px; }
	.card-actions { display: flex; align-items: center; gap: 8px; }
	.card-body { display: flex; flex-direction: column; gap: 10px; }

	.btn { display: inline-flex; align-items: center; gap: 6px; padding: 7px 14px; border-radius: 8px; border: 1px solid var(--separator); background: var(--bg-surface); color: var(--fg-secondary); font-size: 12px; font-family: inherit; cursor: pointer; transition: all 0.15s; }
	.btn:hover { background: var(--bg-hover); color: var(--fg-primary); }
	.btn-sm { padding: 5px 10px; font-size: 11px; }
	.btn.danger { border-color: rgba(255, 80, 80, 0.15); color: rgba(255, 80, 80, 0.5); }
	.btn.danger:hover { background: rgba(255, 80, 80, 0.08); }

	.preset-select { padding: 5px 10px; border-radius: 8px; border: 1px solid var(--separator); background: var(--bg-surface); color: var(--fg-secondary); font-size: 12px; font-family: inherit; outline: none; cursor: pointer; }

	.eq-grid { display: flex; gap: 6px; align-items: flex-start; justify-content: center; padding: 8px 0; }
	.eq-col { display: flex; flex-direction: column; align-items: center; gap: 6px; flex: 1; max-width: 48px; }
	.eq-gain-val { font-size: 10px; color: var(--fg-tertiary); font-variant-numeric: tabular-nums; height: 14px; line-height: 14px; }
	.eq-slider-wrap { height: 120px; display: flex; align-items: center; }
	.eq-slider-v { -webkit-appearance: none; appearance: none; width: 100px; height: 4px; border-radius: 2px; background: rgba(255, 255, 255, 0.1); outline: none; cursor: pointer; writing-mode: vertical-lr; direction: rtl; }
	.eq-slider-v::-webkit-slider-thumb { -webkit-appearance: none; width: 14px; height: 14px; border-radius: 50%; background: var(--accent, #8888cc); cursor: pointer; box-shadow: 0 0 10px color-mix(in srgb, var(--accent, #8888cc) 40%, transparent); }
	.eq-freq-label { font-size: 10px; color: var(--fg-tertiary); }

	.effects-grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(280px, 1fr)); gap: 16px; }

	.toggle { display: inline-flex; align-items: center; gap: 10px; padding: 4px; border: none; background: var(--bg-hover); border-radius: 20px; cursor: pointer; transition: all 0.2s; width: 52px; position: relative; }
	.toggle.active { background: var(--accent, #8888cc); }
	.toggle-knob { width: 18px; height: 18px; border-radius: 50%; background: white; box-shadow: 0 1px 4px rgba(0,0,0,0.2); transition: transform 0.2s; }
	.toggle.active .toggle-knob { transform: translateX(26px); }
	.toggle-label { position: absolute; left: 56px; font-size: 12px; color: var(--fg-secondary); white-space: nowrap; }

	.status-dot { width: 6px; height: 6px; border-radius: 50%; background: var(--fg-quaternary); }
	.status-dot.active { background: #44cc88; box-shadow: 0 0 6px rgba(68, 204, 136, 0.4); }
	.status-text { font-size: 11px; color: var(--fg-tertiary); }

	.slider-row { display: flex; align-items: center; gap: 10px; }
	.slider-label { font-size: 11px; color: var(--fg-tertiary); min-width: 32px; }
	.slider { flex: 1; max-width: 140px; -webkit-appearance: none; appearance: none; height: 4px; border-radius: 2px; background: rgba(255, 255, 255, 0.1); outline: none; cursor: pointer; }
	.slider::-webkit-slider-thumb { -webkit-appearance: none; width: 12px; height: 12px; border-radius: 50%; background: var(--accent, #8888cc); cursor: pointer; }
	.slider-val { font-size: 11px; color: var(--fg-tertiary); min-width: 28px; }
</style>
