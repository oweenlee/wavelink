<script lang="ts">
	import '../app.css';
	import { browser } from '$app/environment';

	let { children } = $props();

	$effect(() => {
		if (!browser) return;
		import('@tauri-apps/api/window').then(({ getCurrentWindow }) => {
			const win = getCurrentWindow();
			if (win.label === 'main') win.show();
		});
	});
</script>

{@render children()}
