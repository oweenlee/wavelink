import type { PlaybackState } from './stores/playback.svelte';

/**
 * Keyboard shortcut module.
 * Extracted from +page.svelte for separation of concerns.
 *
 * Usage:
 *   import { createKeyboardHandler } from '$lib/keyboard';
 *   const onKeydown = createKeyboardHandler(playback);
 *   <svelte:window onkeydown={onKeydown} />
 */

export function createKeyboardHandler(playback: PlaybackState) {
	return function onKeydown(e: KeyboardEvent) {
		// Don't intercept when typing in inputs
		if (e.target instanceof HTMLInputElement || e.target instanceof HTMLTextAreaElement) return;

		switch (e.key) {
			case ' ':
				e.preventDefault();
				playback.togglePlay();
				break;
			case 'ArrowLeft':
				e.preventDefault();
				if (e.ctrlKey) {
					playback.prev();
				} else if (playback.duration > 0) {
					const target = Math.max(0, playback.currentTime - 5);
					playback.currentTime = target;
				}
				break;
			case 'ArrowRight':
				e.preventDefault();
				if (e.ctrlKey) {
					playback.next();
				} else if (playback.duration > 0) {
					const target = Math.min(playback.duration, playback.currentTime + 5);
					playback.currentTime = target;
				}
				break;
			case 'ArrowUp':
				e.preventDefault();
				playback.volume = Math.min(1.5, playback.volume + 0.05);
				break;
			case 'ArrowDown':
				e.preventDefault();
				playback.volume = Math.max(0, playback.volume - 0.05);
				break;
		}
	};
}
