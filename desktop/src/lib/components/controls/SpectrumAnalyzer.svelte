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

  // 颜色渐变点：深琥珀 → 亮金 → 暖白
  const colors = [
    [180, 120, 30],
    [195, 135, 35],
    [210, 150, 40],
    [220, 160, 50],
    [226, 166, 61],
    [230, 175, 75],
    [235, 185, 90],
    [238, 195, 105],
    [240, 205, 120],
    [242, 212, 135],
    [244, 220, 150],
    [245, 226, 165],
    [246, 232, 180],
    [248, 238, 195],
    [250, 244, 210],
    [252, 248, 225],
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
      ctx.shadowColor = 'rgba(226, 166, 61, 0.15)';
      ctx.shadowBlur = 10;

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
      grad.addColorStop(0, '#b5492f');
      grad.addColorStop(0.4, '#e8553f');
      grad.addColorStop(0.7, '#f57a6b');
      grad.addColorStop(1, '#fbd0c8');
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
