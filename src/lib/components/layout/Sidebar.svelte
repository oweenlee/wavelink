<script lang="ts">
	import { getUiState } from '$lib/stores/ui.svelte';
	import { getPlaylistState } from '$lib/stores/playlist.svelte';
	import { browser } from '$app/environment';

	const ui = getUiState();
	const playlist = getPlaylistState();

	// Load saved playlists on mount
	$effect(() => {
		if (browser) playlist.loadPlaylistNames();
	});

	let showPlaylists = $state(true);

	async function togglePlaylists() {
		showPlaylists = !showPlaylists;
		if (showPlaylists && playlist.savedPlaylists.length === 0) {
			await playlist.loadPlaylistNames();
		}
	}
</script>

<aside class="sidebar">
	<div class="logo">
		<span class="logo-mark">◈</span>
		<span class="logo-text">WaveLink</span>
	</div>

	<nav class="nav">
		<p class="nav-label">浏览</p>
		<button class="nav-item" class:active={ui.view === 'library'} onclick={() => ui.navigateTo('library')}>
			<svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round"><path d="M9 18V5l12-2v13"/><circle cx="6" cy="18" r="3"/><circle cx="18" cy="16" r="3"/></svg>
			<span>本地音乐</span>
		</button>
		<button class="nav-item" class:active={ui.view === 'effects'} onclick={() => ui.navigateTo('effects')}>
			<svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round"><path d="M12 20V10"/><path d="M18 20V4"/><path d="M6 20v-6"/></svg>
			<span>音效设置</span>
		</button>
		<button class="nav-item" class:active={ui.view === 'settings'} onclick={() => ui.navigateTo('settings')}>
			<svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round"><circle cx="12" cy="12" r="3"/><path d="M19.4 15a1.65 1.65 0 0 0 .33 1.82l.06.06a2 2 0 0 1 0 2.83 2 2 0 0 1-2.83 0l-.06-.06a1.65 1.65 0 0 0-1.82-.33 1.65 1.65 0 0 0-1 1.51V21a2 2 0 0 1-2 2 2 2 0 0 1-2-2v-.09A1.65 1.65 0 0 0 9 19.4a1.65 1.65 0 0 0-1.82.33l-.06.06a2 2 0 0 1-2.83 0 2 2 0 0 1 0-2.83l.06-.06a1.65 1.65 0 0 0 .33-1.82 1.65 1.65 0 0 0-1.51-1H3a2 2 0 0 1-2-2 2 2 0 0 1 2-2h.09A1.65 1.65 0 0 0 4.6 9a1.65 1.65 0 0 0-.33-1.82l-.06-.06a2 2 0 0 1 0-2.83 2 2 0 0 1 2.83 0l.06.06a1.65 1.65 0 0 0 1.82.33H9a1.65 1.65 0 0 0 1-1.51V3a2 2 0 0 1 2-2 2 2 0 0 1 2 2v.09a1.65 1.65 0 0 0 1 1.51 1.65 1.65 0 0 0 1.82-.33l.06-.06a2 2 0 0 1 2.83 0 2 2 0 0 1 0 2.83l-.06.06a1.65 1.65 0 0 0-.33 1.82V9a1.65 1.65 0 0 0 1.51 1H21a2 2 0 0 1 2 2 2 2 0 0 1-2 2h-.09a1.65 1.65 0 0 0-1.51 1z"/></svg>
			<span>设置</span>
		</button>
	</nav>

	<nav class="nav secondary">
		<div class="nav-section-header">
			<p class="nav-label">播放列表</p>
			<button class="nav-toggle" onclick={togglePlaylists} aria-label="展开播放列表">
				<svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" style="transform: rotate({showPlaylists ? 90 : 0}deg); transition: transform 0.2s;"><polyline points="9,18 15,12 9,6"/></svg>
			</button>
		</div>
		{#if showPlaylists}
			{#if playlist.savedPlaylists.length > 0}
				{#each playlist.savedPlaylists as name}
					<button class="nav-item playlist-item" onclick={() => { playlist.loadPlaylist(name); ui.navigateTo('library'); }}>
						<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round"><path d="M21 15V6M18.5 18a2.5 2.5 0 1 0 0-5 2.5 2.5 0 0 0 0 5zM12 12H3M16 6H3M12 18H3"/></svg>
						<span class="playlist-name">{name}</span>
					</button>
				{/each}
			{:else}
				<p class="nav-empty">暂无播放列表</p>
			{/if}
			<button class="nav-item new-playlist" onclick={() => ui.showPlaylistPanel = true}>
				<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><line x1="12" y1="5" x2="12" y2="19"/><line x1="5" y1="12" x2="19" y2="12"/></svg>
				<span>新建播放列表</span>
			</button>
		{/if}
	</nav>
</aside>

<style>
	.sidebar {
		width: 220px; min-width: 220px; height: 100%;
		display: flex; flex-direction: column;
		padding: var(--space-6) var(--space-3);
		background: var(--glass-bg);
		backdrop-filter: var(--glass-blur);
		-webkit-backdrop-filter: var(--glass-blur);
	}

	.logo {
		display: flex; align-items: center; gap: var(--space-2);
		padding: 0 var(--space-2);
		margin-bottom: var(--space-8);
	}

	.logo-mark { font-size: 22px; color: var(--accent); }
	.logo-text { font-size: 16px; font-weight: 600; color: var(--fg-primary); letter-spacing: 0.5px; }

	.nav { display: flex; flex-direction: column; gap: 1px; margin-bottom: var(--space-6); }
	.nav.secondary { margin-top: auto; }

	.nav-section-header { display: flex; align-items: center; justify-content: space-between; padding: 0 var(--space-2); margin-bottom: var(--space-2); }
	.nav-label {
		font-size: 10px; font-weight: 600; color: var(--fg-tertiary);
		text-transform: uppercase; letter-spacing: 1.2px;
	}

	.nav-toggle {
		width: 20px; height: 20px; border: none; border-radius: var(--radius-sm);
		background: transparent; color: var(--fg-tertiary); cursor: pointer;
		display: flex; align-items: center; justify-content: center;
		transition: all 0.12s;
	}
	.nav-toggle:hover { background: var(--bg-hover); color: var(--fg-secondary); }

	.nav-item {
		display: flex; align-items: center; gap: var(--space-2);
		padding: var(--space-2) var(--space-2);
		border: none; border-radius: var(--radius-sm);
		background: transparent; color: var(--fg-secondary);
		font-size: 13px; font-family: inherit;
		cursor: pointer; transition: all 0.12s;
		text-align: left; width: 100%;
	}

	.nav-item:hover { background: var(--bg-hover); color: var(--fg-primary); }
	.nav-item.active { background: var(--bg-active); color: var(--fg-primary); font-weight: 500; }

	.nav-item svg { flex-shrink: 0; opacity: 0.6; }
	.nav-item.active svg { opacity: 1; color: var(--accent); }

	.playlist-item { padding-left: var(--space-4); }
	.playlist-name { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
	.new-playlist { color: var(--fg-tertiary); margin-top: var(--space-1); }
	.new-playlist:hover { color: var(--accent) !important; }

	.nav-empty { font-size: 11px; color: var(--fg-quaternary); padding: var(--space-1) var(--space-4); }
</style>
