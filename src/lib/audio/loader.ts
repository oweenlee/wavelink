import { browser, lazyInvoke } from '$lib/tauri';
import type { Track } from './types';

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

export async function getTracks(limit: number, offset: number): Promise<Track[]> {
	if (!browser) return [];
	return await (await lazyInvoke())('get_tracks', { limit, offset });
}

export async function searchTracks(keyword: string, limit: number, offset: number): Promise<Track[]> {
	if (!browser) return [];
	return await (await lazyInvoke())('search_tracks', { keyword, limit, offset });
}

export async function getArtists(): Promise<string[]> {
	if (!browser) return [];
	return await (await lazyInvoke())('get_artists');
}

export async function getAlbumsByArtist(artist: string): Promise<string[]> {
	if (!browser) return [];
	return await (await lazyInvoke())('get_albums_by_artist', { artist });
}

export async function getTracksByAlbum(artist: string, album: string): Promise<Track[]> {
	if (!browser) return [];
	return await (await lazyInvoke())('get_tracks_by_album', { artist, album });
}

export async function getTrackCount(): Promise<number> {
	if (!browser) return 0;
	return await (await lazyInvoke())('get_track_count');
}

export async function getCover(trackId: number): Promise<string | null> {
	if (!browser) return null;
	return await (await lazyInvoke())('get_cover', { trackId });
}

export async function getAudioInfo(): Promise<{ sample_rate: number; channels: number }> {
	if (!browser) return { sample_rate: 0, channels: 0 };
	return await (await lazyInvoke())('audio_info');
}
