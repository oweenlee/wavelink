<script lang="ts">
	import { invoke } from '@tauri-apps/api/core';
	import { browser } from '$app/environment';
	import { Folder, File, ChevronLeft, Plus, X, Loader, Play, RefreshCw, HardDrive } from 'lucide-svelte';
	import { t } from '$lib/i18n/i18n.svelte';
	import { getPlaybackState } from '$lib/stores/playback.svelte';
	import type { Track } from '$lib/audio/types';

	interface WebdavConfig {
		base_url: string;
		path: string;
		username: string;
		password: string;
	}

	interface WebdavEntry {
		name: string;
		url: string;
		is_dir: boolean;
		size: number;
		ext: string;
	}

	const playback = getPlaybackState();

	let config = $state<WebdavConfig>({ base_url: '', path: '', username: '', password: '' });
	let loaded = $state(false);
	let showDialog = $state(false);
	let testing = $state(false);
	let scanning = $state(false);
	let loading = $state(false);
	let error = $state('');
	let entries = $state<WebdavEntry[]>([]);
	let currentPath = $state('');
	const dirStack = $state<string[]>([]);

	$effect(() => {
		if (browser && !loaded) {
			loaded = true;
			(async () => {
				try {
					const cfg = (await invoke('webdav_get_config')) as WebdavConfig;
					config = { base_url: cfg.base_url || '', path: cfg.path || '', username: cfg.username || '', password: cfg.password || '' };
				} catch { /* 无配置时忽略 */ }
			})();
		}
	});

	function joinPath(base: string, rel: string): string {
		const b = base.replace(/\/+$/, '');
		if (!rel) return b + '/';
		return `${b}/${rel.replace(/^\/+/, '')}`;
	}

	async function handleTest() {
		if (!config.base_url) return;
		testing = true;
		error = '';
		try {
			await invoke('webdav_test_connection', {
				baseUrl: config.base_url, path: config.path, username: config.username, password: config.password,
			});
			await handleSave();
			await handleList(config.path);
		} catch (e) {
			error = String(e);
		} finally {
			testing = false;
		}
	}

	async function handleSave() {
		error = '';
		await invoke('webdav_save_config', { config });
	}

	async function handleList(path: string) {
		if (!config.base_url) return;
		loading = true;
		error = '';
		try {
			entries = (await invoke('webdav_list', {
				baseUrl: config.base_url, path, username: config.username, password: config.password,
			})) as WebdavEntry[];
			currentPath = path;
		} catch (e) {
			error = String(e);
		} finally {
			loading = false;
		}
	}

	async function handleScan() {
		if (!config.base_url) return;
		scanning = true;
		error = '';
		try {
			entries = (await invoke('webdav_scan', {
				baseUrl: config.base_url, path: config.path, username: config.username, password: config.password,
			})) as WebdavEntry[];
			await handleSave();
		} catch (e) {
			error = String(e);
		} finally {
			scanning = false;
		}
	}

	function openDir(entry: WebdavEntry) {
		if (!entry.is_dir) return;
		dirStack.push(currentPath);
		handleList(entry.url);
	}

	function goUp() {
		const prev = dirStack.pop();
		if (prev !== undefined) handleList(prev);
		else handleList(config.path);
	}

	async function handlePlay(entry: WebdavEntry) {
		error = '';
		try {
			const localPath = (await invoke('webdav_play', {
				url: entry.url, name: entry.name, username: config.username, password: config.password,
			})) as string;
			const track: Track = {
				id: 0, path: localPath, title: entry.name.replace(/\.[^.]+$/, ''), artist: t('webdav.unknown_artist'),
				album: t('webdav.album_placeholder'), album_artist: null, track_number: null, disc_number: null,
				year: null, genre: null, duration: null, sample_rate: null, channels: null, format: entry.ext || null,
				file_size: entry.size || null, file_modified: null, date_added: 0, play_count: 0, last_played: null,
				rating: 0, missing: false,
			};
			await playback.playTrack(track);
		} catch (e) {
			error = String(e);
		}
	}

	function fmtSize(bytes: number): string {
		if (!bytes) return '';
		if (bytes < 1024) return `${bytes} B`;
		if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`;
		return `${(bytes / 1024 / 1024).toFixed(1)} MB`;
	}
</script>

<div class="nas-view">
	<div class="header">
		<h1>{t('webdav.title')}</h1>
		<button class="btn-primary" onclick={() => (showDialog = true)}>
			<Plus size={16} />
			<span>{t('webdav.configure')}</span>
		</button>
	</div>

	{#if error}
		<div class="error">{error}</div>
	{/if}

	{#if !config.base_url}
		<div class="empty">
			<HardDrive size={48} stroke-width={1} />
			<p>{t('webdav.empty')}</p>
			<p class="hint">{t('webdav.empty_hint')}</p>
		</div>
	{:else}
		<div class="conn-bar">
			<span class="conn-dot"></span>
			<span class="conn-url">{config.base_url}{config.path ? '/' + config.path : ''}</span>
			<button class="btn-icon" title={t('webdav.scan')} onclick={handleScan} disabled={scanning}>
				{#if scanning}<Loader size={15} class="spin" />{:else}<RefreshCw size={15} />{/if}
			</button>
		</div>

		<div class="path-bar">
			<button class="btn-icon" title={t('webdav.up')} onclick={goUp} disabled={dirStack.length === 0}>
				<ChevronLeft size={15} />
			</button>
			<span class="path-text">{currentPath || config.path || '/'}</span>
		</div>

		{#if loading}
			<div class="loading"><Loader size={20} class="spin" /> {t('webdav.loading')}</div>
		{:else if entries.length === 0}
			<div class="empty small">
				<Folder size={32} stroke-width={1} />
				<p>{t('webdav.no_entries')}</p>
			</div>
		{:else}
			<div class="song-list">
				{#each entries as entry (entry.url)}
					{#if entry.is_dir}
						<button class="song-row dir" onclick={() => openDir(entry)}>
							<div class="entry-icon"><Folder size={15} /></div>
							<div class="song-info">
								<div class="song-title">{entry.name}</div>
								<div class="song-meta">{t('webdav.folder')}</div>
							</div>
						</button>
					{:else}
						<button class="song-row" onclick={() => handlePlay(entry)}>
							<div class="entry-icon audio"><Play size={13} fill="currentColor" /></div>
							<div class="song-info">
								<div class="song-title">{entry.name}</div>
								<div class="song-meta">{fmtSize(entry.size)}</div>
							</div>
						</button>
					{/if}
				{/each}
			</div>
		{/if}
	{/if}
</div>

{#if showDialog}
	<div class="overlay">
		<div class="dialog" role="dialog" tabindex="-1">
			<div class="dialog-header">
				<h2>{t('webdav.dialog_title')}</h2>
				<button class="btn-icon" onclick={() => (showDialog = false)}><X size={18} /></button>
			</div>
			<div class="dialog-body">
				<label class="field">
					<span>{t('webdav.base_url')}</span>
					<input type="text" bind:value={config.base_url} placeholder="http://192.168.1.100/webdav" />
				</label>
				<label class="field">
					<span>{t('webdav.path')}</span>
					<input type="text" bind:value={config.path} placeholder="music" />
				</label>
				<label class="field">
					<span>{t('webdav.username')}</span>
					<input type="text" bind:value={config.username} placeholder="user" />
				</label>
				<label class="field">
					<span>{t('webdav.password')}</span>
					<input type="password" bind:value={config.password} />
				</label>
			</div>
			<div class="dialog-footer">
				<button class="btn-secondary" onclick={() => (showDialog = false)}>{t('webdav.cancel')}</button>
				<button class="btn-primary" disabled={!config.base_url} onclick={handleTest}>
					{#if testing}<Loader size={14} class="spin" />{:else}<HardDrive size={14} />{/if}
					<span>{t('webdav.test_save')}</span>
				</button>
			</div>
		</div>
	</div>
{/if}

<style>
	.nas-view { padding: var(--space-6); max-width: 720px; }

	.header { display: flex; align-items: center; justify-content: space-between; margin-bottom: var(--space-6); }
	.header h1 { font-size: 20px; font-weight: 600; color: var(--fg-primary); margin: 0; }

	.error { color: #e85d5d; font-size: 13px; padding: var(--space-3); background: rgba(232,93,93,0.1); border-radius: var(--radius-md); margin-bottom: var(--space-4); }

	.empty { display: flex; flex-direction: column; align-items: center; gap: var(--space-3); padding: var(--space-12) 0; color: var(--fg-tertiary); }
	.empty p { margin: 0; font-size: 14px; }
	.empty .hint { font-size: 12px; color: var(--fg-quaternary); }
	.empty.small { padding: var(--space-8) 0; }

	.loading { display: flex; align-items: center; gap: var(--space-2); color: var(--fg-tertiary); font-size: 13px; padding: var(--space-8) 0; justify-content: center; }

	.conn-bar {
		display: flex; align-items: center; gap: var(--space-2);
		padding: var(--space-2) var(--space-3); background: var(--glass-bg);
		border-radius: var(--radius-md); margin-bottom: var(--space-2);
	}
	.conn-dot { width: 8px; height: 8px; border-radius: 50%; background: #4ec9a0; flex-shrink: 0; }
	.conn-url { flex: 1; font-size: 12px; color: var(--fg-secondary); font-family: var(--font-mono, monospace); overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }

	.path-bar { display: flex; align-items: center; gap: var(--space-2); padding: var(--space-1) var(--space-3); margin-bottom: var(--space-3); }
	.path-text { font-size: 12px; color: var(--fg-tertiary); font-family: var(--font-mono, monospace); overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }

	.song-list { display: flex; flex-direction: column; gap: 2px; }

	.song-row {
		display: flex; align-items: center; gap: var(--space-3);
		padding: var(--space-2) var(--space-3); border: none; border-radius: var(--radius-sm);
		background: transparent; color: var(--fg-primary); cursor: pointer;
		text-align: left; font-family: inherit; transition: background 0.12s; width: 100%;
	}
	.song-row:hover { background: var(--bg-hover); }
	.song-row.dir:hover .song-title { color: var(--accent); }

	.entry-icon {
		width: 24px; height: 24px; border-radius: var(--radius-sm); flex-shrink: 0;
		display: flex; align-items: center; justify-content: center;
		background: var(--bg-active); color: var(--fg-tertiary);
	}
	.entry-icon.audio { color: var(--accent); }

	.song-info { flex: 1; min-width: 0; }
	.song-title { font-size: 13px; font-weight: 500; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
	.song-meta { font-size: 11px; color: var(--fg-tertiary); overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }

	.btn-primary {
		display: inline-flex; align-items: center; gap: var(--space-1);
		padding: var(--space-2) var(--space-4); border: none; border-radius: var(--radius-sm);
		background: var(--accent); color: #fff; font-size: 13px; font-family: inherit; font-weight: 500;
		cursor: pointer; transition: opacity 0.12s;
	}
	.btn-primary:hover { opacity: 0.9; }
	.btn-primary:disabled { opacity: 0.4; cursor: not-allowed; }

	.btn-secondary {
		display: inline-flex; align-items: center; gap: var(--space-1);
		padding: var(--space-2) var(--space-4); border: none; border-radius: var(--radius-sm);
		background: var(--bg-active); color: var(--fg-secondary); font-size: 13px; font-family: inherit;
		cursor: pointer; transition: all 0.12s;
	}
	.btn-secondary:hover { background: var(--bg-hover); color: var(--fg-primary); }

	.btn-icon {
		width: 30px; height: 30px; border: none; border-radius: var(--radius-sm);
		background: transparent; color: var(--fg-secondary); cursor: pointer;
		display: flex; align-items: center; justify-content: center; transition: all 0.12s;
	}
	.btn-icon:hover { background: var(--bg-hover); color: var(--fg-primary); }
	.btn-icon:disabled { opacity: 0.4; cursor: not-allowed; }

	.overlay {
		position: fixed; inset: 0; z-index: 100;
		background: rgba(0,0,0,0.5);
		display: flex; align-items: center; justify-content: center;
		backdrop-filter: blur(4px);
	}
	.dialog {
		width: 420px; max-width: 90vw;
		background: var(--bg); border-radius: var(--radius-lg);
		border: 1px solid var(--glass-border);
		box-shadow: 0 20px 60px rgba(0,0,0,0.3);
	}
	.dialog-header { display: flex; align-items: center; justify-content: space-between; padding: var(--space-4) var(--space-5); border-bottom: 1px solid var(--glass-border); }
	.dialog-header h2 { margin: 0; font-size: 16px; font-weight: 600; }
	.dialog-body { padding: var(--space-4) var(--space-5); display: flex; flex-direction: column; gap: var(--space-3); }
	.dialog-footer { display: flex; justify-content: flex-end; gap: var(--space-2); padding: var(--space-3) var(--space-5); border-top: 1px solid var(--glass-border); }

	.field { display: flex; flex-direction: column; gap: var(--space-1); }
	.field span { font-size: 12px; font-weight: 500; color: var(--fg-secondary); }
	.field input {
		padding: var(--space-2) var(--space-3); border: 1px solid var(--glass-border);
		border-radius: var(--radius-sm); background: var(--bg-active);
		color: var(--fg-primary); font-size: 13px; font-family: inherit;
		outline: none; transition: border-color 0.12s;
	}
	.field input:focus { border-color: var(--accent); }

	:global(.spin) { animation: spin 1s linear infinite; }
	@keyframes spin { to { transform: rotate(360deg); } }
</style>