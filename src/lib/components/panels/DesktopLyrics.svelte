<script lang="ts">
	import { browser } from '$app/environment';
	import { getSettingsState } from '$lib/stores/settings.svelte';

	const settings = getSettingsState();

	type LrcLine = { time: number; text: string };
	let currentLine = $state('');
	let nextLine = $state('');
	let accentColor = $state('#8888cc');

	$effect(() => {
		if (!browser) return;
		let cancelled = false;
		let unlistenFns: (() => void)[] = [];

		import('@tauri-apps/api/event').then(async ({ listen }) => {
			if (cancelled) return;
			const fns = await Promise.all([
				listen<string>('lyrics:current_line', (e) => { if (!cancelled) currentLine = e.payload || ''; }),
				listen<string>('lyrics:next_line', (e) => { if (!cancelled) nextLine = e.payload || ''; }),
			]);
			if (cancelled) { fns.forEach(fn => fn()); return; }
			unlistenFns.push(...fns);
		});

		settings.load().then(() => {
			if (!cancelled) accentColor = settings.accentColor;
		});

		return () => {
			cancelled = true;
			for (const fn of unlistenFns) fn();
		};
	});

	// 鼠标穿透切换
	let passthrough = $state(true);

	async function togglePassthrough() {
		passthrough = !passthrough;
		if (!browser) return;
		const { getCurrentWindow } = await import('@tauri-apps/api/window');
		await getCurrentWindow().setIgnoreCursorEvents(passthrough);
	}

	// 关闭歌词窗口
	async function closeWindow() {
		if (!browser) return;
		const { getCurrentWindow } = await import('@tauri-apps/api/window');
		await getCurrentWindow().hide();
	}
</script>

<div
	class="lyrics-overlay"
	data-tauri-drag-region
	style="--accent: {accentColor};"
>
	{#if passthrough}
		<!-- 鼠标穿透模式：只显示文字 -->
		<div class="lyrics-text" data-tauri-drag-region>
			<div class="current-line">{currentLine || '♪'}</div>
			{#if nextLine}
				<div class="next-line">{nextLine}</div>
			{/if}
		</div>
	{:else}
		<!-- 交互模式：显示控制按钮 -->
		<div class="lyrics-text interactive">
			<div class="current-line">{currentLine || '♪'}</div>
			{#if nextLine}
				<div class="next-line">{nextLine}</div>
			{/if}
		</div>
		<div class="lyrics-controls">
			<button class="ctrl-btn" onclick={togglePassthrough} title="穿透">⊘</button>
			<button class="ctrl-btn close" onclick={closeWindow} title="关闭">✕</button>
		</div>
	{/if}
</div>

<style>
	.lyrics-overlay {
		width: 100vw;
		height: 100vh;
		display: flex;
		align-items: center;
		justify-content: center;
		position: relative;
		background: transparent;
		overflow: hidden;
	}

	.lyrics-text {
		text-align: center;
		padding: 0 24px;
		cursor: move;
		user-select: none;
	}

	.current-line {
		font-size: 28px;
		font-weight: 700;
		color: var(--accent);
		text-shadow:
			0 0 20px rgba(0, 0, 0, 0.6),
			0 2px 8px rgba(0, 0, 0, 0.4);
		line-height: 1.4;
		transition: opacity 0.3s ease;
	}

	.next-line {
		font-size: 16px;
		font-weight: 500;
		color: rgba(255, 255, 255, 0.5);
		text-shadow: 0 0 12px rgba(0, 0, 0, 0.5);
		margin-top: 6px;
		line-height: 1.3;
	}

	.lyrics-controls {
		position: absolute;
		top: 8px;
		right: 12px;
		display: flex;
		gap: 6px;
	}

	.ctrl-btn {
		width: 26px;
		height: 26px;
		border-radius: 50%;
		border: 1px solid rgba(255, 255, 255, 0.2);
		background: rgba(0, 0, 0, 0.3);
		color: rgba(255, 255, 255, 0.7);
		font-size: 12px;
		cursor: pointer;
		display: flex;
		align-items: center;
		justify-content: center;
		transition: all 0.2s;
	}

	.ctrl-btn:hover {
		background: rgba(0, 0, 0, 0.5);
		color: white;
	}

	.ctrl-btn.close:hover {
		background: rgba(220, 50, 50, 0.6);
	}

	.interactive {
		cursor: default;
	}
</style>
