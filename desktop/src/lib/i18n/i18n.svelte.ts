import zh from './zh.json';
import en from './en.json';

export type Locale = 'zh' | 'en';
export type I18nKey = keyof typeof zh;

const dicts: Record<Locale, Record<string, string>> = { zh, en };

let _locale = $state<Locale>('zh');
let _dict = $state<Record<string, string>>(zh);

export function getLocale() {
	return _locale;
}

export function setLocale(l: Locale) {
	_locale = l;
	_dict = dicts[l];
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
