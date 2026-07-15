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
    [167, 139, 250],  // #a78bfa 紫
    [167, 139, 250],  // #a78bfa
    [180, 130, 240],  // 过渡
    [200, 120, 220],  // 过渡
    [220, 110, 200],  // 过渡
    [240, 100, 180],  // 过渡
    [244, 114, 182],  // #f472b6 品红
    [245, 115, 170],  // 过渡
    [248, 120, 155],  // 过渡
    [250, 130, 140],  // 过渡
    [251, 140, 130],  // 过渡
    [251, 150, 115],  // 过渡
    [251, 155, 105],  // 过渡
    [251, 160, 95],   // 过渡
    [251, 170, 80],   // 过渡
    [251, 180, 70],   // #fbbf24 橙金
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
      // 慢速缓动，更优雅
      for (let i = 0; i < 16; i++) {
        smooth[i] += (bands[i] - smooth[i]) * 0.12;
      }
      ctx.clearRect(0, 0, width, height);

      const barCount = 16;
      const gap = width / 80;
      const barW = (width - gap * (barCount - 1)) / barCount;
      const maxH = height;

      // 底部微弱轨道
      ctx.globalAlpha = 0.06;
      ctx.fillStyle = '#a78bfa';
      for (let i = 0; i < barCount; i++) {
        const x = i * (barW + gap);
        const bh = Math.max(1, smooth[i] * maxH);
        ctx.beginPath();
        ctx.roundRect(x, maxH - 2, barW, 2, 1);
        ctx.fill();
      }
      ctx.globalAlpha = 1;

      // 主柱
      for (let i = 0; i < barCount; i++) {
        const bh = Math.max(0, smooth[i] * maxH);
        if (bh < 1) continue;
        const x = i * (barW + gap);
        const [r, g, b] = colors[Math.min(i, colors.length - 1)];
        const alpha = 0.35 + smooth[i] * 0.45;

        // 发光层（模糊阴影）
        ctx.shadowColor = `rgba(${r}, ${g}, ${b}, ${alpha * 0.4})`;
        ctx.shadowBlur = 8;
        ctx.fillStyle = `rgba(${r}, ${g}, ${b}, ${alpha})`;
        ctx.beginPath();
        // 顶部圆角 + 底部直角
        const rad = Math.min(barW / 2, 4);
        ctx.roundRect(x, maxH - bh, barW, bh - rad, [rad, rad, 0, 0]);
        ctx.fill();

        // 顶部高光：细亮线
        ctx.shadowBlur = 0;
        ctx.globalAlpha = 0.5;
        ctx.fillStyle = `rgba(255, 255, 255, ${0.15 + smooth[i] * 0.3})`;
        ctx.beginPath();
        ctx.roundRect(x + 1, maxH - bh, barW - 2, 2, [1, 1, 0, 0]);
        ctx.fill();
        ctx.globalAlpha = 1;
      }
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

<canvas bind:this={canvas} class="spectrum" style="width: {width}px; height: {height}px;" role="img" aria-label="频谱分析器"></canvas>

<style>
  .spectrum {
    display: block;
    border-radius: 6px;
  }
</style>
