<script lang="ts">
	import { invoke } from '@tauri-apps/api/core';
	import { browser } from '$app/environment';
	import { ListMusic, Upload, Play, RefreshCw, FileText } from 'lucide-svelte';
	import { t } from '$lib/i18n/i18n.svelte';
	import type { CueSheet, Track } from '$lib/audio/types';
	import { getPlaybackState } from '$lib/stores/playback.svelte';

	// 全部虚轨（展平后的可播列表）
	interface FlatTrack {
		num: string;
		title: string;
		performer: string | null;
		audio_file: string; // CUE 所在目录 + 相对路径
		start_secs: number;
		index: number; // 全局虚轨序号（0 起）
	}

	let cueText = $state('');
	let sheet = $state<CueSheet | null>(null);
	let tracks = $state<FlatTrack[]>([]);
	let cueDir = $state('');
	let cuePath = $state('');
	let loading = $state(false);
	let playing = $state(false);
	let error = $state('');

	function fmtTime(secs: number): string {
		const m = Math.floor(secs / 60);
		const s = Math.floor(secs % 60);
		return `${m}:${s.toString().padStart(2, '0')}`;
	}

	// 将 CueSheet 展平为可播轨道列表
	function flatten(s: CueSheet, dir: string): FlatTrack[] {
		const out: FlatTrack[] = [];
		let idx = 0;
		for (const file of s.files) {
			for (const tr of file.tracks) {
				out.push({
					num: tr.num,
					title: tr.title || `${file.path} #${tr.num}`,
					performer: tr.performer,
					audio_file: dir ? `${dir}/${file.path}` : file.path,
					start_secs: tr.start_secs,
					index: idx++,
				});
			}
		}
		return out;
	}

	async function importCue() {
		if (!browser) return;
		try {
			const { open } = await import('@tauri-apps/plugin-dialog');
			const path = await open({ filters: [{ name: 'CUE', extensions: ['cue'] }], multiple: false });
			if (!path) return;
			const text = (await invoke('read_text_file', { path })) as string;
			await parseText(String(text));
			cuePath = String(path);
			const idx = cuePath.lastIndexOf('/');
			cueDir = idx >= 0 ? cuePath.slice(0, idx) : '';
		} catch {
			error = t('cue.error_read');
		}
	}

	async function parseText(text: string) {
		loading = true;
		error = '';
		try {
			const s = (await invoke('parse_cue_text', { data: text })) as CueSheet;
			sheet = s;
			tracks = flatten(s, cueDir);
			cueText = text;
		} catch (e) {
			error = String(e);
			sheet = null;
			tracks = [];
		} finally {
			loading = false;
		}
	}

	// 虚轨 → 前端快照 Track：path 用 `${cuePath}#${i}` 镜像键（仅展示/索引同步，
	// 不参与引擎解析；引擎播放走 play_queue_at 展开 cuePath）
	function toQueueTrack(tr: FlatTrack, cuePath: string, i: number): Track {
		return {
			id: -(i + 1),
			path: `${cuePath}#${i}`,
			title: tr.title,
			artist: tr.performer ?? null,
			album: null,
			album_artist: null,
			track_number: parseInt(tr.num, 10) || null,
			disc_number: null,
			year: null,
			genre: null,
			format: 'cue',
			duration: null,
			sample_rate: null,
			channels: null,
			file_size: null,
			file_modified: null,
			date_added: 0,
			play_count: 0,
			last_played: null,
			rating: 0,
			missing: false,
		};
	}

	// 播放指定分轨：整碟交给引擎（自动展开虚轨），从第 n 轨开始播
	async function playTrackN(n: number) {
		if (!cuePath || tracks.length === 0) return;
		playing = true;
		error = '';
		try {
			const playback = getPlaybackState();
			await playback.playCueTracks(
				cuePath,
				tracks.map((tr, i) => toQueueTrack(tr, cuePath, i)),
				n
			);
		} catch (e) {
			error = String(e);
		} finally {
			playing = false;
		}
	}
</script>

<div class="cue-view">
	<div class="header">
		<h2 class="title">{t('cue.title')}</h2>
		<p class="desc">{t('cue.hint')}</p>
		<div class="actions">
			<button class="btn" onclick={importCue}>
				<Upload size={14} />
				<span>{t('cue.import')}</span>
			</button>
		</div>
	</div>

	{#if error}
		<div class="error-banner">{error}</div>
	{/if}

	{#if !sheet}
		<div class="empty">
			<ListMusic size={40} stroke-width={1} />
			<p>{t('cue.empty')}</p>
		</div>
	{:else}
		{#if cuePath}
			<div class="file-bar">
				<FileText size={14} />
				<span>{cuePath}</span>
			</div>
		{/if}

		{#if tracks.length === 0}
			<div class="empty">
				<p>{t('cue.no_tracks')}</p>
			</div>
		{:else}
			<div class="track-list">
				{#each tracks as tr (tr.index)}
					<button class="track-row" onclick={() => playTrackN(tr.index)} disabled={playing}>
						<span class="t-num">{tr.num}</span>
						<span class="t-title">{tr.title}</span>
						{#if tr.performer}
							<span class="t-artist">{tr.performer}</span>
						{/if}
						<span class="t-time">{fmtTime(tr.start_secs)}</span>
						<span class="t-play">
							{#if playing}
								<RefreshCw size={14} class="spin" />
							{:else}
								<Play size={14} />
							{/if}
						</span>
					</button>
				{/each}
			</div>
		{/if}
	{/if}
</div>

<style>
	.cue-view { padding: var(--space-6); display: flex; flex-direction: column; gap: var(--space-5); max-width: 820px; margin: 0 auto; }

	.header { display: flex; flex-direction: column; gap: 6px; }
	.title { font-size: 22px; font-weight: 600; color: var(--fg-primary); margin: 0; }
	.desc { font-size: 13px; color: var(--fg-tertiary); margin: 0; }
	.actions { margin-top: var(--space-2); }

	.btn { display: inline-flex; align-items: center; gap: 6px; padding: 8px 16px; border-radius: var(--radius-md); border: 1px solid var(--separator); background: var(--bg-surface); color: var(--fg-primary); font-size: 13px; font-family: inherit; cursor: pointer; transition: all 0.12s; }
	.btn:hover { background: var(--bg-hover); }
	.btn:disabled { opacity: 0.5; cursor: default; }

	.error-banner { padding: 10px 12px; border-radius: 8px; background: rgba(232, 93, 93, 0.08); border: 1px solid rgba(232, 93, 93, 0.25); font-size: 12px; color: rgba(232, 93, 93, 0.9); }

	.empty { display: flex; flex-direction: column; align-items: center; gap: 12px; padding: 60px 0; color: var(--fg-tertiary); font-size: 13px; }
	.empty :global(svg) { opacity: 0.35; }

	.file-bar { display: flex; align-items: center; gap: 8px; padding: 8px 12px; border-radius: 8px; background: var(--bg-surface); border: 1px solid var(--separator); font-size: 12px; color: var(--fg-secondary); font-family: var(--font-mono); }

	.track-list { display: flex; flex-direction: column; border: 1px solid var(--separator); border-radius: var(--radius-md); overflow: hidden; }
	.track-row { display: flex; align-items: center; gap: 12px; padding: 10px 14px; background: transparent; border: none; border-bottom: 1px solid var(--separator); color: var(--fg-primary); font-size: 13px; font-family: inherit; cursor: pointer; transition: background 0.12s; text-align: left; }
	.track-row:last-child { border-bottom: none; }
	.track-row:hover { background: var(--bg-hover); }
	.track-row:disabled { cursor: default; opacity: 0.6; }
	.t-num { width: 28px; color: var(--fg-tertiary); font-family: var(--font-mono); font-size: 12px; flex-shrink: 0; }
	.t-title { flex: 1; min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
	.t-artist { color: var(--fg-secondary); font-size: 12px; flex-shrink: 0; }
	.t-time { color: var(--fg-tertiary); font-family: var(--font-mono); font-size: 12px; flex-shrink: 0; }
	.t-play { color: var(--accent); display: flex; flex-shrink: 0; }

	.spin { animation: spin 0.8s linear infinite; }
	@keyframes spin { to { transform: rotate(360deg); } }
</style>
