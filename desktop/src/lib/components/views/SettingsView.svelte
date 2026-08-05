<script lang="ts">
	import { browser } from '$app/environment';
	import { getSettingsState } from '$lib/stores/settings.svelte';
	import { getPlaybackState, type PlayMode } from '$lib/stores/playback.svelte';
	import { getPlaylistState } from '$lib/stores/playlist.svelte';
	import { Trash2, Activity, Monitor, ListMusic, Radio } from 'lucide-svelte';
	import { open, save } from '@tauri-apps/plugin-dialog';
	import { t } from '$lib/i18n/i18n.svelte';

	const settings = getSettingsState();
	const playback = getPlaybackState();
	const playlist = getPlaylistState();

	let _invoke: ((cmd: string, args?: any) => Promise<any>) | null = null;
	let folders = $state<string[]>([]);
	let devices = $state<string[]>([]);
	let showAdvanced = $state(false);

	// 设备热插拔
	let monitorActive = $state(false);
	let deviceEvents = $state<{ type: string; name: string; time: number }[]>([]);
	let underrunCount = $state(0);
	let _underrunTimer: ReturnType<typeof setInterval> | undefined;

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
		{ name: t('settings.amber'), color: '#e2a63d' }, { name: t('settings.blue'), color: '#5b9bd5' },
		{ name: t('settings.green'), color: '#5daa72' }, { name: t('settings.copper'), color: '#c8956c' },
		{ name: t('settings.rose'), color: '#d4728a' }, { name: t('settings.silver'), color: '#a0aab4' },
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

	// ── 设备热插拔 ──
	let _unsubDeviceEvent: (() => void) | null = null;

	$effect(() => {
		return () => {
			if (_unsubDeviceEvent) _unsubDeviceEvent();
			if (_underrunTimer) clearInterval(_underrunTimer);
		};
	});

	async function toggleMonitor() {
		if (!_invoke) return;
		if (monitorActive) {
			await _invoke('stop_device_monitor');
			monitorActive = false;
			if (_unsubDeviceEvent) { _unsubDeviceEvent(); _unsubDeviceEvent = null; }
			if (_underrunTimer) { clearInterval(_underrunTimer); _underrunTimer = undefined; }
		} else {
			await _invoke('start_device_monitor');
			monitorActive = true;
			const { listen } = await import('@tauri-apps/api/event');
			_unsubDeviceEvent = await listen<{ type: string; name: string }>('device:event', (event) => {
				deviceEvents = [{ type: event.payload.type, name: event.payload.name, time: Date.now() }, ...deviceEvents].slice(0, 20);
			});
			_underrunTimer = setInterval(async () => {
				try { underrunCount = await _invoke!('get_underrun_count'); } catch { /* 轮询瞬时失败忽略 */ }
			}, 2000);
		}
	}

	// ── 导出播放列表 ──
	async function exportPlaylist(format: 'm3u' | 'pls' | 'auto') {
		if (!_invoke || playlist.queue.length === 0) return;
		const ext = format === 'm3u' ? 'm3u' : format === 'pls' ? 'pls' : 'm3u';
		const path = await save({
			filters: [{ name: 'Playlist', extensions: [ext] }],
			defaultPath: `playlist.${ext}`,
			title: t('settings.export_playlist'),
		});
		if (!path) return;
		const entries = playlist.queue.map((t, i) => ({
			path: t.path,
			title: t.title || '',
			artist: t.artist || '',
			album: t.album || '',
			duration: t.duration || 0,
		}));
		const cmd = format === 'm3u' ? 'export_playlist_m3u' : format === 'pls' ? 'export_playlist_pls' : 'export_playlist_auto';
		try {
			await _invoke(cmd, { path, entries });
			console.log(`Playlist exported to ${path}`);
		} catch (e) { console.error('Export failed:', e); }
	}
</script>

<div class="settings-page">
	<!-- ── 音频 ── -->
	<div class="card">
		<div class="card-header">
			<h3 class="card-title">{t('settings.audio')}</h3>
		</div>
		<div class="card-body">
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
			<div class="setting-row">
				<div class="setting-label">
					<span class="label-text">{t('settings.replaygain')}</span>
					<span class="label-desc">{t('settings.replaygain_desc')}</span>
				</div>
				<button class="toggle" class:active={settings.replaygainEnabled} onclick={toggleReplaygain} aria-label={t('settings.toggle_replaygain')}>
					<span class="toggle-knob"></span>
				</button>
			</div>
			<div class="setting-row">
				<div class="setting-label">
					<span class="label-text">{t('settings.capture')}</span>
					<span class="label-desc">{t('settings.capture_desc')}</span>
				</div>
				<button class="toggle" class:active={playback.capturing} onclick={() => playback.capturing ? playback.stopCapture() : playback.startCapture()} aria-label={t('settings.toggle_capture')}>
					<span class="toggle-knob"></span>
				</button>
			</div>

			<!-- 高级引擎配置 -->
			<button class="advanced-toggle" onclick={() => showAdvanced = !showAdvanced}>
				<span class="advanced-icon" class:open={showAdvanced}>▶</span>
				{t('settings.advanced')}
			</button>
			{#if showAdvanced}
				<div class="advanced-section">
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
							<span class="label-text">{t('settings.auto_sample_rate')}</span>
							<span class="label-desc">{t('settings.auto_sample_rate_desc')}</span>
						</div>
						<button class="toggle" class:active={settings.autoSampleRate} onclick={() => { settings.autoSampleRate = !settings.autoSampleRate; applyEngineConfig(); }} aria-label="{t('settings.auto_sample_rate')}">
							<span class="toggle-knob"></span>
						</button>
					</div>
					<div class="setting-row">
						<div class="setting-label">
							<span class="label-text">{t('settings.exclusive_mode')}</span>
							<span class="label-desc">{t('settings.exclusive_mode_desc')}</span>
						</div>
						<button class="toggle" class:active={settings.exclusiveMode} onclick={() => { settings.exclusiveMode = !settings.exclusiveMode; applyEngineConfig(); }} aria-label="{t('settings.exclusive_mode')}">
							<span class="toggle-knob"></span>
						</button>
					</div>
					<div class="setting-row">
						<div class="setting-label">
							<span class="label-text">{t('settings.dsd_mode')}</span>
							<span class="label-desc">{t('settings.dsd_mode_desc')}</span>
						</div>
						<select class="select" value={settings.dsdMode} onchange={(e) => settings.setDsdMode((e.currentTarget as HTMLSelectElement).value as 'to_pcm' | 'dop')}>
							<option value="to_pcm">{t('settings.dsd_to_pcm')}</option>
							<option value="dop">{t('settings.dsd_dop')}</option>
						</select>
					</div>
					<div class="setting-row">
						<div class="setting-label">
							<span class="label-text">{t('settings.limiter')}</span>
							<span class="label-desc">{t('settings.limiter_desc')}</span>
						</div>
						<button class="toggle" class:active={settings.limiterEnabled} onclick={() => settings.setLimiter(!settings.limiterEnabled)} aria-label="{t('settings.limiter')}">
							<span class="toggle-knob"></span>
						</button>
					</div>
					<div class="setting-row">
						<div class="setting-label">
							<span class="label-text">{t('settings.dither')}</span>
							<span class="label-desc">{t('settings.dither_desc')}</span>
						</div>
						<button class="toggle" class:active={settings.ditherEnabled} onclick={() => settings.setDither(!settings.ditherEnabled)} aria-label="{t('settings.dither')}">
							<span class="toggle-knob"></span>
						</button>
					</div>
				</div>
			{/if}
		</div>
	</div>

	<!-- ── 设备监视器 ── -->
	<div class="card">
		<div class="card-header">
			<h3 class="card-title"><Radio size={14} style="margin-right: 6px;" /> {t('settings.device_monitor')}</h3>
			<button class="btn-add" class:active={monitorActive} onclick={toggleMonitor}>
				{monitorActive ? t('settings.stop_monitor') : t('settings.start_monitor')}
			</button>
		</div>
		<div class="card-body">
			<div class="setting-row">
				<div class="setting-label">
					<span class="label-text">{t('settings.underrun')}</span>
					<span class="label-desc">{t('settings.underrun_desc')}</span>
				</div>
				<span class="badge" class:badge-warn={underrunCount > 10}>{underrunCount}</span>
			</div>
			<div class="setting-label">
				<span class="label-text">{t('settings.device_events')}</span>
			</div>
			<div class="events-list">
				{#if deviceEvents.length === 0}
					<p class="empty-hint">{t('settings.no_events')}</p>
				{:else}
					{#each deviceEvents as ev (ev.time + ev.name)}
						<div class="event-row" class:event-added={ev.type === 'added'} class:event-removed={ev.type === 'removed'}>
							<span class="event-dot" class:dot-added={ev.type === 'added'} class:dot-removed={ev.type === 'removed'}></span>
							<span class="event-type">{ev.type === 'added' ? '+' : ev.type === 'removed' ? '−' : '⟳'}</span>
							<span class="event-name">{ev.name || '(default changed)'}</span>
							<span class="event-time">{new Date(ev.time).toLocaleTimeString()}</span>
						</div>
					{/each}
				{/if}
			</div>
		</div>
	</div>

	<!-- ── 导出播放列表 ── -->
	<div class="card">
		<div class="card-header">
			<h3 class="card-title"><ListMusic size={14} style="margin-right: 6px;" /> {t('settings.export_playlist')}</h3>
		</div>
		<div class="card-body">
			<p class="label-desc" style="margin-bottom: 8px;">{t('settings.export_hint')} ({playlist.queue.length} tracks)</p>
			<div class="btn-row">
				<button class="btn" onclick={() => exportPlaylist('m3u')} disabled={playlist.queue.length === 0}>
					<Activity size={12} /> {t('settings.export_m3u')}
				</button>
				<button class="btn" onclick={() => exportPlaylist('pls')} disabled={playlist.queue.length === 0}>
					<Activity size={12} /> {t('settings.export_pls')}
				</button>
				<button class="btn" onclick={() => exportPlaylist('auto')} disabled={playlist.queue.length === 0}>
					<Activity size={12} /> {t('settings.export_auto')}
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
	.slider::-webkit-slider-thumb { -webkit-appearance: none; width: 12px; height: 12px; border-radius: 50%; background: var(--accent, #e2a63d); cursor: pointer; }
	.slider-val { font-size: 11px; color: var(--fg-tertiary); min-width: 50px; text-align: right; }


	.toggle { display: inline-flex; align-items: center; padding: 4px; border: none; background: var(--bg-hover); border-radius: 20px; cursor: pointer; transition: all 0.2s; width: 52px; height: 26px; position: relative; }
	.toggle.active { background: var(--accent, #e2a63d); }
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

	.events-list { display: flex; flex-direction: column; gap: 4px; max-height: 160px; overflow-y: auto; background: rgba(0,0,0,0.1); border-radius: 8px; padding: 6px 8px; }
	.event-row { display: flex; align-items: center; gap: 8px; padding: 4px 6px; border-radius: 4px; font-size: 11px; }
	.event-row.event-added { color: #44cc88; }
	.event-row.event-removed { color: #ef4444; }
	.event-dot { width: 6px; height: 6px; border-radius: 50%; flex-shrink: 0; }
	.dot-added { background: #44cc88; }
	.dot-removed { background: #ef4444; }
	.event-type { font-variant-numeric: tabular-nums; min-width: 12px; font-weight: 600; }
	.event-name { flex: 1; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
	.event-time { color: var(--fg-quaternary); flex-shrink: 0; }
	.badge { padding: 2px 10px; border-radius: 10px; font-size: 12px; font-variant-numeric: tabular-nums; background: rgba(255,255,255,0.06); color: var(--fg-secondary); }
	.badge.badge-warn { background: rgba(239,68,68,0.15); color: #ef4444; }
	.btn { display: inline-flex; align-items: center; gap: 6px; padding: 7px 14px; border-radius: 8px; border: 1px solid var(--separator); background: var(--bg-surface); color: var(--fg-secondary); font-size: 12px; font-family: inherit; cursor: pointer; transition: all 0.15s; }
	.btn:hover { background: var(--bg-hover); color: var(--fg-primary); }
	.btn:disabled { opacity: 0.4; cursor: default; }
	.btn-row { display: flex; gap: 8px; flex-wrap: wrap; }
	.btn-add.active { background: rgba(239,68,68,0.15); color: #ef4444; border-color: rgba(239,68,68,0.2); }

	.advanced-toggle {
		display: flex; align-items: center; gap: 6px; padding: 6px 0; border: none;
		background: transparent; color: var(--fg-tertiary); font-size: 11px; font-weight: 500;
		cursor: pointer; transition: color 0.15s; width: 100%; text-align: left;
	}
	.advanced-toggle:hover { color: var(--fg-secondary); }
	.advanced-icon { font-size: 8px; transition: transform 0.15s; }
	.advanced-icon.open { transform: rotate(90deg); }
	.advanced-section {
		padding: 12px 0 0; border-top: 1px solid var(--separator);
		display: flex; flex-direction: column; gap: 16px;
	}
</style>
