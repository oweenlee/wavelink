<script lang="ts">
	import { browser } from '$app/environment';
	import { getUiState } from '$lib/stores/ui.svelte';
	import { getPlaylistState } from '$lib/stores/playlist.svelte';
	import { getPlaybackState } from '$lib/stores/playback.svelte';
	import { fly } from 'svelte/transition';
	import { cubicOut } from 'svelte/easing';
	import { formatTime } from '$lib/data/music';
	import { X, Plus, ListMusic, Trash2 } from 'lucide-svelte';

	const ui = getUiState();
	const playlist = getPlaylistState();
	const playback = getPlaybackState();

	let newPlaylistName = $state('');
	let creating = $state(false);
	let error = $state('');

	$effect(() => {
		if (browser && ui.showPlaylistPanel) {
			playlist.loadPlaylistNames();
		}
	});

	async function createPlaylist() {
		if (!newPlaylistName.trim()) { error = '请输入名称'; return; }
		if (playlist.queue.length === 0) { error = '当前队列为空'; return; }
		creating = true;
		error = '';
		try {
			await playlist.saveCurrentAs(newPlaylistName.trim());
			newPlaylistName = '';
		} catch (e: any) {
			error = typeof e === 'string' ? e : '创建失败';
		} finally {
			creating = false;
		}
	}

	async function loadPlaylist(name: string) {
		await playlist.loadPlaylist(name);
	}

	async function deletePlaylist(name: string) {
		if (!confirm(`确定删除播放列表「${name}」吗？`)) return;
		await playlist.deletePlaylist(name);
	}

	function closePanel() { ui.showPlaylistPanel = false; }

	let queueDuration = $derived(playlist.queue.reduce((sum, t) => sum + (t.duration || 0), 0));
</script>

{#if ui.showPlaylistPanel}
	<div class="backdrop" onclick={closePanel} role="button" tabindex="0" onkeydown={(e) => e.key === 'Enter' && closePanel()}></div>
{/if}

<div class="playlist-panel" class:visible={ui.showPlaylistPanel} transition:fly={{ x: 420, duration: 300, easing: cubicOut, opacity: 0 }}>
	<div class="panel-header">
		<h3 class="panel-title">播放列表</h3>
		<button class="close-btn" onclick={closePanel} aria-label="关闭">
			<X size={18} />
		</button>
	</div>

	<!-- Current queue -->
	<div class="section">
		<div class="section-header">
			<span class="section-label">当前队列</span>
			<span class="section-count">{playlist.queue.length} 首 · {formatTime(queueDuration)}</span>
		</div>
		{#if playlist.queue.length > 0}
			<div class="queue-list">
				{#each playlist.queue as track, i (track.id)}
					<div class="queue-item" class:active={i === playlist.currentIndex}>
						<button class="qi-play" onclick={() => playlist.playFromIndex(i)} aria-label="播放">
							<span class="qi-num">{i + 1}</span>
							{#if i === playlist.currentIndex && playback.isPlaying}
								<div class="eq-anim"><span></span><span></span><span></span></div>
							{/if}
						</button>
						<div class="qi-info">
							<span class="qi-title">{track.title || track.path.split(/[/\\]/).pop()}</span>
							<span class="qi-artist">{track.artist || '未知'}</span>
						</div>
			<button class="qi-remove" onclick={() => playlist.removeFromQueue(i)} aria-label="移除">
				<X size={12} />
			</button>
					</div>
				{/each}
			</div>
			<button class="save-queue-btn" onclick={() => creating = true}>
				<Plus size={14} />
				<span>保存为播放列表</span>
			</button>
		{:else}
			<p class="empty">队列为空</p>
		{/if}
	</div>

	<!-- Save dialog -->
	{#if creating}
		<div class="save-dialog">
			<input type="text" bind:value={newPlaylistName} placeholder="播放列表名称" class="name-input" onkeydown={(e) => e.key === 'Enter' && createPlaylist()} />
			<div class="save-actions">
				<button class="btn-cancel" onclick={() => { creating = false; error = ''; }}>取消</button>
				<button class="btn-save" onclick={createPlaylist} disabled={creating}>{creating ? '保存中...' : '保存'}</button>
			</div>
			{#if error}<span class="error-msg">{error}</span>{/if}
		</div>
	{/if}

	<!-- Saved playlists -->
	<div class="section">
		<div class="section-header">
			<span class="section-label">已保存的播放列表</span>
			<span class="section-count">{playlist.savedPlaylists.length}</span>
		</div>
		{#if playlist.savedPlaylists.length > 0}
			<div class="saved-list">
				{#each playlist.savedPlaylists as name (name)}
					<div class="saved-item">
						<button class="si-play" onclick={() => loadPlaylist(name)}>
							<ListMusic size={14} stroke-width={1.5} />
							<span class="si-name">{name}</span>
						</button>
						<button class="si-delete" onclick={() => deletePlaylist(name)} aria-label="删除">
							<Trash2 size={12} />
						</button>
					</div>
				{/each}
			</div>
		{:else}
			<p class="empty">暂无已保存的播放列表</p>
		{/if}
	</div>
</div>

<style>
	.backdrop { position: fixed; inset: 0; background: rgba(0, 0, 0, 0.4); z-index: 80; animation: fadeIn 0.3s ease; }
	@keyframes fadeIn { from { opacity: 0; } to { opacity: 1; } }

	.playlist-panel {
		position: fixed; top: 0; right: 0; width: 380px; max-width: 100vw;
		height: 100vh; z-index: 90;
		background: rgba(20, 20, 30, 0.85);
		backdrop-filter: blur(40px); -webkit-backdrop-filter: blur(40px);
		border-left: 1px solid var(--separator);
		display: flex; flex-direction: column;
		transform: translateX(100%);
		box-shadow: -8px 0 40px rgba(0, 0, 0, 0.3);
	}
	.playlist-panel.visible { transform: translateX(0); }

	.panel-header { display: flex; align-items: center; justify-content: space-between; padding: 20px 24px; border-bottom: 1px solid var(--separator); }
	.panel-title { font-size: 16px; font-weight: 600; color: var(--fg-primary); }
	.close-btn { width: 36px; height: 36px; border-radius: var(--radius-md); border: none; background: var(--bg-hover); color: var(--fg-secondary); cursor: pointer; display: flex; align-items: center; justify-content: center; transition: all 0.2s; }
	.close-btn:hover { background: var(--bg-active); color: var(--fg-primary); }

	.section { padding: var(--space-4) var(--space-6); border-bottom: 1px solid var(--separator); }
	.section:last-child { border-bottom: none; }
	.section-header { display: flex; align-items: center; justify-content: space-between; margin-bottom: var(--space-3); }
	.section-label { font-size: 11px; font-weight: 600; color: var(--fg-tertiary); text-transform: uppercase; letter-spacing: 1px; }
	.section-count { font-size: 11px; color: var(--fg-quaternary); }

	.queue-list { max-height: 300px; overflow-y: auto; display: flex; flex-direction: column; gap: 2px; }
	.queue-item { display: flex; align-items: center; gap: var(--space-2); padding: var(--space-2); border-radius: var(--radius-sm); transition: background 0.1s; }
	.queue-item:hover { background: var(--bg-hover); }
	.queue-item.active { background: var(--accent-dim); }

	.qi-play { width: 24px; height: 24px; border: none; background: transparent; color: var(--fg-tertiary); cursor: pointer; display: flex; align-items: center; justify-content: center; font-size: 11px; font-family: inherit; flex-shrink: 0; border-radius: var(--radius-sm); }
	.qi-num { font-variant-numeric: tabular-nums; }
	.qi-info { flex: 1; min-width: 0; display: flex; flex-direction: column; gap: 1px; }
	.qi-title { font-size: 12px; font-weight: 500; color: var(--fg-primary); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
	.qi-artist { font-size: 10px; color: var(--fg-tertiary); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
	.qi-remove { width: 20px; height: 20px; border: none; background: transparent; color: var(--fg-quaternary); cursor: pointer; display: flex; align-items: center; justify-content: center; opacity: 0; transition: all 0.12s; border-radius: var(--radius-sm); }
	.queue-item:hover .qi-remove { opacity: 1; }
	.qi-remove:hover { color: rgba(255, 80, 80, 0.6); background: rgba(255, 80, 80, 0.08); }

	.eq-anim { display: flex; gap: 2px; height: 12px; align-items: flex-end; }
	.eq-anim span { width: 2px; background: var(--accent); border-radius: 2px 2px 0 0; animation: eq 0.5s ease-in-out infinite alternate; }
	.eq-anim span:nth-child(1) { height: 6px; animation-duration: 0.35s; }
	.eq-anim span:nth-child(2) { height: 10px; animation-delay: 0.12s; animation-duration: 0.45s; }
	.eq-anim span:nth-child(3) { height: 4px; animation-delay: 0.25s; animation-duration: 0.38s; }
	@keyframes eq { 0% { transform: scaleY(0.3); } 100% { transform: scaleY(1); } }

	.save-queue-btn { display: flex; align-items: center; gap: var(--space-2); padding: var(--space-2) var(--space-3); margin-top: var(--space-3); border: 1px dashed var(--separator); border-radius: var(--radius-sm); background: transparent; color: var(--fg-tertiary); font-size: 12px; font-family: inherit; cursor: pointer; transition: all 0.12s; width: 100%; }
	.save-queue-btn:hover { border-color: var(--accent-dim); color: var(--accent); }

	.save-dialog { margin-top: var(--space-3); padding: var(--space-3); background: var(--bg-hover); border-radius: var(--radius-md); display: flex; flex-direction: column; gap: var(--space-2); }
	.name-input { padding: 8px 12px; border-radius: var(--radius-sm); border: 1px solid var(--separator); background: var(--bg-surface); color: var(--fg-primary); font-size: 13px; font-family: inherit; outline: none; }
	.name-input:focus { border-color: var(--accent); }
	.save-actions { display: flex; gap: var(--space-2); justify-content: flex-end; }
	.btn-cancel, .btn-save { padding: 6px 16px; border-radius: var(--radius-sm); border: none; font-size: 12px; font-family: inherit; cursor: pointer; transition: all 0.12s; }
	.btn-cancel { background: var(--bg-surface); color: var(--fg-secondary); }
	.btn-cancel:hover { background: var(--bg-active); }
	.btn-save { background: var(--accent); color: white; }
	.btn-save:hover { filter: brightness(1.1); }
	.btn-save:disabled { opacity: 0.4; cursor: default; }
	.error-msg { font-size: 11px; color: rgba(255, 80, 80, 0.7); }

	.saved-list { display: flex; flex-direction: column; gap: 2px; }
	.saved-item { display: flex; align-items: center; gap: var(--space-2); border-radius: var(--radius-sm); transition: background 0.1s; }
	.saved-item:hover { background: var(--bg-hover); }
	.si-play { flex: 1; display: flex; align-items: center; gap: var(--space-2); padding: var(--space-2) var(--space-3); border: none; background: transparent; color: var(--fg-secondary); cursor: pointer; text-align: left; font-family: inherit; }
	.si-name { font-size: 13px; color: var(--fg-primary); }
	.si-delete { width: 24px; height: 24px; border: none; background: transparent; color: var(--fg-quaternary); cursor: pointer; display: flex; align-items: center; justify-content: center; opacity: 0; transition: all 0.12s; border-radius: var(--radius-sm); }
	.saved-item:hover .si-delete { opacity: 1; }
	.si-delete:hover { color: rgba(255, 80, 80, 0.6); }

	.empty { font-size: 12px; color: var(--fg-quaternary); padding: var(--space-2) 0; }
</style>
