import { browser } from '$app/environment';

let _invoke: typeof import('@tauri-apps/api/core')['invoke'] | null = null;

export async function lazyInvoke() {
  if (_invoke) return _invoke;
  const { invoke } = await import('@tauri-apps/api/core');
  _invoke = invoke;
  return _invoke;
}

export async function lazyListen() {
  const { listen } = await import('@tauri-apps/api/event');
  return listen;
}

export { browser };
