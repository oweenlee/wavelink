<script lang="ts">
	import { browser } from '$app/environment';
	import { getSettingsState } from '$lib/stores/settings.svelte';
	import { getPlaybackState, type PlayMode } from '$lib/stores/playback.svelte';
	import { Trash2 } from 'lucide-svelte';
	import { open } from '@tauri-apps/plugin-dialog';
	import { t } from '$lib/i18n/i18n.svelte';

	const settings = getSettingsState();
	const playback = getPlaybackState();

	let _invoke: ((cmd: string, args?: any) => Promise<any>) | null = null;
	let folders = $state<string[]>([]);
	let devices = $state<string[]>([]);

	$effect(() => {
		if (!browser) return;
		import('@tauri-apps/api/core').then(async (mod) => {
			_invoke = mod.invoke;
			await settings.load();
			try {
				folders = await mod.invoke('get_scan_folders');
				const mode = await mod.invoke('get_play_mode');
				playback.playMode = mode as PlayMode;
				devices = await mod.invoke('list_audio_devices');
			} catch { console.warn('同步失败'); }
		});
	});

	async function setAudioDevice(e: Event) {
		const target = e.target as HTMLSelectElement;
		await settings.setAudioDevice(target.value);
	}

	const accentColors = [
		{ name: t('settings.purple'), color: '#8888cc' }, { name: t('settings.blue'), color: '#4488cc' },
		{ name: t('settings.green'), color: '#44aa88' }, { name: t('settings.amber'), color: '#cc8844' },
		{ name: t('settings.rose'), color: '#cc4488' }, { name: t('settings.silver'), color: '#aabbcc' },
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

	async function addFolder() {
		const selected = await open({ directory: true, multiple: false, title: t('settings.select_folder') });
		if (!selected || !_invoke) return;
		try {
			const result = await _invoke('scan_dir', { path: selected });
			console.log('扫描结果:', result);
			folders = await _invoke('get_scan_folders');
		} catch (e) { console.error('扫描失败:', e); }
	}

	async function removeFolder(path: string) {
		if (!_invoke) return;
		try {
			const count = await _invoke('remove_scan_folder', { path });
			folders = folders.filter(f => f !== path);
			console.log(`已删除 ${count} 首曲目`);
		} catch (e) { console.error('删除失败:', e); }
	}
</script>

<div class="settings-page">
	<!-- ── 引擎配置 ── -->
	<div class="card">
		<div class="card-header">
			<h3 class="card-title">{t('settings.audio_engine')}</h3>
		</div>
		<div class="card-body">
			<div class="setting-row">
				<div class="setting-label">
					<span class="label-text">{t('settings.sample_rate')}</span>
					<span class="label-desc">{t('settings.sample_rate_desc')}</span>
				</div>
				<select class="select" bind:value={settings.sampleRate} onchange={applyEngineConfig}>
					<option value={44100}>{t('settings.cd')}</option>
					<option value={48000}>{t('settings.dvd')}</option>
					<option value={96000}>{t('settings.hi_res_96')}</option>
					<option value={192000}>{t('settings.hi_res_192')}</option>
				</select>
			</div>
			<div class="setting-row">
				<div class="setting-label">
					<span class="label-text">{t('settings.buffer_size')}</span>
					<span class="label-desc">{t('settings.buffer_desc')}</span>
				</div>
				<div class="slider-row">
					<input type="range" min="20" max="300" step="10" bind:value={settings.bufferMs} onchange={applyEngineConfig} class="slider" style="--accent: {settings.accentColor};" />
					<span class="slider-val">{settings.bufferMs} ms</span>
				</div>
			</div>
			<div class="setting-row">
				<div class="setting-label">
					<span class="label-text">{t('settings.crossfade')}</span>
					<span class="label-desc">{t('settings.crossfade_desc')}</span>
				</div>
				<div class="slider-row">
					<input type="range" min="0" max="5000" step="100" bind:value={settings.crossfadeMs} onchange={applyEngineConfig} class="slider" style="--accent: {settings.accentColor};" />
					<span class="slider-val">{settings.crossfadeMs} ms</span>
				</div>
			</div>
			<div class="setting-row">
				<div class="setting-label">
					<span class="label-text">{t('settings.output_device')}</span>
					<span class="label-desc">{t('settings.output_device_desc')}</span>
				</div>
				<select class="select" value={settings.audioDevice} onchange={setAudioDevice}>
					<option value="">{t('settings.default_device')}</option>
					{#each devices as d (d)}
						<option value={d}>{d}</option>
					{/each}
				</select>
			</div>
		</div>
	</div>

	<!-- ── 外观 ── -->
	<div class="card">
		<div class="card-header">
			<h3 class="card-title">{t('settings.appearance')}</h3>
		</div>
		<div class="card-body">
			<div class="setting-row">
				<div class="setting-label">
					<span class="label-text">{t('settings.accent_color')}</span>
					<span class="label-desc">{t('settings.accent_desc')}</span>
				</div>
				<div class="color-row">
					{#each accentColors as c (c.color)}
						<button class="color-dot" class:active={settings.accentColor === c.color} style="background: {c.color};" onclick={() => setAccentColor(c.color)} title={c.name}></button>
					{/each}
				</div>
			</div>
		</div>
	</div>

	<!-- ── 播放 ── -->
	<div class="card">
		<div class="card-header">
			<h3 class="card-title">{t('settings.playback')}</h3>
		</div>
		<div class="card-body">
			<div class="setting-row">
				<div class="setting-label">
					<span class="label-text">{t('settings.replaygain')}</span>
					<span class="label-desc">{t('settings.replaygain_desc')}</span>
				</div>
				<button class="toggle" class:active={settings.replaygainEnabled} onclick={toggleReplaygain} aria-label={t('settings.toggle_replaygain')}>
					<span class="toggle-knob"></span>
				</button>
			</div>
		</div>
	</div>

	<!-- ── 文件夹管理 ── -->
	<div class="card">
		<div class="card-header">
			<h3 class="card-title">{t('settings.scan_folders')}</h3>
			<button class="btn-add" onclick={addFolder} title={t('settings.add_folder')}>{t('settings.add_folder_short')}</button>
		</div>
		<div class="card-body">
			{#if folders.length === 0}
				<p class="empty-hint">{t('settings.no_folders')}</p>
			{:else}
				{#each folders as folder (folder)}
					<div class="folder-row">
						<div class="folder-path" title={folder}>{folder}</div>
						<button class="btn-remove" onclick={() => removeFolder(folder)} title={t('settings.remove_folder')}>
							<Trash2 size={14} />
						</button>
					</div>
				{/each}
			{/if}
		</div>
	</div>

	<!-- ── 关于 ── -->
	<div class="card about">
		<div class="card-header">
			<h3 class="card-title">{t('settings.about')}</h3>
		</div>
		<div class="about-body">
			<div class="about-logo">◈</div>
			<div class="about-info">
				<span class="about-name">WaveLink</span>
				<span class="about-version">{t('settings.version')}</span>
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

	.folder-row { display: flex; align-items: center; justify-content: space-between; gap: 8px; padding: 6px 8px; border-radius: 8px; background: rgba(255,255,255,0.03); }
	.folder-row:hover { background: rgba(255,255,255,0.06); }
	.folder-path { font-size: 12px; color: var(--fg-secondary); overflow: hidden; text-overflow: ellipsis; white-space: nowrap; flex: 1; }
	.btn-add { padding: 4px 12px; border: none; border-radius: 6px; background: var(--accent); color: #fff; font-size: 12px; cursor: pointer; transition: all 0.15s; }
	.btn-add:hover { filter: brightness(1.15); }
	.btn-remove { width: 28px; height: 28px; border: none; border-radius: 6px; background: transparent; color: var(--fg-tertiary); cursor: pointer; display: flex; align-items: center; justify-content: center; transition: all 0.15s; flex-shrink: 0; }
	.btn-remove:hover { background: rgba(239,68,68,0.15); color: #ef4444; }
	.empty-hint { font-size: 12px; color: var(--fg-tertiary); text-align: center; padding: 8px 0; }
</style>
