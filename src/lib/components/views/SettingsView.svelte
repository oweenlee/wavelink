<script lang="ts">
	import { browser } from '$app/environment';
	import { getSettingsState } from '$lib/stores/settings.svelte';
	import { getPlaybackState, type PlayMode } from '$lib/stores/playback.svelte';

	const settings = getSettingsState();
	const playback = getPlaybackState();

	let _invoke: ((cmd: string, args?: any) => Promise<any>) | null = null;

	$effect(() => {
		if (!browser) return;
		import('@tauri-apps/api/core').then(async (mod) => {
			_invoke = mod.invoke;
			await settings.load();
			// Sync playMode from engine
			try {
				const mode = await mod.invoke('get_play_mode');
				playback.playMode = mode as PlayMode;
			} catch {}
		});
	});

	const accentColors = [
		{ name: '极光紫', color: '#8888cc' }, { name: '海洋蓝', color: '#4488cc' },
		{ name: '翡翠绿', color: '#44aa88' }, { name: '琥珀橙', color: '#cc8844' },
		{ name: '玫瑰红', color: '#cc4488' }, { name: '月光银', color: '#aabbcc' },
	];

	async function setAccentColor(color: string) {
		await settings.setAccentColor(color);
	}

	async function applyEngineConfig() {
		await settings.applyEngineConfig();
	}

	async function toggleReplaygain() {
		await settings.setReplaygain(!settings.replaygainEnabled);
	}
</script>

<div class="settings-page">
	<!-- ── 引擎配置 ── -->
	<div class="card">
		<div class="card-header">
			<h3 class="card-title">音频引擎</h3>
		</div>
		<div class="card-body">
			<div class="setting-row">
				<div class="setting-label">
					<span class="label-text">采样率</span>
					<span class="label-desc">输出音频的采样率 (Hz)</span>
				</div>
				<select class="select" bind:value={settings.sampleRate} onchange={applyEngineConfig}>
					<option value={44100}>44100 Hz (CD)</option>
					<option value={48000}>48000 Hz (DVD)</option>
					<option value={96000}>96000 Hz (Hi-Res)</option>
					<option value={192000}>192000 Hz (Hi-Res)</option>
				</select>
			</div>
			<div class="setting-row">
				<div class="setting-label">
					<span class="label-text">缓冲区大小</span>
					<span class="label-desc">音频输出缓冲时长 (ms)，越小延迟越低</span>
				</div>
				<div class="slider-row">
					<input type="range" min="20" max="300" step="10" bind:value={settings.bufferMs} onchange={applyEngineConfig} class="slider" style="--accent: {settings.accentColor};" />
					<span class="slider-val">{settings.bufferMs} ms</span>
				</div>
			</div>
		</div>
	</div>

	<!-- ── 外观 ── -->
	<div class="card">
		<div class="card-header">
			<h3 class="card-title">外观</h3>
		</div>
		<div class="card-body">
			<div class="setting-row">
				<div class="setting-label">
					<span class="label-text">主题色</span>
					<span class="label-desc">自定义应用强调色</span>
				</div>
				<div class="color-row">
					{#each accentColors as c}
						<button class="color-dot" class:active={settings.accentColor === c.color} style="background: {c.color};" onclick={() => setAccentColor(c.color)} title={c.name}></button>
					{/each}
				</div>
			</div>
		</div>
	</div>

	<!-- ── 播放 ── -->
	<div class="card">
		<div class="card-header">
			<h3 class="card-title">播放</h3>
		</div>
		<div class="card-body">
			<div class="setting-row">
				<div class="setting-label">
					<span class="label-text">ReplayGain</span>
					<span class="label-desc">统一不同曲目的响度，避免切歌时音量突变</span>
				</div>
				<button class="toggle" class:active={settings.replaygainEnabled} onclick={toggleReplaygain} aria-label="切换 ReplayGain">
					<span class="toggle-knob"></span>
				</button>
			</div>
		</div>
	</div>

	<!-- ── 关于 ── -->
	<div class="card about">
		<div class="card-header">
			<h3 class="card-title">关于</h3>
		</div>
		<div class="about-body">
			<div class="about-logo">◈</div>
			<div class="about-info">
				<span class="about-name">WaveLink</span>
				<span class="about-version">版本 0.1.0 · 果味玻璃风格高级音乐播放器</span>
			</div>
		</div>
	</div>
</div>

<style>
	.settings-page { padding: 8px 32px 32px; display: flex; flex-direction: column; gap: 20px; height: 100%; overflow-y: auto; }

	.card { background: var(--bg-surface); border: 1px solid var(--separator); border-radius: 16px; padding: 20px 24px; }
	.card-header { display: flex; align-items: center; justify-content: space-between; margin-bottom: 16px; }
	.card-title { font-size: 14px; font-weight: 600; color: var(--fg-primary); margin: 0; }
	.card-body { display: flex; flex-direction: column; gap: 16px; }

	.setting-row { display: flex; align-items: center; justify-content: space-between; gap: 16px; }
	.setting-label { display: flex; flex-direction: column; gap: 2px; }
	.label-text { font-size: 13px; font-weight: 500; color: var(--fg-primary); }
	.label-desc { font-size: 11px; color: var(--fg-tertiary); }

	.select { padding: 6px 12px; border-radius: 8px; border: 1px solid var(--separator); background: var(--bg-surface); color: var(--fg-secondary); font-size: 12px; font-family: inherit; outline: none; cursor: pointer; }

	.slider-row { display: flex; align-items: center; gap: 10px; }
	.slider { -webkit-appearance: none; appearance: none; width: 140px; height: 4px; border-radius: 2px; background: rgba(255, 255, 255, 0.1); outline: none; cursor: pointer; }
	.slider::-webkit-slider-thumb { -webkit-appearance: none; width: 12px; height: 12px; border-radius: 50%; background: var(--accent, #8888cc); cursor: pointer; }
	.slider-val { font-size: 11px; color: var(--fg-tertiary); min-width: 50px; text-align: right; }

	.color-row { display: flex; gap: 10px; }
	.color-dot { width: 28px; height: 28px; border-radius: 50%; border: 2px solid transparent; cursor: pointer; transition: all 0.2s; outline: none; }
	.color-dot:hover { transform: scale(1.2); }
	.color-dot.active { border-color: rgba(255, 255, 255, 0.6); box-shadow: 0 0 12px rgba(255, 255, 255, 0.1); }

	.toggle { display: inline-flex; align-items: center; padding: 4px; border: none; background: var(--bg-hover); border-radius: 20px; cursor: pointer; transition: all 0.2s; width: 52px; height: 26px; position: relative; }
	.toggle.active { background: var(--accent, #8888cc); }
	.toggle-knob { width: 18px; height: 18px; border-radius: 50%; background: white; box-shadow: 0 1px 4px rgba(0,0,0,0.2); transition: transform 0.2s; }
	.toggle.active .toggle-knob { transform: translateX(26px); }

	.about { position: relative; }
	.about-body { display: flex; align-items: center; gap: 16px; }
	.about-logo { font-size: 32px; color: var(--accent); }
	.about-info { display: flex; flex-direction: column; gap: 2px; }
	.about-name { font-size: 16px; font-weight: 600; color: var(--fg-primary); }
	.about-version { font-size: 12px; color: var(--fg-tertiary); }
</style>
