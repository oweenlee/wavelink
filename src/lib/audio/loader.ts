import { browser } from '$app/environment';
import type { Track } from './types';

/**
 * 通过 Tauri 后端加载曲库数据（SSR 安全）
 */

/** 使用 Tauri 文件对话框选择目录并扫描 */
export async function scanDirectory(): Promise<{
	scanned: number;
	errors: number;
	removed: number;
}> {
	if (!browser) throw new Error('只能在浏览器端使用');

	const { open } = await import('@tauri-apps/plugin-dialog');
	const { invoke } = await import('@tauri-apps/api/core');

	const selected = await open({
		directory: true,
		multiple: false,
		title: '选择音乐目录',
	});

	if (!selected) {
		throw new Error('未选择目录');
	}

	const result: { scanned: number; errors: number; removed: number } =
		await invoke('scan_dir', { path: selected });

	return result;
}

/** 从后端获取曲目列表 */
export async function getTracks(limit: number, offset: number): Promise<Track[]> {
	if (!browser) return [];
	const { invoke } = await import('@tauri-apps/api/core');
	return await invoke('get_tracks', { limit, offset });
}

/** 搜索曲目 */
export async function searchTracks(
	keyword: string,
	limit: number,
	offset: number,
): Promise<Track[]> {
	if (!browser) return [];
	const { invoke } = await import('@tauri-apps/api/core');
	return await invoke('search_tracks', { keyword, limit, offset });
}

/** 获取艺术家列表 */
export async function getArtists(): Promise<string[]> {
	if (!browser) return [];
	const { invoke } = await import('@tauri-apps/api/core');
	return await invoke('get_artists');
}

/** 获取指定艺术家的专辑列表 */
export async function getAlbumsByArtist(artist: string): Promise<string[]> {
	if (!browser) return [];
	const { invoke } = await import('@tauri-apps/api/core');
	return await invoke('get_albums_by_artist', { artist });
}

/** 获取指定专辑的曲目 */
export async function getTracksByAlbum(
	artist: string,
	album: string,
): Promise<Track[]> {
	if (!browser) return [];
	const { invoke } = await import('@tauri-apps/api/core');
	return await invoke('get_tracks_by_album', { artist, album });
}

/** 获取曲目总数 */
export async function getTrackCount(): Promise<number> {
	if (!browser) return 0;
	const { invoke } = await import('@tauri-apps/api/core');
	return await invoke('get_track_count');
}

/** 获取专辑封面 */
export async function getCover(trackId: number): Promise<string | null> {
	if (!browser) return null;
	const { invoke } = await import('@tauri-apps/api/core');
	return await invoke('get_cover', { trackId });
}

/** 获取音频引擎信息 */
export async function getAudioInfo(): Promise<{
	sample_rate: number;
	channels: number;
}> {
	if (!browser) return { sample_rate: 0, channels: 0 };
	const { invoke } = await import('@tauri-apps/api/core');
	return await invoke('audio_info');
}
