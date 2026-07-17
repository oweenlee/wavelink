<script lang="ts">
	import { nasStore, type NasConnection } from '$lib/stores/nas.svelte';
	import { invoke } from '@tauri-apps/api/core';
	import { browser } from '$app/environment';
	import { HardDrive, Plus, Trash2, Play, Square, Server, X, Loader, Upload } from 'lucide-svelte';
	import { t } from '$lib/i18n/i18n.svelte';

	const nas = nasStore;

	let showAddDialog = $state(false);
	let mounting = $state<Set<string>>(new Set());
	let scanning = $state(false);

	let form = $state({
		name: '',
		server: '',
		share: '',
		username: '',
		password: '',
		autoMount: false,
	});

	$effect(() => {
		if (browser) nas.loadConnections();
	});

	async function handleMount(id: string, conn: NasConnection) {
		if (conn.mounted) {
			await nas.unmountConnection(id);
		} else {
			mounting = new Set([...mounting, id]);
			try {
				const path = await nas.mountConnection(id);
				// 挂载后自动扫描
				scanning = true;
				await invoke('scan_dir', { path });
			} catch (e) {
				console.error('挂载失败:', e);
			} finally {
				mounting = new Set([...mounting].filter(x => x !== id));
				scanning = false;
			}
		}
	}

	async function handleAdd() {
		if (!form.name || !form.server || !form.share) return;
		await nas.addConnection(
			form.name,
			form.server,
			form.share,
			form.username,
			form.password,
			form.autoMount
		);
		form = { name: '', server: '', share: '', username: '', password: '', autoMount: false };
		showAddDialog = false;
	}

	async function handleRemove(id: string) {
		await nas.removeConnection(id);
	}
</script>

<div class="nas-view">
	<div class="header">
		<h1>{t('nas.title')}</h1>
		<button class="btn-primary" onclick={() => (showAddDialog = true)}>
			<Plus size={16} />
			<span>{t('nas.add')}</span>
		</button>
	</div>

	{#if nas.loading}
		<div class="loading"><Loader size={20} class="spin" /> {t('nas.loading')}</div>
	{/if}

	{#if nas.error}
		<div class="error">{nas.error}</div>
	{/if}

	{#if nas.connections.length === 0 && !nas.loading}
		<div class="empty">
			<Server size={48} stroke-width={1} />
			<p>{t('nas.empty')}</p>
			<p class="hint">{t('nas.empty_hint')}</p>
		</div>
	{/if}

	<div class="nas-list">
		{#each nas.connections as conn (conn.id)}
			<div class="nas-card">
				<div class="card-icon" class:mounted={conn.mounted}>
					<HardDrive size={24} stroke-width={1.5} />
				</div>
				<div class="card-info">
					<div class="card-name">{conn.name}</div>
					<div class="card-detail">
						smb://{conn.server}/{conn.share}
					</div>
					<div class="card-status" class:connected={conn.mounted}>
						{conn.mounted ? t('nas.mounted') : t('nas.unmounted')}
						{#if conn.mount_path} — {conn.mount_path}{/if}
					</div>
				</div>
				<div class="card-actions">
					<button
						class="btn-icon"
						class:btn-mount={!conn.mounted}
						class:btn-unmount={conn.mounted}
						disabled={mounting.has(conn.id)}
						title={conn.mounted ? t('nas.unmount') : t('nas.mount')}
						onclick={() => handleMount(conn.id, conn)}
					>
						{#if mounting.has(conn.id)}
							<Loader size={16} class="spin" />
						{:else if conn.mounted}
							<Square size={14} />
						{:else}
							<Play size={14} />
						{/if}
					</button>
					<button class="btn-icon btn-danger" title={t('nas.delete')} onclick={() => handleRemove(conn.id)}>
						<Trash2 size={14} />
					</button>
				</div>
			</div>
		{/each}
	</div>

	{#if scanning}
		<div class="scan-bar"><Loader size={14} class="spin" /> {t('nas.scanning')}</div>
	{/if}
</div>

<!-- 添加弹窗 -->
{#if showAddDialog}
	<div class="overlay" onclick={() => (showAddDialog = false)}>
		<div class="dialog" onclick={(e) => e.stopPropagation()}>
			<div class="dialog-header">
				<h2>{t('nas.dialog_title')}</h2>
				<button class="btn-icon" onclick={() => (showAddDialog = false)}><X size={18} /></button>
			</div>
			<div class="dialog-body">
				<label class="field">
					<span>{t('nas.name')}</span>
					<input type="text" bind:value={form.name} placeholder={t('nas.name_placeholder')} />
				</label>
				<label class="field">
					<span>{t('nas.server')}</span>
					<input type="text" bind:value={form.server} placeholder={t('nas.server_placeholder')} />
				</label>
				<label class="field">
					<span>{t('nas.share')}</span>
					<input type="text" bind:value={form.share} placeholder={t('nas.share_placeholder')} />
				</label>
				<label class="field">
					<span>{t('nas.username')}</span>
					<input type="text" bind:value={form.username} placeholder={t('nas.username_placeholder')} />
				</label>
				<label class="field">
					<span>{t('nas.password')}</span>
					<input type="password" bind:value={form.password} placeholder={t('nas.password_placeholder')} />
				</label>
				<label class="checkbox">
					<input type="checkbox" bind:checked={form.autoMount} />
					<span>{t('nas.auto_mount')}</span>
				</label>
			</div>
			<div class="dialog-footer">
				<button class="btn-secondary" onclick={() => (showAddDialog = false)}>{t('nas.cancel')}</button>
				<button class="btn-primary" disabled={!form.name || !form.server || !form.share} onclick={handleAdd}>
					<Plus size={14} />
					<span>{t('nas.add_btn')}</span>
				</button>
			</div>
		</div>
	</div>
{/if}

<style>
	.nas-view { padding: var(--space-6); max-width: 720px; }

	.header { display: flex; align-items: center; justify-content: space-between; margin-bottom: var(--space-6); }
	.header h1 { font-size: 20px; font-weight: 600; color: var(--fg-primary); margin: 0; }

	.loading { display: flex; align-items: center; gap: var(--space-2); color: var(--fg-tertiary); font-size: 13px; padding: var(--space-8) 0; justify-content: center; }
	.error { color: #ef4444; font-size: 13px; padding: var(--space-3); background: rgba(239,68,68,0.1); border-radius: var(--radius-md); margin-bottom: var(--space-4); }

	.empty { display: flex; flex-direction: column; align-items: center; gap: var(--space-3); padding: var(--space-12) 0; color: var(--fg-tertiary); }
	.empty p { margin: 0; font-size: 14px; }
	.empty .hint { font-size: 12px; color: var(--fg-quaternary); }

	.nas-list { display: flex; flex-direction: column; gap: var(--space-2); }

	.nas-card {
		display: flex; align-items: center; gap: var(--space-3);
		padding: var(--space-3) var(--space-4);
		background: var(--glass-bg); border-radius: var(--radius-md);
		backdrop-filter: var(--glass-blur); -webkit-backdrop-filter: var(--glass-blur);
		transition: all 0.12s;
	}
	.nas-card:hover { background: var(--bg-hover); }

	.card-icon {
		width: 40px; height: 40px; border-radius: var(--radius-sm);
		display: flex; align-items: center; justify-content: center;
		background: var(--bg-active); color: var(--fg-tertiary); flex-shrink: 0;
	}
	.card-icon.mounted { color: var(--accent); background: color-mix(in srgb, var(--accent) 12%, transparent); }

	.card-info { flex: 1; min-width: 0; }
	.card-name { font-size: 14px; font-weight: 500; color: var(--fg-primary); }
	.card-detail { font-size: 12px; color: var(--fg-tertiary); font-family: var(--font-mono, monospace); }
	.card-status { font-size: 11px; color: var(--fg-quaternary); margin-top: 2px; }
	.card-status.connected { color: #22c55e; }

	.card-actions { display: flex; gap: var(--space-1); flex-shrink: 0; }

	.btn-icon {
		width: 32px; height: 32px; border: none; border-radius: var(--radius-sm);
		background: transparent; color: var(--fg-secondary); cursor: pointer;
		display: flex; align-items: center; justify-content: center;
		transition: all 0.12s;
	}
	.btn-icon:hover { background: var(--bg-hover); color: var(--fg-primary); }
	.btn-icon:disabled { opacity: 0.4; cursor: not-allowed; }
	.btn-mount:hover { color: #22c55e; }
	.btn-unmount:hover { color: #f59e0b; }
	.btn-danger:hover { color: #ef4444; background: rgba(239,68,68,0.1); }

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

	.scan-bar {
		display: flex; align-items: center; gap: var(--space-2);
		margin-top: var(--space-3); padding: var(--space-2) var(--space-3);
		background: var(--bg-active); border-radius: var(--radius-sm);
		font-size: 12px; color: var(--fg-tertiary);
	}

	/* Dialog */
	.overlay {
		position: fixed; inset: 0; z-index: 100;
		background: rgba(0,0,0,0.5);
		display: flex; align-items: center; justify-content: center;
		backdrop-filter: blur(4px);
	}
	.dialog {
		width: 400px; max-width: 90vw;
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
	.field input:focus { border-color: var(--accent); }

	.checkbox { display: flex; align-items: center; gap: var(--space-2); font-size: 13px; color: var(--fg-secondary); cursor: pointer; }
	.checkbox input { accent-color: var(--accent); }

	.spin { animation: spin 1s linear infinite; }
	@keyframes spin { to { transform: rotate(360deg); } }
</style>
