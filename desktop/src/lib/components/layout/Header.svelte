<script lang="ts">
	import { motion } from '@humanspeak/svelte-motion';
	import { getUiState } from '$lib/stores/ui.svelte';
	import { getLibraryState } from '$lib/stores/library.svelte';
	import { getPlaybackState } from '$lib/stores/playback.svelte';
	import { getSettingsState } from '$lib/stores/settings.svelte';
	import { formatTime } from '$lib/utils/time';
	import { browser } from '$app/environment';
	import type { Track } from '$lib/audio/types';
	import { Search, Folder, X } from 'lucide-svelte';
	import { t } from '$lib/i18n/i18n.svelte';

	const ui = getUiState();
	const library = getLibraryState();
	const playback = getPlaybackState();
	const settings = getSettingsState();

	interface Props { title?: string; }
	let { title }: Props = $props();

	let searchInput: HTMLInputElement | undefined = $state();
	let searchResults = $state<Track[]>([]);
	let searchTimer: ReturnType<typeof setTimeout> | undefined;

	const viewTitles: Record<string, string> = {
		library: t('header.view_library'),
		effects: t('header.view_effects'),
		settings: t('header.view_settings'),
		room: t('header.view_room'),
		subsonic: t('header.view_subsonic'),
		webdav: t('header.view_webdav'),
	};

	function openSearch() {
		ui.showSearch = true;
		library.searchQuery = '';
		searchResults = [];
		requestAnimationFrame(() => searchInput?.focus());
	}

	function closeSearch() {
		ui.showSearch = false;
		if (!library.searchQuery) library.loadTracks();
	}

	async function onSearchInput(e: Event) {
		const val = (e.currentTarget as HTMLInputElement).value;
		library.searchQuery = val;
		clearTimeout(searchTimer);
		if (!val.trim()) { searchResults = []; return; }
		searchTimer = setTimeout(async () => {
			searchResults = await library.search(val);
		}, 300);
	}

	function onSearchKeydown(e: KeyboardEvent) {
		if (e.key === 'Escape') closeSearch();
	}

	async function handleScan() {
		if (!browser) return;
		try {
			await library.scanDirectory();
		} catch { console.error('Scan cancelled'); }
	}

	// Cmd+K / Ctrl+K 打开搜索
	function onKeydown(e: KeyboardEvent) {
		if ((e.metaKey || e.ctrlKey) && e.key === 'k') {
			e.preventDefault();
			if (ui.showSearch) closeSearch();
			else openSearch();
		}
		if (e.key === 'Escape' && ui.showSearch) closeSearch();
	}
</script>

<svelte:window onkeydown={onKeydown} />

<header class="header">
	<div class="header-left">
		<h1 class="page-title">{title || viewTitles[ui.view] || t('header.default_title')}</h1>
	</div>
	<div class="header-right">
		<button class="icon-btn" title={t('header.search')} onclick={openSearch}>
			<Search size={16} />
		</button>
		<button class="icon-btn" title={t('header.scan')} onclick={handleScan}>
			<Folder size={16} />
		</button>
		<div class="avatar" style="background: linear-gradient(135deg, {settings.accentColor}, color-mix(in srgb, {settings.accentColor} 70%, #fff));">W</div>
	</div>
</header>

<!-- Search sheet -->
{#if ui.showSearch}
	<div class="backdrop" onclick={closeSearch} onkeydown={(e) => e.key === 'Escape' && closeSearch()} role="button" tabindex="0"></div>
	<div class="search-sheet">
		<motion.div
			initial={{ opacity: 0, scale: 0.95 }}
			animate={{ opacity: 1, scale: 1 }}
			transition={{ type: 'spring', stiffness: 400, damping: 28 }}
		>
		<div class="search-bar">
			<Search size={16} style="color: var(--fg-tertiary); flex-shrink: 0;" />
			<input bind:this={searchInput} type="text" class="search-input" placeholder={t('header.search_placeholder')} value={library.searchQuery} oninput={onSearchInput} onkeydown={onSearchKeydown} />
			<button class="search-close" onclick={closeSearch} aria-label={t('header.close')}>
				<X size={14} />
			</button>
		</div>

		{#if library.searchQuery && searchResults.length > 0}
			<div class="search-results">
				{#each searchResults as track, i (track.id)}
					<button class="search-row" style="animation-delay: {i * 25}ms" onclick={() => { playback.playTrack(track); closeSearch(); }}>
						<div class="sr-body">
							<span class="sr-title">{track.title || track.path.split(/[/\\]/).pop()}</span>
							<span class="sr-meta">{track.artist}{track.album ? ' · ' + track.album : ''}</span>
						</div>
					</button>
				{/each}
			</div>
		{:else if library.searchQuery}
			<div class="search-empty">
				<span>{t('header.search_empty')}</span>
			</div>
		{/if}
	</motion.div>
	</div>
{/if}

<style>
	.header { display: flex; align-items: center; justify-content: space-between; padding: var(--space-4) var(--space-6) var(--space-3); flex-shrink: 0; }
	.header-left { display: flex; align-items: center; gap: var(--space-3); }
	.page-title { font-size: 20px; font-weight: 600; color: var(--fg-primary); letter-spacing: -0.3px; }
	.header-right { display: flex; align-items: center; gap: var(--space-2); }

	.avatar {
		width: 28px; height: 28px; border-radius: 50%;
		color: white; display: flex; align-items: center; justify-content: center;
		font-size: 12px; font-weight: 600; cursor: default;
	}

	/* ── Search sheet ── */
	.search-sheet {
		position: fixed; top: 50%; left: 50%; z-index: 51;
		width: min(440px, 90vw);
		transform: translate(-50%, -50%);
		transform-origin: center;
		background: rgba(18, 18, 18, 0.96);
		backdrop-filter: blur(20px);
		border: 1px solid rgba(255,255,255,0.06);
		border-radius: var(--radius-xl);
		box-shadow: var(--shadow-lg), 0 0 0 1px rgba(255,255,255,0.03);
		overflow: hidden;
	}

	.search-bar { display: flex; align-items: center; gap: var(--space-2); padding: var(--space-4) var(--space-4); border-bottom: 1px solid var(--separator); }
	.search-input { flex: 1; border: none; background: transparent; color: var(--fg-primary); font-size: 15px; font-family: inherit; outline: none; }
	.search-input::placeholder { color: var(--fg-tertiary); }

	.search-close {
		width: 26px; height: 26px; border-radius: var(--radius-sm); border: none;
		background: var(--bg-hover); color: var(--fg-tertiary);
		cursor: pointer; display: flex; align-items: center; justify-content: center;
		transition: all 0.12s;
	}
	.search-close:hover { background: var(--bg-active); color: var(--fg-secondary); }

	.search-results { max-height: 320px; overflow-y: auto; padding: var(--space-1); }
	.search-row {
		display: flex; align-items: center; width: 100%; padding: var(--space-2) var(--space-3);
		border: none; border-radius: var(--radius-sm); background: transparent; color: var(--fg-secondary);
		cursor: pointer; transition: all 0.1s; text-align: left; font-family: inherit;
		animation: rowFade 0.25s ease both;
	}
	@keyframes rowFade { from { opacity: 0; transform: translateY(4px); } to { opacity: 1; transform: translateY(0); } }
	.search-row:hover { background: var(--bg-hover); color: var(--fg-primary); }

	.sr-body { flex: 1; min-width: 0; display: flex; flex-direction: column; gap: 1px; }
	.sr-title { font-size: 13px; font-weight: 500; color: var(--fg-primary); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
	.sr-meta { font-size: 11px; color: var(--fg-tertiary); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }

	.search-empty { padding: var(--space-8); text-align: center; color: var(--fg-tertiary); font-size: 13px; }
</style>
