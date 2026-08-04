import { describe, it, expect, vi } from 'vitest';
import { createKeyboardHandler } from '$lib/keyboard';

function createMockPlayback() {
	return {
		currentTime: 0,
		duration: 100,
		volume: 1.0,
		togglePlay: vi.fn(),
		prev: vi.fn(),
		next: vi.fn(),
	} as any;
}

describe('createKeyboardHandler', () => {
	it('calls togglePlay on Space', () => {
		const pb = createMockPlayback();
		createKeyboardHandler(pb)(new KeyboardEvent('keydown', { key: ' ' }));
		expect(pb.togglePlay).toHaveBeenCalledOnce();
	});

	it('seeks back 5s on ArrowLeft', () => {
		const pb = createMockPlayback();
		pb.currentTime = 50;
		createKeyboardHandler(pb)(new KeyboardEvent('keydown', { key: 'ArrowLeft' }));
		expect(pb.currentTime).toBe(45);
	});

	it('calls prev on Ctrl+ArrowLeft', () => {
		const pb = createMockPlayback();
		createKeyboardHandler(pb)(new KeyboardEvent('keydown', { key: 'ArrowLeft', ctrlKey: true }));
		expect(pb.prev).toHaveBeenCalledOnce();
	});

	it('seeks forward 5s on ArrowRight', () => {
		const pb = createMockPlayback();
		pb.currentTime = 10;
		createKeyboardHandler(pb)(new KeyboardEvent('keydown', { key: 'ArrowRight' }));
		expect(pb.currentTime).toBe(15);
	});

	it('calls next on Ctrl+ArrowRight', () => {
		const pb = createMockPlayback();
		createKeyboardHandler(pb)(new KeyboardEvent('keydown', { key: 'ArrowRight', ctrlKey: true }));
		expect(pb.next).toHaveBeenCalledOnce();
	});

	it('does not seek if duration is 0 on ArrowLeft', () => {
		const pb = createMockPlayback();
		pb.currentTime = 10;
		pb.duration = 0;
		createKeyboardHandler(pb)(new KeyboardEvent('keydown', { key: 'ArrowLeft' }));
		expect(pb.currentTime).toBe(10);
	});

	it('clamps ArrowLeft to 0', () => {
		const pb = createMockPlayback();
		pb.currentTime = 2;
		createKeyboardHandler(pb)(new KeyboardEvent('keydown', { key: 'ArrowLeft' }));
		expect(pb.currentTime).toBe(0);
	});

	it('clamps ArrowRight to duration', () => {
		const pb = createMockPlayback();
		pb.currentTime = 98;
		createKeyboardHandler(pb)(new KeyboardEvent('keydown', { key: 'ArrowRight' }));
		expect(pb.currentTime).toBe(100);
	});

	it('increases volume on ArrowUp', () => {
		const pb = createMockPlayback();
		pb.volume = 0.5;
		createKeyboardHandler(pb)(new KeyboardEvent('keydown', { key: 'ArrowUp' }));
		expect(pb.volume).toBeCloseTo(0.55);
	});

	it('clamps volume to 1.5 on ArrowUp', () => {
		const pb = createMockPlayback();
		pb.volume = 1.48;
		createKeyboardHandler(pb)(new KeyboardEvent('keydown', { key: 'ArrowUp' }));
		expect(pb.volume).toBe(1.5);
	});

	it('decreases volume on ArrowDown', () => {
		const pb = createMockPlayback();
		pb.volume = 0.5;
		createKeyboardHandler(pb)(new KeyboardEvent('keydown', { key: 'ArrowDown' }));
		expect(pb.volume).toBeCloseTo(0.45);
	});

	it('clamps volume to 0 on ArrowDown', () => {
		const pb = createMockPlayback();
		pb.volume = 0.02;
		createKeyboardHandler(pb)(new KeyboardEvent('keydown', { key: 'ArrowDown' }));
		expect(pb.volume).toBe(0);
	});

	it('ignores Space when target is input', () => {
		const pb = createMockPlayback();
		const handler = createKeyboardHandler(pb);
		const ev = new KeyboardEvent('keydown', { key: ' ' });
		Object.defineProperty(ev, 'target', { value: document.createElement('input') });
		handler(ev);
		expect(pb.togglePlay).not.toHaveBeenCalled();
	});

	it('ignores Space when target is textarea', () => {
		const pb = createMockPlayback();
		const handler = createKeyboardHandler(pb);
		const ev = new KeyboardEvent('keydown', { key: ' ' });
		Object.defineProperty(ev, 'target', { value: document.createElement('textarea') });
		handler(ev);
		expect(pb.togglePlay).not.toHaveBeenCalled();
	});
});
