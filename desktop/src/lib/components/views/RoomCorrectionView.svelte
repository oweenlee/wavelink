<script lang="ts">
	import { browser } from '$lib/tauri';
	import { getSettingsState } from '$lib/stores/settings.svelte';
	import { t } from '$lib/i18n/i18n.svelte';
	import type { CorrectionConfig, FreqPoint, RoomCorrectionReport } from '$lib/audio/types';
	import { Upload, ClipboardPaste, Trash2, CheckCircle2, Circle, AlertTriangle, X } from 'lucide-svelte';

	const settings = getSettingsState();

	// ── 状态 ──
	let _rewText = $state('');
	let _measured = $state<FreqPoint[]>([]);
	let _cfg = $state<CorrectionConfig | null>(null);
	let _generating = $state(false);
	let _report = $state<RoomCorrectionReport | null>(null);
	let _active = $state(false);
	let _error = $state('');
	let _pasting = $state(false);
	let _pasteText = $state('');

	// ── 画布 ──
	let canvasEl = $state<HTMLCanvasElement | undefined>();
	let canvasWrap = $state<HTMLDivElement | undefined>();
	let dpr = $state(1);
	let _canvasWidth = $state(0);

	// 初始化：默认配置 + 已应用状态（启动恢复路径存在即 active）
	$effect(() => {
		if (!browser) return;
		import('@tauri-apps/api/core').then(async (mod) => {
			try { _cfg = (await mod.invoke('default_correction_config')) as CorrectionConfig; } catch { /* 保持 null */ }
			try {
				const p = await mod.invoke('get_room_correction_path');
				_active = p != null;
			} catch { /* 保持 false */ }
		});
	});

	// ── 导入 / 粘贴 ──

	async function importFromFile() {
		const { open } = await import('@tauri-apps/plugin-dialog');
		const path = await open({ filters: [{ name: 'REW', extensions: ['txt', 'csv'] }], multiple: false });
		if (!path) return;
		try {
			const { invoke } = await import('@tauri-apps/api/core');
			const text = await invoke('read_text_file', { path });
			await parseText(String(text));
		} catch {
			_error = t('room.error_read');
		}
	}

	async function parseText(text: string) {
		try {
			const { invoke } = await import('@tauri-apps/api/core');
			const pts = (await invoke('parse_rew_text', { text })) as FreqPoint[];
			_rewText = text;
			_measured = pts;
			_report = null;
			_error = '';
			_pasting = false;
			_pasteText = '';
		} catch (e) {
			_error = String(e);
		}
	}

	// ── 生成 / 清除 ──

	async function generate() {
		if (!_rewText || !_cfg) { _error = t('room.no_data'); return; }
		_generating = true;
		_error = '';
		try {
			const { invoke } = await import('@tauri-apps/api/core');
			_report = (await invoke('generate_room_correction', { rewTxt: _rewText, config: _cfg })) as RoomCorrectionReport;
			_active = true;
		} catch (e) {
			_error = t('room.error_generate', { error: String(e) });
		} finally {
			_generating = false;
		}
	}

	async function clear() {
		try {
			const { invoke } = await import('@tauri-apps/api/core');
			await invoke('clear_room_correction');
		} catch { /* 忽略 */ }
		_active = false;
		_report = null;
	}

	// ── 参数 ──

	function setCfg(patch: Partial<CorrectionConfig>) {
		if (_cfg) _cfg = { ..._cfg, ...patch };
	}

	function fmtFreq(v: number): string {
		return v >= 1000 ? `${(v / 1000).toFixed(1)}kHz` : `${Math.round(v)}Hz`;
	}

	// ── 测量曲线 Canvas（log 频率 x 轴，dB y 轴，校正范围背景高亮）──

	const MIN_FREQ = 10;
	const MAX_FREQ = 20000;
	const CHART_H = 180;

	$effect(() => {
		if (!browser || !canvasWrap) return;
		dpr = window.devicePixelRatio || 1;
		const ro = new ResizeObserver((entries) => {
			for (const entry of entries) {
				const { width } = entry.contentRect;
				_canvasWidth = width;
				if (canvasEl && width > 0) {
					canvasEl.style.width = width + 'px';
					canvasEl.style.height = CHART_H + 'px';
					canvasEl.width = Math.round(width * dpr);
					canvasEl.height = Math.round(CHART_H * dpr);
					drawCurve();
				}
			}
		});
		ro.observe(canvasWrap);
		return () => ro.disconnect();
	});

	$effect(() => {
		const _ = [_measured, _cfg?.freq_min, _cfg?.freq_max];
		drawCurve();
	});

	function drawCurve() {
		const canvas = canvasEl;
		if (!canvas) return;
		const ctx = canvas.getContext('2d');
		if (!ctx || _measured.length < 2) return;

		const w = canvas.width;
		const h = canvas.height;
		const d = dpr;
		const pad = { top: 10 * d, bottom: 18 * d, left: 40 * d, right: 12 * d };
		const plotW = w - pad.left - pad.right;
		const plotH = h - pad.top - pad.bottom;

		ctx.clearRect(0, 0, w, h);

		const logMin = Math.log(MIN_FREQ);
		const logRange = Math.log(MAX_FREQ) - logMin;
		const f2x = (f: number) => pad.left + (Math.log(f) - logMin) / logRange * plotW;

		const dbMin = _measured.reduce((a, p) => Math.min(a, p.level_db), Infinity);
		const dbMax = _measured.reduce((a, p) => Math.max(a, p.level_db), -Infinity);
		const span = dbMax - dbMin < 0.5 ? 1.0 : dbMax - dbMin;
		const g2y = (g: number) => pad.top + (dbMax - g) / span * plotH;

		// 校正范围背景
		const fMin = _cfg?.freq_min ?? 20;
		const fMax = _cfg?.freq_max ?? 16000;
		ctx.fillStyle = hexToRgba(settings.accentColor, 0.07);
		ctx.fillRect(f2x(fMin), 0, f2x(fMax) - f2x(fMin), h);

		// 0dB 参考线
		if (dbMin < 0 && dbMax > 0) {
			const y = g2y(0);
			ctx.strokeStyle = 'rgba(255,255,255,0.12)';
			ctx.lineWidth = 1 * d;
			ctx.beginPath();
			ctx.moveTo(pad.left, y);
			ctx.lineTo(w - pad.right, y);
			ctx.stroke();
		}

		// 折线
		ctx.beginPath();
		_measured.forEach((p, i) => {
			const x = f2x(Math.max(MIN_FREQ, p.freq));
			const y = g2y(p.level_db);
			if (i === 0) ctx.moveTo(x, y);
			else ctx.lineTo(x, y);
		});
		ctx.strokeStyle = settings.accentColor;
		ctx.lineWidth = 1.6 * d;
		ctx.lineJoin = 'round';
		ctx.lineCap = 'round';
		ctx.stroke();

		// 频率刻度 100 / 1k / 10k
		ctx.fillStyle = 'rgba(255,255,255,0.3)';
		ctx.font = `${9 * d}px -apple-system, BlinkMacSystemFont, sans-serif`;
		ctx.textAlign = 'center';
		ctx.textBaseline = 'top';
		for (const f of [100, 1000, 10000]) {
			ctx.fillText(f >= 1000 ? `${Math.round(f / 1000)}k` : `${f}`, f2x(f), h - pad.bottom + 4 * d);
		}
	}

	function hexToRgba(hex: string, alpha: number): string {
		const m = /^#?([a-f0-9]{2})([a-f0-9]{2})([a-f0-9]{2})$/i.exec(hex);
		if (!m) return `rgba(226,166,61,${alpha})`;
		const r = parseInt(m[1], 16), g = parseInt(m[2], 16), b = parseInt(m[3], 16);
		return `rgba(${r},${g},${b},${alpha})`;
	}
</script>

<div class="room-page">
	<div class="effect-card">
		<div class="card-header">
			<h3 class="card-title">{t('room.title')}</h3>
			<div class="status">
				{#if _active}
					<CheckCircle2 size={14} style="color: #44cc88;" />
					<span class="status-text" style="color: #44cc88;">{t('room.active')}</span>
				{:else}
					<Circle size={14} />
					<span class="status-text">{t('room.off')}</span>
				{/if}
				{#if _report}
					<span class="ir-len">{t('room.ir_len', { taps: _report.ir_len })}</span>
				{/if}
			</div>
		</div>
		<p class="card-desc">{t('room.hint')}</p>

		{#if settings.bitPerfect}
			<div class="warn-banner">
				<AlertTriangle size={14} />
				<span>{t('room.bit_perfect_warn')}</span>
			</div>
		{/if}

		{#if _error}
			<div class="error-banner">
				<span>{_error}</span>
			</div>
		{/if}

		<!-- ── 导入 ── -->
		<div class="import-row">
			<button class="btn" onclick={importFromFile}>
				<Upload size={14} />
				<span>{t('room.import')}</span>
			</button>
			<button class="btn" onclick={() => { _pasting = !_pasting; }}>
				<ClipboardPaste size={14} />
				<span>{t('room.paste')}</span>
			</button>
		</div>

		{#if _pasting}
			<div class="paste-box">
				<textarea
					bind:value={_pasteText}
					placeholder="Freq (Hz), Level (dB)&#10;20.0, -1.5&#10;…"
					rows="6"
				></textarea>
				<div class="paste-actions">
					<button class="btn" onclick={() => parseText(_pasteText)}>{t('room.paste_parse')}</button>
					<button class="btn" onclick={() => { _pasting = false; _pasteText = ''; }}>
						<X size={14} />
					</button>
				</div>
			</div>
		{/if}

		{#if _measured.length > 0}
			<div class="data-badge">
				{t('room.valid_points', { count: _measured.length })}
				<span class="dot">·</span>
				{t('room.freq_span', { min: Math.round(_measured[0].freq), max: Math.round(_measured[_measured.length - 1].freq) })}
			</div>
		{/if}

		<!-- ── 测量曲线预览 ── -->
		{#if _measured.length >= 2}
			<h4 class="section-title">{t('room.preview')}</h4>
			<div class="chart-wrap" bind:this={canvasWrap}>
				<canvas bind:this={canvasEl}></canvas>
			</div>
		{/if}
	</div>

	<!-- ── 参数 ── -->
	{#if _cfg}
		<div class="effect-card">
			<h4 class="section-title">{t('room.target')}</h4>
			<div class="seg-row">
				<button
					class="seg" class:seg-active={_cfg.target === 'flat'}
					style={_cfg.target === 'flat' ? `border-color: ${settings.accentColor}; color: ${settings.accentColor};` : ''}
					onclick={() => setCfg({ target: 'flat' })}
				>{t('room.target_flat')}</button>
				<button
					class="seg" class:seg-active={_cfg.target === 'harman_tilt'}
					style={_cfg.target === 'harman_tilt' ? `border-color: ${settings.accentColor}; color: ${settings.accentColor};` : ''}
					onclick={() => setCfg({ target: 'harman_tilt' })}
				>{t('room.target_harman')}</button>
			</div>
			<p class="hint-text">{t('room.target_hint')}</p>

			<h4 class="section-title">{t('room.taps')}</h4>
			<div class="chip-row">
				{#each [4096, 8192, 16384, 32768] as taps}
					<button
						class="chip" class:chip-active={_cfg.taps === taps}
						style={_cfg.taps === taps ? `border-color: ${settings.accentColor}; color: ${settings.accentColor};` : ''}
						onclick={() => setCfg({ taps })}
					>{taps}</button>
				{/each}
			</div>
			<p class="hint-text">{t('room.taps_hint')}</p>

			<div class="param-row">
				<div class="param-head">
					<span>{t('room.max_cut')}</span>
					<span class="param-val" style="color: {settings.accentColor};">{_cfg.max_cut_db.toFixed(0)} dB</span>
				</div>
				<input type="range" min="3" max="21" step="1" bind:value={_cfg.max_cut_db} class="slider" style="--accent: {settings.accentColor};" />
			</div>

			<div class="param-row">
				<div class="param-head">
					<span>{t('room.null_limit')}</span>
					<span class="param-val" style="color: {settings.accentColor};">{_cfg.null_limit_db.toFixed(0)} dB</span>
				</div>
				<input type="range" min="0" max="9" step="0.5" bind:value={_cfg.null_limit_db} class="slider" style="--accent: {settings.accentColor};" />
				<p class="hint-text">{t('room.null_limit_hint')}</p>
			</div>

			<div class="param-row">
				<div class="param-head">
					<span>{t('room.headroom')}</span>
					<span class="param-val" style="color: {settings.accentColor};">{_cfg.headroom_db.toFixed(0)} dB</span>
				</div>
				<input type="range" min="1" max="12" step="0.5" bind:value={_cfg.headroom_db} class="slider" style="--accent: {settings.accentColor};" />
				<p class="hint-text">{t('room.headroom_hint')}</p>
			</div>

			<div class="param-row">
				<div class="param-head">
					<span>{t('room.freq_range')}</span>
					<span class="param-val" style="color: {settings.accentColor};">{fmtFreq(_cfg.freq_min)} - {fmtFreq(_cfg.freq_max)}</span>
				</div>
				<div class="range-duo">
					<span class="range-label">{fmtFreq(_cfg.freq_min)}</span>
					<input
						type="range" min="20" max="20000" step="100" value={_cfg.freq_min}
						style="--accent: {settings.accentColor};"
						oninput={(e) => {
							const v = Number((e.currentTarget as HTMLInputElement).value);
							if (v < _cfg!.freq_max - 100) setCfg({ freq_min: v });
						}}
					/>
					<input
						type="range" min="20" max="20000" step="100" value={_cfg.freq_max}
						style="--accent: {settings.accentColor};"
						oninput={(e) => {
							const v = Number((e.currentTarget as HTMLInputElement).value);
							if (v > _cfg!.freq_min + 100) setCfg({ freq_max: v });
						}}
					/>
					<span class="range-label">{fmtFreq(_cfg.freq_max)}</span>
				</div>
			</div>

			<div class="switch-row">
				<div class="switch-head">
					<span>{t('room.psycho')}</span>
					<button class="toggle" aria-label={t('room.psycho')} class:active={_cfg.psycho_weighting} onclick={() => setCfg({ psycho_weighting: !_cfg!.psycho_weighting })}>
						<span class="toggle-knob"></span>
					</button>
				</div>
				<p class="hint-text">{t('room.psycho_hint')}</p>
			</div>
		</div>
	{/if}

	<!-- ── 生成 / 清除 ── -->
	<div class="actions">
		<button
			class="btn primary"
			disabled={_generating || !_rewText || !_cfg}
			onclick={generate}
		>
			{#if _generating}
				<span class="spinner"></span>
				<span>{t('room.generating')}</span>
			{:else}
				<span>{t('room.generate')}</span>
			{/if}
		</button>

		{#if _active}
			<button class="btn danger" onclick={clear}>
				<Trash2 size={14} />
				<span>{t('room.clear')}</span>
			</button>
		{/if}
	</div>

	{#if _report}
		<p class="gain-hint">
			{_report.applied_gain_db < 0
				? t('room.gain_hint', { gain: _report.applied_gain_db.toFixed(1) })
				: t('room.gain_hint_merge', { gain: `+${_report.applied_gain_db.toFixed(1)}` })}
		</p>
	{/if}
</div>

<style>
	.room-page { padding: 8px 32px 32px; display: flex; flex-direction: column; gap: 16px; height: 100%; overflow-y: auto; }

	.effect-card { background: var(--bg-surface); border: 1px solid var(--separator); border-radius: 16px; padding: 20px 24px; }
	.card-header { display: flex; align-items: center; justify-content: space-between; margin-bottom: 8px; }
	.card-title { font-size: 14px; font-weight: 600; color: var(--fg-primary); margin: 0; }
	.card-desc { font-size: 12px; color: var(--fg-tertiary); margin: 4px 0 12px; }

	.status { display: flex; align-items: center; gap: 6px; font-size: 12px; color: var(--fg-tertiary); }
	.status-text { font-size: 11px; }
	.ir-len { font-size: 11px; color: var(--fg-tertiary); opacity: 0.8; }

	.warn-banner { display: flex; align-items: flex-start; gap: 8px; padding: 10px 12px; border-radius: 8px; background: rgba(255, 170, 0, 0.08); border: 1px solid rgba(255, 170, 0, 0.25); font-size: 11px; color: #ffab2e; margin-bottom: 12px; }
	.error-banner { padding: 10px 12px; border-radius: 8px; background: rgba(255, 80, 80, 0.08); border: 1px solid rgba(255, 80, 80, 0.25); font-size: 12px; color: rgba(255, 110, 110, 0.9); margin-bottom: 12px; }

	.import-row { display: flex; gap: 8px; }

	.btn { display: inline-flex; align-items: center; gap: 6px; padding: 7px 14px; border-radius: 8px; border: 1px solid var(--separator); background: var(--bg-surface); color: var(--fg-secondary); font-size: 12px; font-family: inherit; cursor: pointer; transition: all 0.15s; }
	.btn:hover { background: var(--bg-hover); color: var(--fg-primary); }
	.btn:disabled { opacity: 0.45; cursor: default; }
	.btn.primary { background: var(--accent, #e8553f); border-color: transparent; color: #0a0a0c; font-weight: 600; }
	.btn.primary:hover { filter: brightness(1.08); }
	.btn.danger { border-color: rgba(255, 80, 80, 0.15); color: rgba(255, 80, 80, 0.5); }
	.btn.danger:hover { background: rgba(255, 80, 80, 0.08); color: rgba(255, 80, 80, 0.8); }

	.paste-box { margin-top: 10px; }
	.paste-box textarea { width: 100%; box-sizing: border-box; resize: vertical; background: rgba(0, 0, 0, 0.15); border: 1px solid var(--separator); border-radius: 8px; color: var(--fg-primary); font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 11px; padding: 10px; outline: none; }
	.paste-box textarea:focus { border-color: var(--accent); }
	.paste-actions { display: flex; gap: 8px; margin-top: 8px; }

	.data-badge { display: inline-flex; align-items: center; gap: 6px; margin-top: 12px; padding: 5px 10px; border-radius: 8px; background: color-mix(in srgb, var(--accent, #e8553f) 12%, transparent); border: 1px solid color-mix(in srgb, var(--accent, #e8553f) 35%, transparent); font-size: 12px; color: var(--accent, #e8553f); }
	.dot { opacity: 0.5; }

	.section-title { font-size: 13px; font-weight: 600; color: var(--fg-secondary); margin: 16px 0 10px; }
	.section-title:first-child { margin-top: 4px; }

	.chart-wrap { width: 100%; overflow: hidden; border-radius: var(--radius-md); background: rgba(0, 0, 0, 0.12); }
	.chart-wrap canvas { display: block; width: 100%; height: 180px; }

	.seg-row { display: flex; gap: 8px; }
	.seg { flex: 1; padding: 9px 0; border-radius: 10px; border: 1px solid var(--separator); background: var(--bg-hover); color: var(--fg-secondary); font-size: 12px; font-family: inherit; cursor: pointer; transition: all 0.15s; }
	.seg:hover { color: var(--fg-primary); }

	.chip-row { display: flex; gap: 8px; flex-wrap: wrap; }
	.chip { padding: 6px 12px; border-radius: 8px; border: 1px solid var(--separator); background: var(--bg-hover); color: var(--fg-secondary); font-size: 12px; font-family: inherit; cursor: pointer; transition: all 0.15s; }
	.chip:hover { color: var(--fg-primary); }

	.hint-text { font-size: 11px; color: var(--fg-quaternary); margin: 6px 0 0; line-height: 1.5; }

	.param-row { margin-top: 14px; }
	.param-head { display: flex; align-items: center; justify-content: space-between; font-size: 13px; color: var(--fg-primary); margin-bottom: 4px; }
	.param-val { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 12px; font-weight: 600; }

	.slider { flex: 1; width: 100%; -webkit-appearance: none; appearance: none; height: 4px; border-radius: 2px; background: rgba(255, 255, 255, 0.1); outline: none; cursor: pointer; }
	.slider::-webkit-slider-thumb { -webkit-appearance: none; width: 12px; height: 12px; border-radius: 50%; background: var(--accent, #e8553f); cursor: pointer; }

	.range-duo { display: flex; align-items: center; gap: 8px; }
	.range-duo input[type="range"] { flex: 1; }
	.range-label { font-size: 10px; color: var(--fg-tertiary); min-width: 42px; text-align: center; font-family: ui-monospace, SFMono-Regular, Menlo, monospace; }

	.switch-row { margin-top: 14px; }
	.switch-head { display: flex; align-items: center; justify-content: space-between; font-size: 13px; color: var(--fg-primary); }

	.toggle { display: inline-flex; align-items: center; padding: 4px; border: none; background: var(--bg-hover); border-radius: 20px; cursor: pointer; transition: all 0.2s; width: 44px; position: relative; }
	.toggle.active { background: var(--accent, #e8553f); }
	.toggle-knob { width: 18px; height: 18px; border-radius: 50%; background: white; box-shadow: 0 1px 4px rgba(0, 0, 0, 0.2); transition: transform 0.2s; }
	.toggle.active .toggle-knob { transform: translateX(18px); }

	.actions { display: flex; align-items: center; gap: 8px; }
	.spinner { width: 14px; height: 14px; border-radius: 50%; border: 2px solid rgba(10, 10, 12, 0.3); border-top-color: #0a0a0c; animation: spin 0.8s linear infinite; }
	@keyframes spin { to { transform: rotate(360deg); } }

	.gain-hint { font-size: 12px; color: var(--fg-tertiary); margin: 0; }
</style>