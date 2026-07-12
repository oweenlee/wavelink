import js from '@eslint/js';
import ts from 'typescript-eslint';
import svelte from 'eslint-plugin-svelte';
import globals from 'globals';

export default [
	js.configs.recommended,
	...ts.configs.recommended,
	...svelte.configs.recommended,
	{
		files: ['**/*.svelte', '**/*.svelte.ts'],
		languageOptions: {
			parserOptions: {
				parser: ts.parser,
			},
			globals: {
				...globals.browser,
				...globals.es2021,
			},
		},
	},
	{
		files: ['**/*.ts'],
		languageOptions: {
			globals: {
				...globals.browser,
				...globals.es2021,
			},
		},
	},
	{
		rules: {
			'@typescript-eslint/no-explicit-any': 'off',
			'@typescript-eslint/no-unused-vars': ['warn', { argsIgnorePattern: '^_' }],
			'no-console': 'warn',
		},
	},
	{
		ignores: ['build/', '.svelte-kit/', 'dist/', 'node_modules/', 'src-tauri/'],
	},
];
