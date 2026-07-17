<script lang="ts">
	import { t } from '$lib/i18n/i18n.svelte';
import { Volume2, Volume1, Volume, VolumeX } from 'lucide-svelte';
	interface Props {
		value: number;
		max?: number;
		oninput: (v: number) => void;
	}
	let { value, max = 1.5, oninput }: Props = $props();

	let trackEl: HTMLDivElement | undefined = $state();
	let isDragging = $state(false);

	function updatePos(clientX: number) {
		if (!trackEl) return;
		const r = trackEl.getBoundingClientRect();
		const ratio = Math.max(0, Math.min(1, (clientX - r.left) / r.width));
		oninput(+(ratio * max).toFixed(2));
	}

	function onDown(e: MouseEvent) { isDragging = true; updatePos(e.clientX); window.addEventListener('mousemove', onMove); window.addEventListener('mouseup', onUp); }
	function onMove(e: MouseEvent) { if (isDragging) updatePos(e.clientX); }
	function onUp() { isDragging = false; window.removeEventListener('mousemove', onMove); window.removeEventListener('mouseup', onUp); }

	function onWheel(e: WheelEvent) {
		e.preventDefault();
		const step = 0.05;
		const delta = e.deltaY > 0 ? -step : step;
		const next = Math.max(0, Math.min(max, +(value + delta).toFixed(2)));
		oninput(next);
	}

	let fillPct = $derived(Math.min(100, (value / max) * 100));
	let Icon = $derived.by(() => {
		if (value === 0) return VolumeX;
		if (value < 0.35) return Volume;
		if (value < 0.7) return Volume1;
		return Volume2;
	});
</script>

<div class="vol" onwheel={onWheel} title={t('volume_scroll_hint')}>
	<Icon size={13} style="color: var(--fg-tertiary); flex-shrink: 0;" />
	<div class="track" bind:this={trackEl} onmousedown={onDown} role="slider" tabindex="0" aria-valuemin={0} aria-valuemax={max} aria-valuenow={value}>
		<div class="track-bg" class:dragging={isDragging}>
			<div class="track-fill" style="width: {fillPct}%;"></div>
			<div class="track-knob" style="left: {fillPct}%;"></div>
		</div>
	</div>
</div>

<style>
	.vol { display: flex; align-items: center; gap: 6px; min-width: 100px; }
	.track { flex: 1; height: 24px; display: flex; align-items: center; cursor: pointer; }
	.track-bg { position: relative; width: 100%; height: 3px; background: rgba(255,255,255,0.08); border-radius: 2px; overflow: visible; }
	.track-fill { height: 100%; background: var(--fg-tertiary); border-radius: 2px; position: relative; }
	.track-knob {
		position: absolute; top: 50%; width: 10px; height: 10px;
		border-radius: 50%; background: var(--fg-primary);
		transform: translate(-50%, -50%) scale(0);
		transition: transform 0.12s;
		pointer-events: none;
	}
	.track:hover .track-knob, .dragging .track-knob { transform: translate(-50%, -50%) scale(1); }
	.track:hover .track-bg { height: 4px; }
	.track-bg.dragging { height: 4px; }
</style>
