<script lang="ts">
	import { browser } from '$app/environment';
	import { getSettingsState } from '$lib/stores/settings.svelte';
	import { getPlaybackState } from '$lib/stores/playback.svelte';
	import type { PeqBand } from '$lib/audio/types';
	import { Upload } from 'lucide-svelte';

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

			// 1. 先从引擎加载默认 EQ 波段（31 段）
			try {
				const bands: any = await mod.invoke('get_eq_bands');
				eqBands = bands as PeqBand[];
			} catch { console.warn('[Effects] EQ 加载失败, 使用默认');
				// 引擎无 EQ 数据时使用默认
			}

			// 2. 再从保存的设置覆盖（仅当波段数匹配时才覆盖：31 段或 10 段）
			try {
				const saved: Record<string, any> = await mod.invoke('load_settings');
				if (typeof saved.irLoaded === 'boolean') irLoaded = saved.irLoaded;
				if (typeof saved.stereoWidener === 'boolean') stereoWidener = saved.stereoWidener;
				if (typeof saved.stereoWidth === 'number') stereoWidth = saved.stereoWidth;
				if (Array.isArray(saved.eqBands) && (saved.eqBands.length === 31 || saved.eqBands.length === 10)) {
					eqBands = saved.eqBands;
					for (let i = 0; i < saved.eqBands.length; i++) {
						const b = saved.eqBands[i];
						await mod.invoke('set_peq_band', { index: i, freq: b.freq, gainDb: b.gain_db, q: b.q });
					}
				}
			} catch { console.warn('[Effects] 设置加载/同步失败'); }

			eq10 = getEq10();
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
		} catch { console.warn('[Effects] 保存设置失败'); }
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
		if (eqBands.length === 31) {
			// 31 段模式（引擎默认）：提取 10 个可见节点的值
			return EQ_BAND_INDICES.map(i => eqBands[i]?.gain_db ?? 0);
		}
		// 10 段模式（预设后）：直接对应
		return eqBands.map(b => b.gain_db);
	}

	let eq10 = $state<number[]>(EQ_BANDS.map(() => 0));

	$effect(() => { eq10 = getEq10(); });

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

	const eqPresets = ['flat', 'rock', 'pop', 'dance', 'classical', 'soft', 'full_bass', 'full_treble', 'techno', 'vocals'];
	let _activePreset = $state('');

	// 预设名称的显示映射
	const presetLabels: Record<string, string> = {
		flat: '平直', rock: '摇滚', pop: '流行', dance: '舞曲',
		classical: '古典', soft: '柔和', full_bass: '重低音',
		full_treble: '高音增强', techno: '电子', vocals: '人声',
	};

	// ── 交互式 EQ 曲线 Canvas ──
	let canvasEl: HTMLCanvasElement | undefined = $state();
	let canvasContainer: HTMLDivElement | undefined = $state();
	let dpr = $state(1);
	let _dragIndex = $state(-1);       // -1 = 未拖拽
	let _hoverIndex = $state(-1);      // -1 = 未悬停
	let _canvasWidth = $state(0);
	let _dragEnabled = $state(true);   // EQ 拖拽开关
	let _animId: number | undefined = $state();

	// 组件卸载时取消动画
	$effect(() => {
		return () => { if (_animId !== undefined) cancelAnimationFrame(_animId); };
	});

	// 画布坐标映射函数（在 drawEqCurve 中也有，这里提取供交互用）
	const MIN_FREQ = 20;
	const MAX_FREQ = 20000;
	const FREQS = [31, 63, 125, 250, 500, 1000, 2000, 4000, 8000, 16000];
	const PAD = { top: 12, bottom: 22, left: 36, right: 12 };

	function freqToX(f: number, w: number, d: number): number {
		const plotW = w * d - (PAD.left + PAD.right) * d;
		const logMin = Math.log(MIN_FREQ);
		const logRange = Math.log(MAX_FREQ) - logMin;
		return PAD.left * d + (Math.log(f) - logMin) / logRange * plotW;
	}

	function gainToY(g: number, h: number, d: number): number {
		const plotH = h * d - (PAD.top + PAD.bottom) * d;
		return PAD.top * d + (12 - g) / 24 * plotH;
	}

	function yToGain(y: number, h: number, d: number): number {
		const plotH = h * d - (PAD.top + PAD.bottom) * d;
		const g = 12 - (y - PAD.top * d) / plotH * 24;
		return Math.round(Math.max(-12, Math.min(12, g)) * 2) / 2; // snap to 0.5
	}

	$effect(() => {
		if (!browser || !canvasContainer) return;
		dpr = window.devicePixelRatio || 1;
		const ro = new ResizeObserver((entries) => {
			for (const entry of entries) {
				const { width } = entry.contentRect;
				_canvasWidth = width;
				if (canvasEl && width > 0) {
					canvasEl.style.width = width + 'px';
					canvasEl.style.height = '220px';
					canvasEl.width = Math.round(width * dpr);
					canvasEl.height = Math.round(220 * dpr);
					drawEqCurve();
				}
			}
		});
		ro.observe(canvasContainer);
		return () => ro.disconnect();
	});

	$effect(() => {
		const _ = [...eq10];
		drawEqCurve();
	});

	function getCanvasCoords(e: MouseEvent): { x: number; y: number } {
		const rect = canvasEl!.getBoundingClientRect();
		return { x: (e.clientX - rect.left) * dpr, y: (e.clientY - rect.top) * dpr };
	}

	function findNearestNode(mx: number): number {
		const h = 220;
		const pts = eq10.map((g, i) => ({
			x: freqToX(FREQS[i], _canvasWidth, dpr),
			y: gainToY(g, h, dpr),
		}));
		let minDist = 20 * dpr;
		let idx = -1;
		for (let i = 0; i < pts.length; i++) {
			const dist = Math.hypot(mx - pts[i].x, 0); // 只查水平距离
			if (dist < minDist) { minDist = dist; idx = i; }
		}
		return idx;
	}

	function onCanvasMouseDown(e: MouseEvent) {
		if (!_dragEnabled || !_invoke || !canvasEl) return;
		_dragIndex = -1;
		_hoverIndex = -1;
		const { x, y } = getCanvasCoords(e);
		const pts = eq10.map((g, i) => ({
			x: freqToX(FREQS[i], _canvasWidth, dpr),
			y: gainToY(g, 220, dpr),
		}));
		let nearest = -1;
		let minDist = 24 * dpr;
		for (let i = 0; i < pts.length; i++) {
			const dist = Math.hypot(x - pts[i].x, y - pts[i].y);
			if (dist < minDist) { minDist = dist; nearest = i; }
		}
		if (nearest >= 0) {
			_dragIndex = nearest;
			canvasEl.style.cursor = 'grabbing';
		}
	}

	function onCanvasMouseMove(e: MouseEvent) {
		if (!canvasEl) return;
		if (!_dragEnabled) {
			// 拖拽关闭时只做悬停光标提示
			const { x } = getCanvasCoords(e);
			const idx = findNearestNode(x);
			canvasEl.style.cursor = idx >= 0 ? 'grab' : 'default';
			return;
		}
		const { x, y } = getCanvasCoords(e);

		if (_dragIndex >= 0) {
			// 拖拽中
			const val = yToGain(y, 220, dpr);
			setEqFromCanvas(_dragIndex, val);
			return;
		}

		// 悬停检测
		const idx = findNearestNode(x);
		_hoverIndex = idx;
		canvasEl.style.cursor = idx >= 0 ? 'grab' : 'default';
		drawEqCurve();
	}

	function onCanvasMouseUp() {
		if (_dragIndex >= 0) {
			_dragIndex = -1;
			if (canvasEl) canvasEl.style.cursor = 'default';
			saveAll();
			drawEqCurve();
		}
	}

	function onCanvasMouseLeave() {
		if (_dragIndex < 0) {
			_hoverIndex = -1;
			drawEqCurve();
		}
	}

	async function setEqFromCanvas(index: number, val: number) {
		if (!_invoke) return;
		if (eqBands.length === 31) {
			// 31 段模式：通过 EQ_RANGES 映射到实际波段
			const [lo, hi] = EQ_RANGES[index];
			eqBands = eqBands.map((b, i) => (i >= lo && i <= hi) ? { ...b, gain_db: val } : b);
			for (let i = lo; i <= hi && i < eqBands.length; i++) {
				await _invoke('set_peq_band', { index: i, freq: eqBands[i].freq, gainDb: val, q: eqBands[i].q });
			}
		} else {
			// 10 段模式：直接映射
			eqBands = eqBands.map((b, i) => i === index ? { ...b, gain_db: val } : b);
			await _invoke('set_peq_band', { index, freq: eqBands[index].freq, gainDb: val, q: eqBands[index].q });
		}
		// eq10 会通过 $effect 自动更新并重绘
	}

	async function updateEqFromEngine() {
		if (!_invoke) return;
		const bands: any = await _invoke('get_eq_bands');
		eqBands = bands as PeqBand[];
		eq10 = getEq10(); // 立即更新 eq10（不等 $effect 异步执行）
		saveAll();
	}

	async function setEqPreset(preset: string) {
		if (!_invoke) return;

		// 取消正在进行的动画
		if (_animId !== undefined) cancelAnimationFrame(_animId);

		// 记录动画起始值（当前曲线）
		const fromVals = [...eq10];

		await _invoke('set_eq_preset', { preset });
		await updateEqFromEngine();

		// 记录目标值（预设曲线）
		const toVals = [...eq10];

		// 动画过渡：300ms 从 fromVals 到 toVals
		const duration = 300;
		const start = performance.now();

		function tick(now: number) {
			const t = Math.min((now - start) / duration, 1);
			const ease = 1 - Math.pow(1 - t, 3); // easeOutCubic
			eq10 = fromVals.map((f, i) => f + (toVals[i] - f) * ease);
			if (t < 1) {
				_animId = requestAnimationFrame(tick);
			} else {
				eq10 = toVals;
				_animId = undefined;
			}
		}
		_animId = requestAnimationFrame(tick);

		_activePreset = preset;
		_dragIndex = -1;
		_hoverIndex = -1;
	}

	async function resetEq() {
		if (!_invoke) return;
		if (_animId !== undefined) cancelAnimationFrame(_animId);

		const fromVals = [...eq10];
		await _invoke('reset_eq');
		await updateEqFromEngine();
		const toVals = [...eq10];

		const duration = 300;
		const start = performance.now();
		function tick(now: number) {
			const t = Math.min((now - start) / duration, 1);
			const ease = 1 - Math.pow(1 - t, 3);
			eq10 = fromVals.map((f, i) => f + (toVals[i] - f) * ease);
			if (t < 1) {
				_animId = requestAnimationFrame(tick);
			} else {
				eq10 = toVals;
				_animId = undefined;
			}
		}
		_animId = requestAnimationFrame(tick);

		_activePreset = '';
		_dragIndex = -1;
		_hoverIndex = -1;
	}

	function drawEqCurve() {
		const canvas = canvasEl;
		if (!canvas) return;
		const ctx = canvas.getContext('2d');
		if (!ctx) return;

		const w = canvas.width;
		const h = canvas.height;
		const d = dpr;
		const pad = { top: PAD.top * d, bottom: PAD.bottom * d, left: PAD.left * d, right: PAD.right * d };
		const plotW = w - pad.left - pad.right;
		const plotH = h - pad.top - pad.bottom;

		ctx.clearRect(0, 0, w, h);

		const freqs = FREQS;
		const logMin = Math.log(MIN_FREQ);
		const logRange = Math.log(MAX_FREQ) - logMin;

		function f2x(f: number) { return pad.left + (Math.log(f) - logMin) / logRange * plotW; }
		function g2y(g: number) { return pad.top + (12 - g) / 24 * plotH; }

		const pts = eq10.map((g, i) => ({ x: f2x(freqs[i]), y: g2y(g) }));

		// ── 网格 ──
		ctx.strokeStyle = `rgba(255,255,255,0.06)`;
		ctx.lineWidth = 1 * d;
		for (const db of [-12, -6, 0, 6, 12]) {
			const y = g2y(db);
			ctx.beginPath();
			ctx.moveTo(pad.left, y);
			ctx.lineTo(w - pad.right, y);
			ctx.stroke();
		}
		const zeroY = g2y(0);
		ctx.strokeStyle = `rgba(255,255,255,0.12)`;
		ctx.lineWidth = 1.5 * d;
		ctx.beginPath();
		ctx.moveTo(pad.left, zeroY);
		ctx.lineTo(w - pad.right, zeroY);
		ctx.stroke();

		ctx.strokeStyle = `rgba(255,255,255,0.04)`;
		ctx.lineWidth = 1 * d;
		for (const f of freqs) {
			const x = f2x(f);
			ctx.beginPath();
			ctx.moveTo(x, pad.top);
			ctx.lineTo(x, h - pad.bottom);
			ctx.stroke();
		}

		// ── 频率标签 ──
		ctx.fillStyle = `rgba(255,255,255,0.3)`;
		ctx.font = `${10 * d}px -apple-system, BlinkMacSystemFont, sans-serif`;
		ctx.textAlign = 'center';
		ctx.textBaseline = 'top';
		const freqLabels = ['31', '63', '125', '250', '500', '1k', '2k', '4k', '8k', '16k'];
		for (let i = 0; i < freqs.length; i++) {
			ctx.fillText(freqLabels[i], f2x(freqs[i]), h - pad.bottom + 4 * d);
		}

		// ── dB 标签 ──
		ctx.textAlign = 'right';
		ctx.textBaseline = 'middle';
		ctx.font = `${9 * d}px -apple-system, BlinkMacSystemFont, sans-serif`;
		for (const db of [-12, -6, 0, 6, 12]) {
			if (db === 0) continue;
			ctx.fillStyle = `rgba(255,255,255,0.2)`;
			ctx.fillText(`${db > 0 ? '+' : ''}${db}`, pad.left - 6 * d, g2y(db));
		}
		ctx.fillStyle = `rgba(255,255,255,0.35)`;
		ctx.fillText('0', pad.left - 6 * d, zeroY);

		// ── 平滑曲线 ──
		if (pts.length < 2) return;
		const numSamples = 200;
		const curvePts: { x: number; y: number }[] = [];
		for (let i = 0; i < numSamples; i++) {
			const t = i / (numSamples - 1);
			const x = pad.left + t * plotW;
			const freq = MIN_FREQ * Math.pow(MAX_FREQ / MIN_FREQ, t);
			let seg = 0;
			for (let j = 0; j < freqs.length - 1; j++) {
				if (freq >= freqs[j] && freq <= freqs[j + 1]) { seg = j; break; }
			}
			if (freq > freqs[freqs.length - 1]) seg = freqs.length - 2;
			if (freq < freqs[0]) seg = 0;
			const f0 = freqs[seg], f1 = freqs[seg + 1];
			const g0 = eq10[seg], g1 = eq10[seg + 1];
			const segT = (Math.log(freq) - Math.log(f0)) / (Math.log(f1) - Math.log(f0));
			const gPrev = seg > 0 ? eq10[seg - 1] : g0 - (g1 - g0) * 0.3;
			const gNext = seg < eq10.length - 2 ? eq10[seg + 2] : g1 + (g1 - g0) * 0.3;
			const y = catmullRomInterp(gPrev, g0, g1, gNext, segT);
			curvePts.push({ x, y: g2y(y) });
		}

		// 填充
		ctx.beginPath();
		ctx.moveTo(curvePts[0].x, g2y(0));
		for (const p of curvePts) ctx.lineTo(p.x, p.y);
		ctx.lineTo(curvePts[curvePts.length - 1].x, g2y(0));
		ctx.closePath();
		const accentRgba = hexToRgba(settings.accentColor);
		const grad = ctx.createLinearGradient(0, pad.top, 0, pad.top + plotH);
		if (accentRgba) {
			grad.addColorStop(0, `rgba(${accentRgba.r},${accentRgba.g},${accentRgba.b},0.20)`);
			grad.addColorStop(0.5, `rgba(${accentRgba.r},${accentRgba.g},${accentRgba.b},0.07)`);
			grad.addColorStop(1, `rgba(${accentRgba.r},${accentRgba.g},${accentRgba.b},0.02)`);
		} else {
			grad.addColorStop(0, 'rgba(136,136,204,0.20)');
			grad.addColorStop(1, 'rgba(136,136,204,0.02)');
		}
		ctx.fillStyle = grad;
		ctx.fill();

		// 曲线
		ctx.beginPath();
		ctx.moveTo(curvePts[0].x, curvePts[0].y);
		for (let i = 1; i < curvePts.length; i++) ctx.lineTo(curvePts[i].x, curvePts[i].y);
		ctx.strokeStyle = settings.accentColor;
		ctx.lineWidth = 2 * d;
		ctx.lineJoin = 'round';
		ctx.lineCap = 'round';
		ctx.stroke();

		// 节点 + 增益值
		for (let i = 0; i < pts.length; i++) {
			const p = pts[i];
			const isHover = i === _hoverIndex;
			const isDrag = i === _dragIndex;
			const r = (isDrag ? 6 : isHover ? 5 : 4) * d;

			// 增益值标签（悬停/拖拽时显示）
			if (isHover || isDrag) {
				ctx.fillStyle = `rgba(255,255,255,0.7)`;
				ctx.font = `bold ${11 * d}px -apple-system, BlinkMacSystemFont, sans-serif`;
				ctx.textAlign = 'center';
				ctx.textBaseline = 'bottom';
				const label = `${eq10[i] > 0 ? '+' : ''}${eq10[i].toFixed(1)} dB`;
				ctx.fillText(label, p.x, p.y - r - 4 * d);
			}

			// 阴影
			ctx.beginPath();
			ctx.arc(p.x, p.y, r + 4 * d, 0, Math.PI * 2);
			ctx.fillStyle = `rgba(0,0,0,0.2)`;
			ctx.fill();

			// 节点圆
			ctx.beginPath();
			ctx.arc(p.x, p.y, r, 0, Math.PI * 2);
			ctx.fillStyle = settings.accentColor;
			ctx.fill();
			if (isDrag) {
				ctx.strokeStyle = `rgba(255,255,255,0.4)`;
				ctx.lineWidth = 2 * d;
				ctx.stroke();
			}
		}
	}

	function catmullRomInterp(p0: number, p1: number, p2: number, p3: number, t: number): number {
		const t2 = t * t, t3 = t2 * t;
		return 0.5 * ((2 * p1) + (-p0 + p2) * t + (2 * p0 - 5 * p1 + 4 * p2 - p3) * t2 + (-p0 + 3 * p1 - 3 * p2 + p3) * t3);
	}

	function hexToRgba(hex: string): { r: number; g: number; b: number } | null {
		const m = /^#?([a-f0-9]{2})([a-f0-9]{2})([a-f0-9]{2})$/i.exec(hex);
		if (!m) return null;
		return { r: parseInt(m[1], 16), g: parseInt(m[2], 16), b: parseInt(m[3], 16) };
	}
</script>

<div class="effects-page">
	<!-- ── EQ ── -->
	<div class="effect-card eq-card">
		<div class="card-header">
			<h3 class="card-title">均衡器</h3>
			<div class="card-actions">
				<select class="preset-select" bind:value={_activePreset} onchange={(e) => { const v = (e.currentTarget as HTMLSelectElement).value; if (v) setEqPreset(v); }}>
					<option value="">预设</option>
					{#each eqPresets as p}<option value={p}>{presetLabels[p] || p}</option>{/each}
				</select>
				<button class="btn btn-sm" onclick={resetEq}>重置</button>
			</div>
		</div>
		<div class="eq-canvas-wrap" bind:this={canvasContainer}>
			<canvas
				bind:this={canvasEl}
				onmousedown={onCanvasMouseDown}
				onmousemove={onCanvasMouseMove}
				onmouseup={onCanvasMouseUp}
				onmouseleave={onCanvasMouseLeave}
			></canvas>
		</div>
		<div class="eq-hint">拖拽曲线上圆点调节各频段增益 ({EQ_BANDS.map(b => b.label).join(' / ')})</div>
	</div>

	<!-- ── Audio effects grid ── -->
	<div class="effects-grid">
		<div class="effect-card small">
			<h3 class="card-title">IR 卷积混响</h3>
			<p class="card-desc">加载真实声学空间的脉冲响应，模拟混响效果</p>
			<div class="card-actions">
			<button class="btn" onclick={handleLoadIr}>
				<Upload size={14} />
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

	.eq-canvas-wrap {
		margin: 0 -4px;
		width: 100%;
		overflow: hidden;
		border-radius: var(--radius-md);
		background: rgba(0, 0, 0, 0.12);
	}

	.eq-canvas-wrap canvas {
		display: block;
		width: 100%;
		height: 220px;
		cursor: default;
	}

	.eq-hint {
		font-size: 11px;
		color: var(--fg-quaternary);
		text-align: center;
		padding: 6px 0 0;
		letter-spacing: 0.3px;
	}

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
