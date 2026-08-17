<script lang="ts">
	import { Eye, EyeOff } from 'lucide-svelte';

	interface Props {
		value?: string;
		placeholder?: string;
	}
	let { value = $bindable(''), placeholder = '' }: Props = $props();

	let show = $state(false);
</script>

<div class="pw-wrap">
	<input
		type={show ? 'text' : 'password'}
		bind:value
		{placeholder}
		spellcheck="false"
		autocomplete="new-password"
	/>
	<button
		class="pw-toggle"
		type="button"
		aria-label={show ? 'hide password' : 'show password'}
		onclick={() => (show = !show)}
	>
		{#if show}<EyeOff size={15} />{:else}<Eye size={15} />{/if}
	</button>
</div>

<style>
	.pw-wrap { position: relative; display: flex; align-items: center; }

	.pw-wrap input {
		width: 100%;
		padding: var(--space-2) 34px var(--space-2) var(--space-3);
		border: 1px solid var(--glass-border);
		border-radius: var(--radius-sm); background: var(--bg-active);
		color: var(--fg-primary); font-size: 13px; font-family: inherit;
		outline: none; transition: border-color 0.12s, box-shadow 0.12s;
	}
	.pw-wrap input:focus { border-color: var(--accent); box-shadow: 0 0 0 3px color-mix(in srgb, var(--accent) 12%, transparent); }

	.pw-toggle {
		position: absolute; right: 4px;
		width: 28px; height: 28px; border: none; border-radius: var(--radius-sm);
		background: transparent; color: var(--fg-tertiary); cursor: pointer;
		display: flex; align-items: center; justify-content: center;
		transition: all 0.12s;
	}
	.pw-toggle:hover { color: var(--fg-primary); background: var(--bg-hover); }
</style>