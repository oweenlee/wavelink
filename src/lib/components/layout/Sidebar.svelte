<script lang="ts">
	import { getUiState } from '$lib/stores/ui.svelte';
	import { getPlaylistState } from '$lib/stores/playlist.svelte';
	import { browser } from '$app/environment';
	import { Music, AudioLines, Settings, ChevronRight, ListMusic, Plus, HardDrive } from 'lucide-svelte';

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
			<Music size={16} stroke-width={1.5} />
			<span>本地音乐</span>
		</button>
		<button class="nav-item" class:active={ui.view === 'effects'} onclick={() => ui.navigateTo('effects')}>
			<AudioLines size={16} stroke-width={1.5} />
			<span>音效设置</span>
		</button>
		<button class="nav-item" class:active={ui.view === 'settings'} onclick={() => ui.navigateTo('settings')}>
			<Settings size={16} stroke-width={1.5} />
			<span>设置</span>
		</button>
		<button class="nav-item" class:active={ui.view === 'nas'} onclick={() => ui.navigateTo('nas')}>
			<HardDrive size={16} stroke-width={1.5} />
			<span>NAS</span>
		</button>
	</nav>

	<nav class="nav secondary">
		<div class="nav-section-header">
			<p class="nav-label">播放列表</p>
			<button class="nav-toggle" onclick={togglePlaylists} aria-label="展开播放列表">
				<ChevronRight size={12} style="transform: rotate({showPlaylists ? 90 : 0}deg); transition: transform 0.2s;" />
			</button>
		</div>
		{#if showPlaylists}
			{#if playlist.savedPlaylists.length > 0}
				{#each playlist.savedPlaylists as name}
					<button class="nav-item playlist-item" onclick={() => { playlist.loadPlaylist(name); ui.navigateTo('library'); }}>
						<ListMusic size={14} stroke-width={1.5} />
						<span class="playlist-name">{name}</span>
					</button>
				{/each}
			{:else}
				<p class="nav-empty">暂无播放列表</p>
			{/if}
			<button class="nav-item new-playlist" onclick={() => ui.showPlaylistPanel = true}>
				<Plus size={14} />
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
		position: relative;
	}

	.nav-item::before {
		content: ''; position: absolute; left: -12px; top: 0; height: 100%; width: 2px;
		background: var(--accent); border-radius: 0 2px 2px 0;
		transform: scaleY(0); transition: transform 0.15s var(--ease-out);
		transform-origin: top;
	}
	.nav-item.active::before { transform: scaleY(1); }

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
