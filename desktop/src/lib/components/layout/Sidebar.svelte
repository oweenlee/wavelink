<script lang="ts">
	import { getUiState } from '$lib/stores/ui.svelte';
	import { Music, AudioLines, Settings, HardDrive, Waves, Radio, Globe, ListMusic } from 'lucide-svelte';
	import { t } from '$lib/i18n/i18n.svelte';

	const ui = getUiState();
</script>

<aside class="sidebar">
	<div class="logo">
		<img class="logo-img" src="/wavelink-logo.png" alt="WaveLink" width="22" height="22" />
		<span class="logo-text">WaveLink</span>
	</div>

	<nav class="nav">
		<p class="nav-label">{t('sidebar.browse')}</p>
		<button class="nav-item" class:active={ui.view === 'library'} onclick={() => ui.navigateTo('library')}>
			<Music size={16} stroke-width={1.5} />
			<span>{t('sidebar.library')}</span>
		</button>
		<button class="nav-item" class:active={ui.view === 'effects'} onclick={() => ui.navigateTo('effects')}>
			<AudioLines size={16} stroke-width={1.5} />
			<span>{t('sidebar.effects')}</span>
		</button>
		<button class="nav-item" class:active={ui.view === 'settings'} onclick={() => ui.navigateTo('settings')}>
			<Settings size={16} stroke-width={1.5} />
			<span>{t('sidebar.settings')}</span>
		</button>
		<button class="nav-item" class:active={ui.view === 'nas'} onclick={() => ui.navigateTo('nas')}>
			<HardDrive size={16} stroke-width={1.5} />
			<span>{t('sidebar.nas')}</span>
		</button>
		<button class="nav-item" class:active={ui.view === 'room'} onclick={() => ui.navigateTo('room')}>
			<Waves size={16} stroke-width={1.5} />
			<span>{t('sidebar.room')}</span>
		</button>
		<button class="nav-item" class:active={ui.view === 'subsonic'} onclick={() => ui.navigateTo('subsonic')}>
			<Radio size={16} stroke-width={1.5} />
			<span>{t('sidebar.subsonic')}</span>
		</button>
		<button class="nav-item" class:active={ui.view === 'webdav'} onclick={() => ui.navigateTo('webdav')}>
			<Globe size={16} stroke-width={1.5} />
			<span>{t('sidebar.webdav')}</span>
		</button>
		<button class="nav-item" class:active={ui.view === 'cue'} onclick={() => ui.navigateTo('cue')}>
			<ListMusic size={16} stroke-width={1.5} />
			<span>{t('sidebar.cue')}</span>
		</button>
	</nav>
</aside>

<style>
	.sidebar {
		width: 200px; min-width: 200px; height: 100%;
		display: flex; flex-direction: column;
		padding: var(--space-6) var(--space-3);
		background: #08090a;
		border-right: 0.5px solid rgba(255, 255, 255, 0.04);
	}

	.logo {
		display: flex; align-items: center; gap: var(--space-2);
		padding: 0 var(--space-2);
		margin-bottom: var(--space-8);
	}

	.logo-svg, .logo-img { flex-shrink: 0; }
	.logo-text { font-family: var(--font-display); font-size: 16px; font-weight: 600; color: var(--fg-primary); letter-spacing: 0.5px; }

	.nav { display: flex; flex-direction: column; gap: 1px; }

	.nav-label {
		font-size: 10px; font-weight: 600; color: var(--fg-tertiary);
		text-transform: uppercase; letter-spacing: 1.2px;
		margin-bottom: var(--space-2);
	}

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
	.nav-item:active { transform: scale(0.97); }
	.nav-item.active { background: var(--bg-active); color: var(--fg-primary); font-weight: 500; }

	.nav-item :global(svg) { flex-shrink: 0; opacity: 0.6; }
	.nav-item.active :global(svg) { opacity: 1; color: var(--accent); }
</style>
