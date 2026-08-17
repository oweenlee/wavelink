<script lang="ts">
	import { invoke } from '@tauri-apps/api/core';
	import { browser } from '$app/environment';
	import { Music, Plus, X, Loader, Search, Play, Radio, RefreshCw } from 'lucide-svelte';
	import { t } from '$lib/i18n/i18n.svelte';
	import PasswordInput from '$lib/components/controls/PasswordInput.svelte';
	import { getPlaybackState } from '$lib/stores/playback.svelte';
	import type { Track } from '$lib/audio/types';

	interface SubsonicConfig {
		base_url: string;
		username: string;
		password: string;
	}

	interface SubsonicSong {
		id: string;
		title: string;
		artist: string;
		album: string;
		duration_ms: number;
		stream_url: string;
		cover_url: string;
		path: string;
	}

	const playback = getPlaybackState();

	let config = $state<SubsonicConfig>({ base_url: '', username: '', password: '' });
	let loaded = $state(false);
	let showDialog = $state(false);
	let testing = $state(false);
	let scanning = $state(false);
	let searching = $state(false);
	let error = $state('');
	let songs = $state<SubsonicSong[]>([]);
	let query = $state('');
	let queryInput = $state('');

	$effect(() => {
		if (browser && !loaded) {
			loaded = true;
			(async () => {
				try {
					const cfg = (await invoke('subsonic_get_config')) as SubsonicConfig;
					config = { base_url: cfg.base_url || '', username: cfg.username || '', password: cfg.password || '' };
				} catch { /* 无配置时忽略 */ }
			})();
		}
	});

	async function handleTest() {
		if (!config.base_url) return;
		testing = true;
		error = '';
		try {
			await invoke('subsonic_test_connection', {
				baseUrl: config.base_url, username: config.username, password: config.password,
			});
			await handleSave();
			await handleScan();
		} catch (e) {
			error = String(e);
		} finally {
			testing = false;
		}
	}

	async function handleSave() {
		error = '';
		await invoke('subsonic_save_config', { config });
	}

	async function handleScan() {
		if (!config.base_url) return;
		scanning = true;
		error = '';
		try {
			songs = (await invoke('subsonic_scan', {
				baseUrl: config.base_url, username: config.username, password: config.password,
			})) as SubsonicSong[];
			await handleSave();
		} catch (e) {
			error = String(e);
		} finally {
			scanning = false;
		}
	}

	async function handleSearch() {
		if (!config.base_url || !queryInput.trim()) return;
		searching = true;
		error = '';
		try {
			songs = (await invoke('subsonic_search', {
				baseUrl: config.base_url, username: config.username, password: config.password, query: queryInput.trim(),
			})) as SubsonicSong[];
		} catch (e) {
			error = String(e);
		} finally {
			searching = false;
		}
	}

	async function handlePlay(song: SubsonicSong) {
		error = '';
		try {
			const localPath = (await invoke('subsonic_play', {
				streamUrl: song.stream_url, songId: song.id, pathHint: song.path,
			})) as string;
			const track: Track = {
				id: 0, path: localPath, title: song.title, artist: song.artist, album: song.album,
				album_artist: null, track_number: null, disc_number: null, year: null, genre: null,
				duration: song.duration_ms > 0 ? song.duration_ms / 1000 : null, sample_rate: null,
				channels: null, format: null, file_size: null, file_modified: null, date_added: 0,
				play_count: 0, last_played: null, rating: 0, missing: false,
			};
			await playback.playTrack(track);
		} catch (e) {
			error = String(e);
		}
	}

	function fmtDuration(ms: number): string {
		if (!ms || ms <= 0) return '';
		const s = Math.round(ms / 1000);
		return `${Math.floor(s / 60)}:${String(s % 60).padStart(2, '0')}`;
	}
</script>

<div class="nas-view">
	<div class="header">
		<h1>{t('subsonic.title')}</h1>
		<button class="btn-primary" onclick={() => (showDialog = true)}>
			<Plus size={16} />
			<span>{t('subsonic.configure')}</span>
		</button>
	</div>

	{#if error}
		<div class="error">{error}</div>
	{/if}

	{#if !config.base_url}
		<div class="empty">
			<Radio size={48} stroke-width={1} />
			<p>{t('subsonic.empty')}</p>
			<p class="hint">{t('subsonic.empty_hint')}</p>
		</div>
	{:else}
		<div class="conn-bar">
			<span class="conn-dot"></span>
			<span class="conn-url">{config.base_url}</span>
			<button class="btn-icon" title={t('subsonic.scan')} onclick={handleScan} disabled={scanning}>
				{#if scanning}<Loader size={15} class="spin" />{:else}<RefreshCw size={15} />{/if}
			</button>
		</div>

		<div class="search-row">
			<input
				type="text"
				bind:value={queryInput}
				placeholder={t('subsonic.search_placeholder')}
				onkeydown={(e) => e.key === 'Enter' && handleSearch()}
			/>
			<button class="btn-secondary" onclick={handleSearch} disabled={searching || !queryInput.trim()}>
				{#if searching}<Loader size={14} class="spin" />{:else}<Search size={14} />{/if}
				<span>{t('subsonic.search')}</span>
			</button>
		</div>

		{#if songs.length === 0 && !scanning}
			<div class="empty small">
				<Music size={32} stroke-width={1} />
				<p>{t('subsonic.no_songs')}</p>
			</div>
		{:else}
			<div class="song-list">
				{#each songs as song (song.id)}
					<button class="song-row" onclick={() => handlePlay(song)}>
						<div class="song-idx">
							<Play size={13} fill="currentColor" />
						</div>
						<div class="song-info">
							<div class="song-title">{song.title}</div>
							<div class="song-meta">{song.artist} · {song.album}</div>
						</div>
						<span class="song-dur">{fmtDuration(song.duration_ms)}</span>
					</button>
				{/each}
			</div>
		{/if}
	{/if}
</div>

{#if showDialog}
	<div class="overlay">
		<div class="dialog" role="dialog" tabindex="-1">
			<div class="dialog-header">
				<h2>{t('subsonic.dialog_title')}</h2>
				<button class="btn-icon" onclick={() => (showDialog = false)}><X size={18} /></button>
			</div>
			<div class="dialog-body">
				<label class="field">
					<span>{t('subsonic.base_url')}</span>
					<input type="text" bind:value={config.base_url} placeholder="http://192.168.1.100:4533" />
				</label>
				<label class="field">
					<span>{t('subsonic.username')}</span>
					<input type="text" bind:value={config.username} placeholder="admin" />
				</label>
				<label class="field">
					<span>{t('subsonic.password')}</span>
					<PasswordInput bind:value={config.password} />
				</label>
			</div>
			<div class="dialog-footer">
				<button class="btn-secondary" onclick={() => (showDialog = false)}>{t('subsonic.cancel')}</button>
				<button class="btn-primary" disabled={!config.base_url} onclick={handleTest}>
					{#if testing}<Loader size={14} class="spin" />{:else}<Radio size={14} />{/if}
					<span>{t('subsonic.test_save')}</span>
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

	.conn-bar {
		display: flex; align-items: center; gap: var(--space-2);
		padding: var(--space-2) var(--space-3); background: var(--glass-bg);
		border-radius: var(--radius-md); margin-bottom: var(--space-3);
	}
	.conn-dot { width: 8px; height: 8px; border-radius: 50%; background: #4ec9a0; flex-shrink: 0; }
	.conn-url { flex: 1; font-size: 12px; color: var(--fg-secondary); font-family: var(--font-mono, monospace); overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }

	.search-row { display: flex; gap: var(--space-2); margin-bottom: var(--space-4); }
	.search-row input {
		flex: 1; padding: var(--space-2) var(--space-3); border: 1px solid var(--glass-border);
		border-radius: var(--radius-sm); background: var(--bg-active);
		color: var(--fg-primary); font-size: 13px; font-family: inherit; outline: none;
		transition: border-color 0.12s;
	}
	.search-row input:focus { border-color: var(--accent); }

	.song-list { display: flex; flex-direction: column; gap: 2px; }

	.song-row {
		display: flex; align-items: center; gap: var(--space-3);
		padding: var(--space-2) var(--space-3); border: none; border-radius: var(--radius-sm);
		background: transparent; color: var(--fg-primary); cursor: pointer;
		text-align: left; font-family: inherit; transition: background 0.12s; width: 100%;
	}
	.song-row:hover { background: var(--bg-hover); }

	.song-idx {
		width: 24px; height: 24px; border-radius: var(--radius-sm); flex-shrink: 0;
		display: flex; align-items: center; justify-content: center;
		background: var(--bg-active); color: var(--fg-tertiary);
	}
	.song-row:hover .song-idx { color: var(--accent); }

	.song-info { flex: 1; min-width: 0; }
	.song-title { font-size: 13px; font-weight: 500; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
	.song-meta { font-size: 11px; color: var(--fg-tertiary); overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
	.song-dur { font-size: 11px; color: var(--fg-quaternary); font-variant-numeric: tabular-nums; flex-shrink: 0; }

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
	.btn-secondary:disabled { opacity: 0.4; cursor: not-allowed; }

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
	.field input:focus { border-color: var(--accent); box-shadow: 0 0 0 3px color-mix(in srgb, var(--accent) 12%, transparent); }

	:global(.spin) { animation: spin 1s linear infinite; }
	@keyframes spin { to { transform: rotate(360deg); } }
</style>