<script lang="ts">
	interface Props {
		value: number;
		max?: number;
		step?: number;
		oninput: (v: number) => void;
	}
	let { value, max = 1.5, step = 0.01, oninput }: Props = $props();
</script>

<div class="vol">
	<svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" style="color: var(--fg-tertiary);">
		<polygon points="11 5 6 9 2 9 2 15 6 15 11 19"/>
		<path d="M19.07 4.93a10 10 0 0 1 0 14.14"/>
		<path d="M15.54 8.46a5 5 0 0 1 0 7.07"/>
	</svg>
	<input type="range" min="0" max={max} step={step} value={value} oninput={(e) => oninput(parseFloat((e.currentTarget as HTMLInputElement).value))} class="vol-slider" />
</div>

<style>
	.vol { display: flex; align-items: center; gap: 4px; }
	.vol-slider { width: 52px; height: 3px; -webkit-appearance: none; appearance: none; background: rgba(255,255,255,0.08); border-radius: 2px; outline: none; cursor: pointer; transition: height 0.12s; }
	.vol-slider:hover { height: 4px; }
	.vol-slider::-webkit-slider-thumb { -webkit-appearance: none; width: 0; height: 0; border-radius: 50%; background: var(--fg-secondary); border: none; cursor: pointer; transition: width 0.12s; }
	.vol-slider:hover::-webkit-slider-thumb { width: 8px; height: 8px; }
</style>
