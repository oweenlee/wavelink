<script lang="ts">
	import { browser } from '$app/environment';
	import { fly } from 'svelte/transition';
	import { cubicOut } from 'svelte/easing';
	import type { Track } from '$lib/audio/types';
	import { X } from 'lucide-svelte';
	import { t } from '$lib/i18n/i18n.svelte';

	let { track, onclose }: { track: Track; onclose: () => void } = $props();

	let title = $state(track.title || '');
	let artist = $state(track.artist || '');
	let album = $state(track.album || '');
	let genre = $state(track.genre || '');
	let trackNumber = $state(track.track_number?.toString() || '');
	let year = $state(track.year?.toString() || '');
	let saving = $state(false);
	let error = $state('');
	let success = $state(false);

	async function save() {
		if (!browser) return;
		saving = true;
		error = '';
		success = false;

		const update: Record<string, any> = {};
		if (title !== (track.title || '')) update.title = title || null;
		if (artist !== (track.artist || '')) update.artist = artist || null;
		if (album !== (track.album || '')) update.album = album || null;
		if (genre !== (track.genre || '')) update.genre = genre || null;
		const tn = trackNumber ? parseInt(trackNumber) : null;
		if (tn !== track.track_number && (tn !== null || track.track_number !== null)) update.track_number = tn;
		const yr = year ? parseInt(year) : null;
		if (yr !== track.year && (yr !== null || track.year !== null)) update.year = yr;

		if (Object.keys(update).length === 0) { saving = false; success = true; return; }

		try {
			const { invoke } = await import('@tauri-apps/api/core');
			await invoke('edit_tags', { path: track.path, update });
			success = true;
			setTimeout(onclose, 800);
		} catch (e: any) {
			error = typeof e === 'string' ? e : t('tag_editor.save_failed');
		} finally {
			saving = false;
		}
	}

	function onBackdropClick() {
		if (!saving) onclose();
	}
</script>

<div class="backdrop" onclick={onBackdropClick} onkeydown={(e) => e.key === 'Escape' && !saving && onclose()} role="button" tabindex="0"></div>

<div class="editor" transition:fly={{ y: 40, duration: 250, easing: cubicOut, opacity: 0 }}>
	<div class="editor-header">
		<h3 class="editor-title">{t('tag_editor.title')}</h3>
		<button class="editor-close" onclick={onclose} disabled={saving} aria-label={t('tag_editor.close')}>
			<X size={16} />
		</button>
	</div>

	<div class="editor-body">
		<label class="field">
			<span class="field-label">{t('tag_editor.title_field')}</span>
			<input type="text" class="field-input" bind:value={title} placeholder={t('tag_editor.title_placeholder')} />
		</label>
		<label class="field">
			<span class="field-label">{t('tag_editor.artist')}</span>
			<input type="text" class="field-input" bind:value={artist} placeholder={t('tag_editor.artist_placeholder')} />
		</label>
		<label class="field">
			<span class="field-label">{t('tag_editor.album')}</span>
			<input type="text" class="field-input" bind:value={album} placeholder={t('tag_editor.album_placeholder')} />
		</label>
		<div class="field-row">
			<label class="field half">
				<span class="field-label">{t('tag_editor.track_number')}</span>
				<input type="number" class="field-input" bind:value={trackNumber} placeholder={t('tag_editor.num_placeholder')} min="1" max="99" />
			</label>
			<label class="field half">
				<span class="field-label">{t('tag_editor.year')}</span>
				<input type="number" class="field-input" bind:value={year} placeholder={t('tag_editor.num_placeholder')} min="1900" max="2100" />
			</label>
		</div>
		<label class="field">
			<span class="field-label">{t('tag_editor.genre')}</span>
			<input type="text" class="field-input" bind:value={genre} placeholder={t('tag_editor.genre_placeholder')} />
		</label>

		{#if error}<div class="msg error">{error}</div>{/if}
		{#if success}<div class="msg success">{t('tag_editor.saved')}</div>{/if}
	</div>

	<div class="editor-footer">
		<div></div>
		<div class="footer-right">
			<button class="btn btn-cancel" onclick={onclose} disabled={saving}>{t('tag_editor.cancel')}</button>
			<button class="btn btn-save" onclick={save} disabled={saving}>{saving ? t('tag_editor.saving') : t('tag_editor.save')}</button>
		</div>
	</div>
</div>

<style>
	.backdrop { position: fixed; inset: 0; z-index: 200; background: rgba(0,0,0,0.35); animation: fade 0.2s; }
	@keyframes fade { from { opacity: 0; } to { opacity: 1; } }

	.editor {
		position: fixed; top: 50%; left: 50%; z-index: 201;
		transform: translate(-50%, -50%);
		width: min(380px, 90vw);
		background: rgba(22,22,35,0.94); backdrop-filter: blur(48px);
		border: 1px solid var(--separator);
		border-radius: var(--radius-xl); box-shadow: 0 24px 80px rgba(0,0,0,0.5);
		overflow: hidden;
	}

	.editor-header { display: flex; align-items: center; justify-content: space-between; padding: 18px 20px 12px; }
	.editor-title { font-size: 16px; font-weight: 600; color: var(--fg-primary); margin: 0; }
	.editor-close { width: 28px; height: 28px; border-radius: var(--radius-sm); border: none; background: var(--bg-surface); color: var(--fg-tertiary); cursor: pointer; display: flex; align-items: center; justify-content: center; }
	.editor-close:hover { background: var(--bg-hover); color: var(--fg-secondary); }

	.editor-body { padding: 4px 20px 16px; display: flex; flex-direction: column; gap: 12px; }

	.field { display: flex; flex-direction: column; gap: 4px; }
	.field-label { font-size: 11px; font-weight: 600; color: var(--fg-tertiary); text-transform: uppercase; letter-spacing: 1px; }
	.field-input { padding: 9px 12px; border-radius: var(--radius-md); border: 1px solid var(--separator); background: var(--bg-surface); color: var(--fg-primary); font-size: 14px; font-family: inherit; outline: none; transition: border-color 0.15s; }
	.field-input:focus { border-color: var(--accent); }
	.field-input::placeholder { color: var(--fg-quaternary); }

	.field-row { display: flex; gap: 12px; }
	.field.half { flex: 1; }

	.msg { padding: 8px 12px; border-radius: var(--radius-sm); font-size: 13px; }
	.msg.error { background: rgba(255,80,80,0.1); color: rgba(255,80,80,0.7); }
	.msg.success { background: rgba(68,204,136,0.1); color: rgba(68,204,136,0.7); text-align: center; }

	.editor-footer { display: flex; align-items: center; justify-content: space-between; padding: 12px 20px 18px; }
	.footer-right { display: flex; gap: 8px; }

	.btn { padding: 8px 20px; border-radius: var(--radius-md); border: none; font-size: 13px; font-weight: 500; font-family: inherit; cursor: pointer; transition: all 0.12s; }
	.btn:disabled { opacity: 0.3; cursor: default; }
	.btn-cancel { background: var(--bg-hover); color: var(--fg-secondary); }
	.btn-cancel:hover:not(:disabled) { background: var(--bg-active); }
	.btn-save { background: var(--accent); color: white; }
	.btn-save:hover:not(:disabled) { filter: brightness(1.1); }
</style>
