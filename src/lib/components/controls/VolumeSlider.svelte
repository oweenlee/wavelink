<script lang="ts">
	interface Props {
		value: number;
		max?: number;
		step?: number;
		oninput: (v: number) => void;
	}
	let { value, max = 1.5, step = 0.05, oninput }: Props = $props();

	function onWheel(e: WheelEvent) {
		e.preventDefault();
		const delta = e.deltaY > 0 ? -step : step;
		const next = Math.max(0, Math.min(max, +(value + delta).toFixed(2)));
		oninput(next);
	}
</script>

<div class="vol" onwheel={onWheel} title="滚轮调节音量">
	<svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" style="color: var(--fg-tertiary);">
		<polygon points="11 5 6 9 2 9 2 15 6 15 11 19"/>
		<path d="M19.07 4.93a10 10 0 0 1 0 14.14"/>
		<path d="M15.54 8.46a5 5 0 0 1 0 7.07"/>
	</svg>
	<span class="vol-pct">{Math.round(value * 100)}%</span>
</div>

<style>
	.vol { display: flex; align-items: center; gap: 4px; cursor: default; }
	.vol-pct { font-size: 10px; color: var(--fg-tertiary); font-variant-numeric: tabular-nums; min-width: 28px; text-align: right; }
</style>
