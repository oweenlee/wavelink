import { describe, it, expect, vi } from 'vitest';
import { render } from '@testing-library/svelte';
import ProgressBar from '$lib/components/controls/ProgressBar.svelte';

describe('ProgressBar', () => {
	const defaultProps = { value: 50, max: 100, currentTime: 25, ondrag: vi.fn() };

	it('renders with correct time labels', () => {
		const { container } = render(ProgressBar, defaultProps);
		const times = container.querySelectorAll('.times span');
		expect(times).toHaveLength(2);
		expect(times[0].textContent).toBe('0:25');
		expect(times[1].textContent).toBe('1:40');
	});

	it('fills correct percentage', () => {
		const { container } = render(ProgressBar, { ...defaultProps, value: 75, max: 200 });
		const fill = container.querySelector('.track-fill') as HTMLElement;
		expect(fill.style.width).toBe('37.5%');
	});

	it('renders custom color', () => {
		const { container } = render(ProgressBar, { ...defaultProps, color: '#ff0000' });
		const fill = container.querySelector('.track-fill') as HTMLElement;
		expect(fill.style.background).toContain('rgb(255, 0, 0)');
	});

	it('shows 0:00 when currentTime is 0', () => {
		const { container } = render(ProgressBar, { ...defaultProps, currentTime: 0 });
		const times = container.querySelectorAll('.times span');
		expect(times[0].textContent).toBe('0:00');
	});
});
