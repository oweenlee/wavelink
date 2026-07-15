<script lang="ts">
  import { browser } from '$app/environment';
  import { onMount } from 'svelte';
  import { listen } from '@tauri-apps/api/event';

  let canvas: HTMLCanvasElement;
  let ctx: CanvasRenderingContext2D | null = null;
  let bands = new Float32Array(16);
  let smooth = new Float32Array(16);
  let rafId = 0;

  onMount(() => {
    if (!browser) return;
    ctx = canvas.getContext('2d');

    const dpr = window.devicePixelRatio || 1;
    const w = 320, h = 64;
    canvas.width = w * dpr;
    canvas.height = h * dpr;
    ctx!.scale(dpr, dpr);

    const unsub = listen<number[]>('player:spectrum', (event) => {
      bands = new Float32Array(event.payload.slice(0, 16));
    });

    function draw() {
      if (!ctx) { rafId = requestAnimationFrame(draw); return; }
      for (let i = 0; i < 16; i++) {
        smooth[i] += (bands[i] - smooth[i]) * 0.3;
      }
      ctx.clearRect(0, 0, w, h);
      const gap = 2;
      const barW = w / 16;
      for (let i = 0; i < 16; i++) {
        const bh = Math.max(0, smooth[i] * h);
        if (bh < 1) continue;
        const x = i * barW + gap / 2;
        const alpha = 0.2 + smooth[i] * 0.55;
        ctx.fillStyle = `rgba(167, 139, 250, ${alpha})`;
        ctx.beginPath();
        ctx.roundRect(x, h - bh, barW - gap, bh, [2, 2, 0, 0]);
        ctx.fill();
      }
      rafId = requestAnimationFrame(draw);
    }
    rafId = requestAnimationFrame(draw);

    return () => {
      cancelAnimationFrame(rafId);
      unsub.then(f => f());
    };
  });
</script>

<canvas bind:this={canvas} class="spectrum" role="img" aria-label="频谱分析器"></canvas>

<style>
  .spectrum {
    width: 320px;
    height: 64px;
    display: block;
    border-radius: 6px;
  }
</style>
