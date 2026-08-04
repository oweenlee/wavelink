import { describe, it, expect, vi } from 'vitest';
import { render } from '@testing-library/svelte';
import VolumeSlider from '$lib/components/controls/VolumeSlider.svelte';

describe('VolumeSlider', () => {
	it('renders volume slider with default max', () => {
		const { container } = render(VolumeSlider, {
			value: 0.5,
			oninput: vi.fn(),
		});
		const slider = container.querySelector('[role="slider"]');
		expect(slider).toBeInTheDocument();
		expect(slider?.getAttribute('aria-valuenow')).toBe('0.5');
		expect(slider?.getAttribute('aria-valuemax')).toBe('1.5');
	});

	it('renders with custom max', () => {
		const { container } = render(VolumeSlider, {
			value: 1,
			max: 2,
			oninput: vi.fn(),
		});
		const slider = container.querySelector('[role="slider"]');
		expect(slider?.getAttribute('aria-valuemax')).toBe('2');
	});

	it('calls oninput on wheel event', async () => {
		const oninput = vi.fn();
		const { container } = render(VolumeSlider, {
			value: 0.5,
			oninput,
		});
		const vol = container.querySelector('.vol') as HTMLElement;
		vol.dispatchEvent(new WheelEvent('wheel', { deltaY: -100, bubbles: true }));
		expect(oninput).toHaveBeenCalled();
		const val = oninput.mock.calls[0][0] as number;
		expect(val).toBeGreaterThan(0.5);
	});

	it('shows VolumeX icon when value is 0', () => {
		const { container } = render(VolumeSlider, {
			value: 0,
			oninput: vi.fn(),
		});
		expect(container.innerHTML).toContain('volume-x');
	});
});
