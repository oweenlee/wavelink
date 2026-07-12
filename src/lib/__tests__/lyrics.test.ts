import { describe, it, expect } from 'vitest';
import { parseLrc } from '$lib/utils/lyrics';

describe('parseLrc', () => {
	it('parses standard LRC tags', () => {
		const result = parseLrc('[01:23.45]Hello world\n[02:34.56]Second line');
		expect(result).toEqual([
			{ time: 83.45, text: 'Hello world' },
			{ time: 154.56, text: 'Second line' },
		]);
	});

	it('parses tags with 3-digit milliseconds', () => {
		const result = parseLrc('[01:23.456]Fine ms');
		expect(result[0].time).toBeCloseTo(83.456, 3);
	});

	it('handles multiple tags on one line', () => {
		const result = parseLrc('[00:12.34][00:34.56]Repeated line');
		expect(result).toHaveLength(2);
		expect(result[0].time).toBeCloseTo(12.34, 2);
		expect(result[1].time).toBeCloseTo(34.56, 2);
	});

	it('skips lines without text', () => {
		const result = parseLrc('[01:23.45]\n[02:34.56]Has text');
		expect(result).toHaveLength(1);
		expect(result[0].text).toBe('Has text');
	});

	it('handles empty input', () => {
		expect(parseLrc('')).toEqual([]);
		expect(parseLrc('\n\n')).toEqual([]);
	});

	it('handles non-LRC text without tags', () => {
		expect(parseLrc('plain text\nwithout tags')).toEqual([]);
	});

	it('handles mm:ss format (no decimals)', () => {
		const result = parseLrc('[01:23]No decimals');
		expect(result[0].time).toBe(83);
	});
});
