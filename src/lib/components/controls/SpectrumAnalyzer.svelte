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
      // 中等缓动，配合后端自动归一化
      for (let i = 0; i < 16; i++) {
        smooth[i] += (bands[i] - smooth[i]) * 0.18;
      }
      ctx.clearRect(0, 0, width, height);

      const barCount = 16;
      const maxH = height;

      // 计算曲线顶点（power curve 提升低能量段的可见度）
      const pts: { x: number; y: number }[] = [];
      const segW = width / (barCount - 1);
      for (let i = 0; i < barCount; i++) {
        const x = i * segW;
        const val = Math.max(0, Math.pow(smooth[i], 0.7));
        const bh = Math.max(8, val * maxH);
        pts.push({ x, y: maxH - bh });
      }

      // 发光层（模糊曲线 + 填充）
      const grad = ctx.createLinearGradient(0, 0, 0, maxH);
      grad.addColorStop(0, 'rgba(167, 139, 250, 0.25)');
      grad.addColorStop(0.5, 'rgba(244, 114, 182, 0.10)');
      grad.addColorStop(1, 'rgba(167, 139, 250, 0)');

      ctx.shadowColor = 'rgba(167, 139, 250, 0.3)';
      ctx.shadowBlur = 16;
      ctx.beginPath();
      ctx.moveTo(pts[0].x, maxH);
      ctx.lineTo(pts[0].x, pts[0].y);
      for (let i = 1; i < barCount; i++) {
        const xc = (pts[i - 1].x + pts[i].x) / 2;
        const yc = (pts[i - 1].y + pts[i].y) / 2;
        ctx.quadraticCurveTo(pts[i - 1].x, pts[i - 1].y, xc, yc);
      }
      ctx.lineTo(pts[barCount - 1].x, maxH);
      ctx.closePath();
      ctx.fillStyle = grad;
      ctx.fill();
      ctx.shadowBlur = 0;

      // 主曲线（亮线）
      ctx.beginPath();
      ctx.moveTo(pts[0].x, pts[0].y);
      for (let i = 1; i < barCount; i++) {
        const xc = (pts[i - 1].x + pts[i].x) / 2;
        const yc = (pts[i - 1].y + pts[i].y) / 2;
        ctx.quadraticCurveTo(pts[i - 1].x, pts[i - 1].y, xc, yc);
      }
      ctx.lineTo(pts[barCount - 1].x, pts[barCount - 1].y);

      const lineGrad = ctx.createLinearGradient(0, 0, width, 0);
      lineGrad.addColorStop(0, '#a78bfa');
      lineGrad.addColorStop(0.5, '#f472b6');
      lineGrad.addColorStop(1, '#fbbf24');
      ctx.strokeStyle = lineGrad;
      ctx.lineWidth = 2.5;
      ctx.stroke();

      // 顶点光点
      for (const p of pts) {
        const [r, g, b] = colors[Math.min(Math.round((p.y / maxH) * 15), 15)];
        ctx.beginPath();
        ctx.arc(p.x, p.y, 3, 0, Math.PI * 2);
        ctx.fillStyle = `rgba(${r}, ${g}, ${b}, 0.8)`;
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

<canvas bind:this={canvas} class="spectrum" style="width: {width}px; height: {height}px;" role="img" aria-label="频谱分析器"></canvas>

<style>
  .spectrum {
    display: block;
    border-radius: 6px;
  }
</style>
