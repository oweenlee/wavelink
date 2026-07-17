import zh from './zh.json';

export type Locale = 'zh' | 'en';
export type I18nKey = keyof typeof zh;

let _locale = $state<Locale>('zh');
let _dict = $state<Record<string, string>>(zh);

export function getLocale() {
	return _locale;
}

export function setLocale(l: Locale) {
	_locale = l;
	if (l === 'en') {
		import('./en.json').then(m => _dict = m).catch(() => _dict = zh);
	} else {
		_dict = zh;
	}
}

export function t(key: I18nKey, params?: Record<string, string | number>): string {
	let text = _dict[key as string] ?? key;
	if (params) {
		for (const [k, v] of Object.entries(params)) {
			text = text.replace(`{${k}}`, String(v));
		}
	}
	return text;
}
