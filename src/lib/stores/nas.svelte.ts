import { invoke } from '@tauri-apps/api/core';

export interface NasConnection {
	id: string;
	name: string;
	server: string;
	share: string;
	username: string;
	auto_mount: boolean;
	mount_path: string;
	mounted?: boolean;
}

function createNasStore() {
	let connections = $state<NasConnection[]>([]);
	let loading = $state(false);
	let error = $state<string | null>(null);

	async function loadConnections() {
		loading = true;
		error = null;
		try {
			const list: NasConnection[] = await invoke('nas_list');
			for (const conn of list) {
				try {
					conn.mounted = await invoke<boolean>('nas_is_mounted', { id: conn.id });
				} catch {
					conn.mounted = false;
				}
			}
			connections = list;
		} catch (e) {
			error = String(e);
		} finally {
			loading = false;
		}
	}

	async function addConnection(
		name: string,
		server: string,
		share: string,
		username: string,
		password: string,
		autoMount: boolean
	) {
		await invoke('nas_add', { name, server, share, username, password, autoMount });
		await loadConnections();
	}

	async function removeConnection(id: string) {
		await invoke('nas_remove', { id });
		await loadConnections();
	}

	async function mountConnection(id: string): Promise<string> {
		const path: string = await invoke('nas_mount', { id });
		await loadConnections();
		return path;
	}

	async function unmountConnection(id: string) {
		await invoke('nas_unmount', { id });
		await loadConnections();
	}

	return {
		get connections() { return connections; },
		get loading() { return loading; },
		get error() { return error; },
		loadConnections,
		addConnection,
		removeConnection,
		mountConnection,
		unmountConnection,
	};
}

export const nasStore = createNasStore();
