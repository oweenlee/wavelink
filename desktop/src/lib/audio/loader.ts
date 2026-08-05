import { browser, lazyInvoke } from '$lib/tauri';

export async function scanDirectory(): Promise<{
	scanned: number;
	errors: number;
	removed: number;
}> {
	if (!browser) throw new Error('Browser only');

	const { open } = await import('@tauri-apps/plugin-dialog');
	const invoke = await lazyInvoke();

	const selected = await open({
		directory: true,
		multiple: false,
		title: 'Select music directory',
	});
	if (!selected) throw new Error('No directory selected');

	return await invoke('scan_dir', { path: selected });
}

export async function importPlaylist(): Promise<string[]> {
	if (!browser) throw new Error('Browser only');
	const { open } = await import('@tauri-apps/plugin-dialog');
	const invoke = await lazyInvoke();
	const selected = await open({
		multiple: false,
		title: 'Select playlist file',
		filters: [{ name: 'Playlist', extensions: ['m3u', 'm3u8', 'pls'] }],
	});
	if (!selected) throw new Error('No file selected');
	return await invoke('import_playlist', { path: selected });
}

export async function getScanFolders(): Promise<string[]> {
	if (!browser) return [];
	return await (await lazyInvoke())('get_scan_folders');
}

export async function removeScanFolder(path: string): Promise<number> {
	if (!browser) return 0;
	return await (await lazyInvoke())('remove_scan_folder', { path });
}
