import { sveltekit } from '@sveltejs/kit/vite';
import { defineConfig } from 'vite';
import { visualizer } from 'rollup-plugin-visualizer';

export default defineConfig({
	plugins: [
		sveltekit(),
		// Only active when ANALYZE=1
		...(process.env.ANALYZE === '1'
			? [visualizer({ open: true, filename: 'dist/stats.html', gzipSize: true, brotliSize: true })]
			: []),
	],

	server: {
		port: 5173,
		strictPort: true,
		watch: {
			ignored: ['**/src-tauri/**'],
		},
	},
});
