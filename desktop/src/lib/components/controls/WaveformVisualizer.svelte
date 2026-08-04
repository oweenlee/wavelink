<script lang="ts">
  import { browser } from '$app/environment';
  import { onMount } from 'svelte';

  let { width = 320, height = 64 }: { width?: number; height?: number } = $props();

  let canvas: HTMLCanvasElement;
  let ctx: CanvasRenderingContext2D | null = null;
  let rafId = 0;
  let _invoke: ((cmd: string, args?: any) => Promise<any>) | null = null;

  onMount(() => {
    if (!browser) return;
    ctx = canvas.getContext('2d');

    const dpr = window.devicePixelRatio || 1;
    canvas.width = width * dpr;
    canvas.height = height * dpr;
    ctx!.scale(dpr, dpr);

    import('@tauri-apps/api/core').then(mod => { _invoke = mod.invoke; });

    function draw() {
      if (!ctx || !_invoke) { rafId = requestAnimationFrame(draw); return; }
      _invoke('read_audio_samples', { maxSamples: 512 }).then((samples: number[]) => {
        ctx!.clearRect(0, 0, width, height);

        const half = height / 2;
        const centerY = half;
        const len = Math.min(samples.length, 512);
        if (len < 2) { rafId = requestAnimationFrame(draw); return; }

        const step = (len - 1) / (width - 1);

        ctx!.beginPath();
        ctx!.moveTo(0, centerY + samples[0] * half);

        for (let x = 1; x < width; x++) {
          const idx = Math.round(x * step);
          const s = Math.max(-1, Math.min(1, samples[idx] || 0));
          ctx!.lineTo(x, centerY + s * half);
        }

        ctx!.strokeStyle = 'rgba(226, 166, 61, 0.7)';
        ctx!.lineWidth = 1.5;
        ctx!.shadowColor = 'rgba(226, 166, 61, 0.1)';
        ctx!.shadowBlur = 4;
        ctx!.stroke();
        ctx!.shadowBlur = 0;
      }).catch(() => {});

      rafId = requestAnimationFrame(draw);
    }
    rafId = requestAnimationFrame(draw);

    return () => { cancelAnimationFrame(rafId); };
  });
</script>

<canvas bind:this={canvas} class="waveform" style="width: {width}px; height: {height}px;"></canvas>

<style>
  .waveform {
    display: block;
    border-radius: 6px;
  }
</style>