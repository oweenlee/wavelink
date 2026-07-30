<script lang="ts">
	import { formatTime } from '$lib/utils/time';

	interface Props { value: number; max: number; currentTime: number; ondrag: (ratio: number) => void; color?: string; }
	let { value, max, currentTime, ondrag, color = '#e2a63d' }: Props = $props();

	let isDragging = $state(false);
	let trackEl: HTMLDivElement | undefined = $state();
	let hoverRatio = $state(0);
	let showTooltip = $state(false);

	function updatePosition(clientX: number) {
		if (!trackEl) return;
		const r = trackEl.getBoundingClientRect();
		const ratio = Math.max(0, Math.min(1, (clientX - r.left) / r.width));
		hoverRatio = ratio;
		showTooltip = true;
		if (isDragging) ondrag(ratio);
	}

	function updateHover(clientX: number) {
		if (!trackEl || isDragging) return;
		const r = trackEl.getBoundingClientRect();
		hoverRatio = Math.max(0, Math.min(1, (clientX - r.left) / r.width));
		showTooltip = true;
	}

	function onDown(e: MouseEvent) { isDragging = true; updatePosition(e.clientX); window.addEventListener('mousemove', onMouseMove); window.addEventListener('mouseup', onUp); }
	function onMouseMove(e: MouseEvent) { updatePosition(e.clientX); }
	function onUp() { isDragging = false; showTooltip = false; window.removeEventListener('mousemove', onMouseMove); window.removeEventListener('mouseup', onUp); }

	function onTouchDown(e: TouchEvent) { e.preventDefault(); isDragging = true; const t = e.touches[0]; if (t) updatePosition(t.clientX); window.addEventListener('touchmove', onTouchMove); window.addEventListener('touchend', onTouchUp); }
	function onTouchMove(e: TouchEvent) { const t = e.touches[0]; if (t) updatePosition(t.clientX); }
	function onTouchUp() { isDragging = false; showTooltip = false; window.removeEventListener('touchmove', onTouchMove); window.removeEventListener('touchend', onTouchUp); }

	let fillPct = $derived(max > 0 ? Math.min(100, (value / max) * 100) : 0);
</script>

<div class="progress">
	<div class="track" bind:this={trackEl} onmousedown={onDown} onmouseenter={() => { if (!isDragging) showTooltip = true; }} onmouseleave={() => { if (!isDragging) showTooltip = false; }} onmousemove={(e) => updateHover(e.clientX)} ontouchstart={onTouchDown} ontouchmove={onTouchMove} ontouchend={onTouchUp} role="slider" tabindex="0" aria-valuemin={0} aria-valuemax={max} aria-valuenow={currentTime}>
		<div class="track-bg" class:dragging={isDragging}>
			<div class="track-fill" style="width: {fillPct}%; background: {color};"></div>
			<div class="track-knob" style="left: {fillPct}%; background: {color}; box-shadow: 0 0 8px {color}80;"></div>
		</div>
		{#if showTooltip && max > 0}
			<div class="tooltip" style="left: {hoverRatio * 100}%;">{formatTime(Math.floor(hoverRatio * max))}</div>
		{/if}
	</div>
	<div class="times">
		<span>{formatTime(Math.floor(currentTime))}</span>
		<span>{formatTime(Math.floor(max))}</span>
	</div>
</div>

<style>
	.progress { width: 100%; user-select: none; padding: 2px 0; }
	.track { position: relative; height: 24px; display: flex; align-items: center; cursor: pointer; outline: none; }
	.track-bg { position: relative; width: 100%; height: 4px; background: rgba(255,255,255,0.06); border-radius: 3px; overflow: visible; transition: height 0.15s var(--ease-out); }
	.track:hover .track-bg { height: 6px; }
	.track-bg.dragging { height: 6px; }
	.track-fill { height: 100%; border-radius: 3px; transition: width 0.05s linear; position: relative; }
	.track-knob {
		position: absolute; top: 50%; width: 12px; height: 12px;
		border-radius: 50%; transform: translate(-50%, -50%) scale(0);
		opacity: 0; transition: transform 0.15s var(--ease-out), opacity 0.12s;
		pointer-events: none;
	}
	.track:hover .track-knob, .dragging .track-knob { opacity: 1; transform: translate(-50%, -50%) scale(1); }
	.times { display: flex; justify-content: space-between; font-size: 10px; color: var(--fg-tertiary); margin-top: 2px; font-variant-numeric: tabular-nums; }
	.tooltip {
		position: absolute; top: -28px; transform: translateX(-50%);
		font-size: 10px; color: var(--fg-secondary);
		background: rgba(10,10,20,0.9); padding: 2px 6px;
		border-radius: 4px; border: 1px solid var(--separator);
		pointer-events: none; white-space: nowrap;
	}
</style>
