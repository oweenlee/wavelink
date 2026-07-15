<script lang="ts">
	import { Volume2 } from 'lucide-svelte';
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
	<Volume2 size={13} style="color: var(--fg-tertiary);" />
	<span class="vol-pct">{Math.round(value * 100)}%</span>
</div>

<style>
	.vol { display: flex; align-items: center; gap: 4px; cursor: default; }
	.vol-pct { font-size: 10px; color: var(--fg-tertiary); font-variant-numeric: tabular-nums; min-width: 28px; text-align: right; }
</style>
