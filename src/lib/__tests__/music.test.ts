import { describe, it, expect } from 'vitest';
import { formatTime } from '$lib/data/music';

describe('formatTime', () => {
	it('formats seconds to m:ss', () => {
		expect(formatTime(0)).toBe('0:00');
		expect(formatTime(5)).toBe('0:05');
		expect(formatTime(65)).toBe('1:05');
		expect(formatTime(3661)).toBe('61:01');
	});

	it('handles edge cases', () => {
		expect(formatTime(-1)).toBe('0:00');
		expect(formatTime(NaN)).toBe('0:00');
		expect(formatTime(Infinity)).toBe('0:00');
	});

	it('handles large values', () => {
		expect(formatTime(7200)).toBe('120:00');
	});
});
