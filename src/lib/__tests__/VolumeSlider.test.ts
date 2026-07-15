import { describe, it, expect, vi } from 'vitest';
import { render, fireEvent } from '@testing-library/svelte';
import VolumeSlider from '$lib/components/controls/VolumeSlider.svelte';

describe('VolumeSlider', () => {
	it('renders with default max and step', () => {
		const { container } = render(VolumeSlider, {
			value: 0.5,
			oninput: vi.fn(),
		});
		const input = container.querySelector('input[type="range"]') as HTMLInputElement;
		expect(input).toBeInTheDocument();
		expect(input.value).toBe('0.5');
		expect(parseFloat(input.max)).toBeCloseTo(1.5);
		expect(parseFloat(input.step)).toBeCloseTo(0.01);
	});

	it('renders with custom max', () => {
		const { container } = render(VolumeSlider, {
			value: 1,
			max: 2,
			oninput: vi.fn(),
		});
		const input = container.querySelector('input') as HTMLInputElement;
		expect(parseFloat(input.max)).toBe(2);
	});

	it('fires oninput on change', async () => {
		const oninput = vi.fn();
		const { container } = render(VolumeSlider, {
			value: 0.5,
			oninput,
		});
		const input = container.querySelector('input') as HTMLInputElement;
		await fireEvent.input(input, { target: { value: '0.75' } });
		expect(oninput).toHaveBeenCalledWith(0.75);
	});
});
