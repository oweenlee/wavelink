import { describe, it, expect, vi, beforeAll } from 'vitest';
import { extractColorFromDataUrl } from '$lib/utils/colorExtractor';

beforeAll(() => {
	// jsdom 没有真正的 canvas 渲染，需要 mock getContext
	HTMLCanvasElement.prototype.getContext = vi.fn(() => {
		const data = new Uint8ClampedArray(50 * 50 * 4);
		// 填充为纯蓝色 (0, 0, 255)
		for (let i = 0; i < data.length; i += 4) {
			data[i] = 0;     // R
			data[i + 1] = 0; // G
			data[i + 2] = 255; // B
			data[i + 3] = 255; // A
		}
		return {
			drawImage: vi.fn(),
			getImageData: () => ({ data, width: 50, height: 50 }),
		} as any;
	}) as any;

	// mock Image: 构造时立即触发 onload
	vi.stubGlobal('Image', class {
		crossOrigin = '';
		onload: (() => void) | null = null;
		src = '';
		constructor() { setTimeout(() => this.onload?.(), 0); }
	});
});

describe('extractColorFromDataUrl', () => {
	it('returns a hex color string', async () => {
		const color = await extractColorFromDataUrl('data:image/png;base64,test');
		expect(color).toMatch(/^#[0-9a-f]{6}$/);
	});

	it('extracts the dominant color from blue pixels', async () => {
		const color = await extractColorFromDataUrl('data:image/png;base64,blue');
		expect(color).toBe('#0000ff');
	});

	it('rejects when the image fails to load', async () => {
		// 让 Image.onerror 触发
		vi.stubGlobal('Image', class {
			crossOrigin = '';
			onerror: (() => void) | null = null;
			src = '';
			constructor() { setTimeout(() => this.onerror?.(), 0); }
		});
		await expect(extractColorFromDataUrl('invalid')).rejects.toThrow('Failed to load image');
	});
});
