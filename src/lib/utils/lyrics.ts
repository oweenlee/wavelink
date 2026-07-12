export function parseLrc(text: string): { time: number; text: string }[] {
	const result: { time: number; text: string }[] = [];
	for (const line of text.split('\n')) {
		const regex = /\[(\d{1,3}):(\d{2})(?:[\.:](\d{2,3}))?\]/g;
		const matches = [...line.matchAll(regex)];
		if (matches.length === 0) continue;
		const textPart = line.replace(/\[\d{1,3}:\d{2}(?:[\.:]\d{2,3})?\]/g, '').trim();
		if (!textPart) continue;
		for (const m of matches) {
			const time = parseInt(m[1]) * 60 + parseInt(m[2]) + (m[3] ? (m[3].length === 2 ? parseInt(m[3]) * 10 : parseInt(m[3])) : 0) / 1000;
			result.push({ time, text: textPart });
		}
	}
	return result;
}
