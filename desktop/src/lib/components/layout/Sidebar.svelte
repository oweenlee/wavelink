<script lang="ts">
	import { getUiState, type ViewName } from '$lib/stores/ui.svelte';
	import { Music, AudioLines, Settings, HardDrive, Waves, Radio, Globe, ListMusic, type Icon as LucideIcon } from 'lucide-svelte';
	import { t, type I18nKey } from '$lib/i18n/i18n.svelte';

	const ui = getUiState();

	type NavItem = { view: ViewName; label: I18nKey; icon: typeof Music };
	type NavGroup = { label: I18nKey; items: NavItem[] };

	const groups = [
		{
			label: 'sidebar.group.sources',
			items: [
				{ view: 'library', label: 'sidebar.library', icon: Music },
				{ view: 'nas', label: 'sidebar.nas', icon: HardDrive },
				{ view: 'subsonic', label: 'sidebar.subsonic', icon: Radio },
				{ view: 'webdav', label: 'sidebar.webdav', icon: Globe },
				{ view: 'cue', label: 'sidebar.cue', icon: ListMusic },
			],
		},
		{
			label: 'sidebar.group.audio',
			items: [
				{ view: 'effects', label: 'sidebar.effects', icon: AudioLines },
				{ view: 'room', label: 'sidebar.room', icon: Waves },
			],
		},
		{
			label: 'sidebar.group.system',
			items: [{ view: 'settings', label: 'sidebar.settings', icon: Settings }],
		},
	] satisfies NavGroup[];
</script>

<aside class="sidebar">
	<div class="logo">
		<img class="logo-img" src="/wavelink-logo.png" alt="WaveLink" width="22" height="22" />
		<span class="logo-text">WaveLink</span>
	</div>

	<nav class="nav">
		{#each groups as group (group.label)}
			<div class="group">
				<p class="nav-label">{t(group.label)}</p>
				{#each group.items as item (item.view)}
					<button
						class="nav-item"
						class:active={ui.view === item.view}
						onclick={() => ui.navigateTo(item.view)}
					>
						<span class="icon-wrap"><item.icon size={15} stroke-width={1.75} /></span>
						<span class="nav-text">{t(item.label)}</span>
					</button>
				{/each}
			</div>
		{/each}
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
		margin-bottom: var(--space-6);
	}

	.logo-img { flex-shrink: 0; }
	.logo-text { font-family: var(--font-display); font-size: 16px; font-weight: 600; color: var(--fg-primary); letter-spacing: 0.5px; }

	.nav { display: flex; flex-direction: column; gap: var(--space-4); overflow-y: auto; }

	.group { display: flex; flex-direction: column; gap: 1px; }

	.nav-label {
		display: flex; align-items: center; gap: var(--space-2);
		font-size: 10px; font-weight: 600; color: var(--fg-tertiary);
		text-transform: uppercase; letter-spacing: 1.2px;
		margin: 0 var(--space-2) var(--space-1);
	}

	.nav-label::after {
		content: ''; flex: 1; height: 1px;
		background: linear-gradient(to right, rgba(255, 255, 255, 0.06), transparent);
	}

	.nav-item {
		display: flex; align-items: center; gap: var(--space-2);
		padding: 3px var(--space-2);
		border: none; border-radius: var(--radius-sm);
		background: transparent; color: var(--fg-secondary);
		font-size: 13px; font-family: inherit;
		cursor: pointer; transition: all 0.12s;
		text-align: left; width: 100%;
		position: relative;
	}

	.nav-item::before {
		content: ''; position: absolute; left: -12px; top: 8px; height: calc(100% - 16px); width: 2px;
		background: var(--accent); border-radius: 0 2px 2px 0;
		transform: scaleY(0); transition: transform 0.15s var(--ease-out);
		transform-origin: top;
	}
	.nav-item.active::before { transform: scaleY(1); }

	.icon-wrap {
		display: flex; align-items: center; justify-content: center;
		width: 28px; height: 28px; border-radius: var(--radius-sm);
		flex-shrink: 0; transition: all 0.12s;
	}

	.nav-item :global(svg) { flex-shrink: 0; opacity: 0.65; transition: all 0.12s; }

	.nav-item:hover { color: var(--fg-primary); }
	.nav-item:hover .icon-wrap { background: var(--bg-hover); }
	.nav-item:hover :global(svg) { opacity: 1; }

	.nav-item:active { transform: scale(0.97); }

	.nav-item.active {
		background: linear-gradient(90deg, color-mix(in srgb, var(--accent) 14%, transparent), transparent 85%);
		color: var(--fg-primary); font-weight: 500;
	}
	.nav-item.active .icon-wrap { background: color-mix(in srgb, var(--accent) 18%, transparent); }
	.nav-item.active :global(svg) { opacity: 1; color: var(--accent); }
</style>