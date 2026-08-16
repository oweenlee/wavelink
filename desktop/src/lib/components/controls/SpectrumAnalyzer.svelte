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

  // 颜色渐变点：深橙红 → 亮橙 → 暖白（对齐 mobile accent #e8553f）
  const colors = [
    [185, 68, 50],
    [196, 72, 52],
    [207, 76, 54],
    [218, 80, 57],
    [226, 84, 60],
    [232, 85, 63],
    [235, 95, 75],
    [238, 108, 90],
    [240, 122, 105],
    [242, 138, 122],
    [244, 155, 140],
    [245, 172, 158],
    [246, 189, 176],
    [248, 206, 195],
    [250, 223, 214],
    [252, 240, 233],
    [245, 150, 130],
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
      ctx.shadowColor = 'rgba(232, 85, 63, 0.15)';
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
