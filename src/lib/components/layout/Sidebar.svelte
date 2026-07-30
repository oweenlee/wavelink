<script lang="ts">
	import { getUiState } from '$lib/stores/ui.svelte';
	import { Music, AudioLines, Settings, HardDrive } from 'lucide-svelte';
	import { t } from '$lib/i18n/i18n.svelte';

	const ui = getUiState();
</script>

<aside class="sidebar">
	<div class="logo">
		<svg class="logo-svg" viewBox="0 0 24 24" width="22" height="22" aria-hidden="true">
			<defs>
				<linearGradient id="sw1" x1="0" y1="0" x2="24" y2="0">
					<stop offset="0" stop-color="#e2a63d"/>
					<stop offset="100" stop-color="#f0c860"/>
				</linearGradient>
				<linearGradient id="sw2" x1="0" y1="0" x2="24" y2="0">
					<stop offset="0" stop-color="#c8956c"/>
					<stop offset="100" stop-color="#e2a63d"/>
				</linearGradient>
			</defs>
			<path d="M2 8C7 7 7 17 12 17C17 17 17 7 22 8" fill="none" stroke="url(#sw1)" stroke-width="2.5" stroke-linecap="round"/>
			<path d="M2 16C7 17 7 7 12 7C17 7 17 17 22 16" fill="none" stroke="url(#sw2)" stroke-width="2" stroke-linecap="round"/>
			<circle cx="7" cy="12" r="1.3" fill="#f0c860"/>
			<circle cx="17" cy="12" r="1.3" fill="#c8956c"/>
		</svg>
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
	</nav>
</aside>

<style>
	.sidebar {
		width: 200px; min-width: 200px; height: 100%;
		display: flex; flex-direction: column;
		padding: var(--space-6) var(--space-3);
		background: #0a0a0c;
		border-right: 0.5px solid rgba(255, 255, 255, 0.04);
	}

	.logo {
		display: flex; align-items: center; gap: var(--space-2);
		padding: 0 var(--space-2);
		margin-bottom: var(--space-8);
	}

	.logo-svg { flex-shrink: 0; }
	.logo-text { font-size: 16px; font-weight: 600; color: var(--fg-primary); letter-spacing: 0.5px; }

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
