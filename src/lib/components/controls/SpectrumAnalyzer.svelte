<script lang="ts">
  import { browser } from '$app/environment';
  import { onMount } from 'svelte';
  import { listen } from '@tauri-apps/api/event';

  let { width = 320, height = 64 }: { width?: number; height?: number } = $props();

  let canvas: HTMLCanvasElement;
  let ctx: CanvasRenderingContext2D | null = null;
  let bands = new Float32Array(16);
  let smooth = new Float32Array(16);
  let rafId = 0;

  // 颜色渐变点：紫 → 品红 → 橙
  const colors = [
    [167, 139, 250],
    [180, 130, 240],
    [200, 120, 220],
    [220, 110, 200],
    [240, 100, 180],
    [244, 114, 182],
    [246, 116, 170],
    [248, 120, 155],
    [250, 130, 140],
    [250, 140, 125],
    [251, 150, 115],
    [251, 155, 105],
    [251, 160, 95],
    [251, 165, 85],
    [251, 172, 78],
    [251, 180, 70],
  ];

  onMount(() => {
    if (!browser) return;
    ctx = canvas.getContext('2d');

    const dpr = window.devicePixelRatio || 1;
    canvas.width = width * dpr;
    canvas.height = height * dpr;
    ctx!.scale(dpr, dpr);

    const unsub = listen<number[]>('player:spectrum', (event) => {
      bands = new Float32Array(event.payload.slice(0, 16));
    });

    function draw() {
      if (!ctx) { rafId = requestAnimationFrame(draw); return; }
      for (let i = 0; i < 16; i++) {
        smooth[i] += (bands[i] - smooth[i]) * 0.22;
      }
      ctx.clearRect(0, 0, width, height);

      const curveH = height * 0.55;
      const baseY = height - 4;

      // 计算顶点
      const segW = width / 15;
      const pts: { x: number; y: number }[] = [];
      for (let i = 0; i < 16; i++) {
        const x = i * segW;
        const val = Math.pow(Math.max(0, smooth[i]), 0.65);
        const y = baseY - val * curveH;
        pts.push({ x, y });
      }

      // 细发光（仅曲线本身）
      ctx.shadowColor = 'rgba(167, 139, 250, 0.2)';
      ctx.shadowBlur = 12;

      // 主曲线
      ctx.beginPath();
      ctx.moveTo(pts[0].x, pts[0].y);
      for (let i = 1; i < 16; i++) {
        const xc = (pts[i - 1].x + pts[i].x) / 2;
        const yc = (pts[i - 1].y + pts[i].y) / 2;
        ctx.quadraticCurveTo(pts[i - 1].x, pts[i - 1].y, xc, yc);
      }
      ctx.lineTo(pts[15].x, pts[15].y);

      ctx.lineWidth = 2;
      const grad = ctx.createLinearGradient(0, 0, width, 0);
      grad.addColorStop(0, '#a78bfa');
      grad.addColorStop(0.4, '#c084fc');
      grad.addColorStop(0.7, '#f472b6');
      grad.addColorStop(1, '#fb923c');
      ctx.strokeStyle = grad;
      ctx.stroke();

      ctx.shadowBlur = 0;

      rafId = requestAnimationFrame(draw);
    }
    rafId = requestAnimationFrame(draw);

    return () => {
      cancelAnimationFrame(rafId);
      unsub.then(f => f());
    };
  });
</script>

<canvas bind:this={canvas} class="spectrum" style="width: {width}px; height: {height}px;"></canvas>

<style>
  .spectrum {
    display: block;
    border-radius: 6px;
  }
</style>
