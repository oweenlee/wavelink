<script lang="ts">
  import { onMount } from 'svelte';
  import { t as tr } from '$lib/i18n/i18n.svelte';

  let { done = () => {} } = $props();
  let visible = $state(true);
  let canvasEl = $state<HTMLCanvasElement>();
  let clicked = $state(false);

  const ACCENT = '#e8553f';
  const FG = '#f0f1f3';
  const MUTED = '#9a9fa6';
  const BG = '#0e1011';

  onMount(() => {
    const canvas = canvasEl!;
    const ctx = canvas.getContext('2d')!;

    const resize = () => {
      const dpr = Math.min(devicePixelRatio || 1, 2);
      const w = canvas.clientWidth || innerWidth;
      const h = canvas.clientHeight || innerHeight;
      canvas.width = w * dpr;
      canvas.height = h * dpr;
      ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    };
    resize();
    const ro = new ResizeObserver(() => resize());
    ro.observe(canvas);

    const W = () => canvas.clientWidth || innerWidth;
    const H = () => canvas.clientHeight || innerHeight;

    // particles
    const pCount = 20;
    const particles = Array.from({ length: pCount }, () => ({
      x: Math.random() * 2000,
      y: Math.random() * 2000,
      vx: (Math.random() - 0.5) * 0.2,
      vy: -0.15 - Math.random() * 0.15,
      baseAlpha: 0.1 + Math.random() * 0.15,
    }));

    // waveform bars
    const BAR_COUNT = 25;
    const barW = 3;
    const barGap = 5;
    const barData = Array.from({ length: BAR_COUNT }, (_, i) => ({
      target: 0,
      cur: 0,
      phase: (i / BAR_COUNT) * Math.PI,
    }));
    const barCenterY = () => H() / 2 + 15;
    const barTotalW = BAR_COUNT * (barW + barGap);
    const barStartX = () => (W() - barTotalW) / 2;

    // ---- tracking state for animations ----
    let titleAlpha = 0;
    let titleY = 0;
    let subtitleAlpha = 0;
    let skipAlpha = 0;
    let waveAlpha = 0;

    const startTime = performance.now();
    const DURATION = 1.5;
    const FADE_DURATION = 0.5;

    // 安全兜底：超时后无论动画是否正常都跳过
    const fallbackTimer = setTimeout(() => {
      if (!clicked) {
        clicked = true;
        cancelAnimationFrame(raf);
        ro.disconnect();
        done();
        visible = false;
      }
    }, (DURATION + FADE_DURATION + 0.3) * 1000);

    const skip = () => {
      if (clicked) return;
      clicked = true;
      clearTimeout(fallbackTimer);
      cancelAnimationFrame(raf);
      ro.disconnect();
      done();
      visible = false;
    };

    canvas.onclick = skip;
    canvas.style.cursor = 'pointer';

    let raf: number;

    const frame = () => {
      if (clicked) return;
      const t = (performance.now() - startTime) / 1000;

      // ---- resize check ----
      const dpr = Math.min(devicePixelRatio || 1, 2);
      const targetW = (canvas.clientWidth || innerWidth) * dpr;
      if (canvas.width !== targetW) {
        resize();
      }

      ctx.clearRect(0, 0, W(), H());

      // ---- background glow ----
      const glow = ctx.createRadialGradient(W() / 2, H() / 2, 0, W() / 2, H() / 2, 220);
      glow.addColorStop(0, 'rgba(232,85,63,0.05)');
      glow.addColorStop(1, 'rgba(232,85,63,0)');
      ctx.fillStyle = glow;
      ctx.fillRect(0, 0, W(), H());

      // ---- waveform bars ----
      if (t < 1.5) {
        const prog = Math.min(t / 1.2, 1);
        const easeProg = 1 - Math.pow(1 - prog, 2);
        waveAlpha = Math.min(prog * 2, 0.6);

        const maxH = 60 + 20 * Math.sin(t * 0.5);
        const sx = barStartX();
        barData.forEach((bd, i) => {
          const center = i / (BAR_COUNT - 1);
          const envelope = Math.sin(center * Math.PI);
          const wave = Math.sin(t * 5 - i * 0.45) * 0.12;
          bd.target = maxH * envelope * (0.82 + wave);
          if (prog > 0.1) {
            bd.cur += (bd.target * easeProg - bd.cur) * 0.12;
          }
          const a = 0.3 + 0.5 * (bd.cur / maxH);
          ctx.fillStyle = `rgba(232,85,63,${Math.min(a * waveAlpha, 0.7)})`;
          ctx.fillRect(sx + i * (barW + barGap), barCenterY() - bd.cur, barW, bd.cur * 2);
        });
      } else {
        const sx = barStartX();
        barData.forEach((bd, i) => {
          const wave = Math.sin(t * 2.5 - i * 0.45) * 0.08;
          bd.target = bd.target * (1 + wave);
          bd.cur += (bd.target - bd.cur) * 0.06;
          ctx.fillStyle = 'rgba(232,85,63,0.45)';
          ctx.fillRect(sx + i * (barW + barGap), barCenterY() - bd.cur, barW, bd.cur * 2);
        });
      }

      // ---- title ----
      if (t > 1.0 && t < 2.2) {
        titleAlpha = Math.min((t - 1.0) / 0.7, 1);
        titleY = H() / 2 + 40 - (1 - titleAlpha) * 8;
      } else if (t >= 2.2) {
        titleAlpha = 1;
        titleY = H() / 2 + 40;
      }
      if (titleAlpha > 0.01) {
        ctx.globalAlpha = titleAlpha;
        ctx.font = '600 38px -apple-system, "SF Pro Display", "PingFang SC", sans-serif';
        ctx.fillStyle = FG;
        ctx.textAlign = 'center';
        ctx.letterSpacing = '8px';
        ctx.fillText('WaveLink', W() / 2, titleY);
        ctx.globalAlpha = 1;
      }

      // ---- subtitle ----
      if (t > 1.4 && t < 2.2) {
        subtitleAlpha = Math.min((t - 1.4) / 0.6, 1);
      } else if (t >= 2.2) {
        subtitleAlpha = 1;
      }
      if (subtitleAlpha > 0.01) {
        ctx.globalAlpha = subtitleAlpha;
        ctx.font = '400 13px -apple-system, "SF Pro Text", "PingFang SC", sans-serif';
        ctx.fillStyle = MUTED;
        ctx.textAlign = 'center';
        ctx.fillText(tr('splash.subtitle'), W() / 2, H() / 2 + 78);
        ctx.globalAlpha = 1;
      }

      // ---- skip hint ----
      if (t > 1.5) {
        skipAlpha = Math.min((t - 1.5) / 0.8, 0.5);
      }
      if (skipAlpha > 0.01) {
        ctx.globalAlpha = skipAlpha;
        ctx.font = '400 11px -apple-system, "SF Pro Text", "PingFang SC", sans-serif';
        ctx.fillStyle = '#555';
        ctx.textAlign = 'center';
        ctx.fillText(tr('splash.skip'), W() / 2, H() - 40);
        ctx.globalAlpha = 1;
      }

      // ---- particles ----
      particles.forEach((p) => {
        p.x += p.vx;
        p.y += p.vy;
        if (p.y < -20) { p.y = H() + 20; p.x = Math.random() * W(); }
        if (p.x < -20) p.x = W() + 20;
        if (p.x > W() + 20) p.x = -20;
        if (t > 0.5) {
          const r = 1 + Math.random() * 1.5;
          ctx.globalAlpha = p.baseAlpha;
          ctx.fillStyle = ACCENT;
          ctx.beginPath();
          ctx.arc(p.x, p.y, r, 0, Math.PI * 2);
          ctx.fill();
          ctx.globalAlpha = 1;
        }
      });

      // ---- fade out overlay ----
      if (t > DURATION - FADE_DURATION && !clicked) {
        const fp = Math.min((t - (DURATION - FADE_DURATION)) / FADE_DURATION, 1);
        ctx.fillStyle = `rgba(14,16,17,${fp})`;
        ctx.fillRect(0, 0, W(), H());
      }

      // ---- end ----
      if (t > DURATION && !clicked) {
        clicked = true;
        ro.disconnect();
        done();
        visible = false;
        return;
      }

      raf = requestAnimationFrame(frame);
    };

    raf = requestAnimationFrame(frame);

    return () => {
      cancelAnimationFrame(raf);
      ro.disconnect();
    };
  });
</script>

{#if visible}
  <div class="splash-overlay">
    <canvas bind:this={canvasEl} class="splash-canvas"></canvas>
    <img class="splash-logo" src="/wavelink-logo.png" alt="" width="128" height="128" />
  </div>
{/if}

<style>
  .splash-overlay {
    position: fixed;
    top: 0;
    left: 0;
    width: 100vw;
    height: 100vh;
    z-index: 99999;
    background: #0e1011;
  }

  .splash-canvas {
    position: absolute;
    inset: 0;
    width: 100%;
    height: 100%;
    cursor: pointer;
  }

  .splash-logo {
    position: absolute;
    top: 38%;
    left: 50%;
    transform: translate(-50%, -50%);
    width: 128px;
    height: 128px;
    pointer-events: none;
    animation: logo-in 0.8s cubic-bezier(0.22, 1, 0.36, 1) both;
  }

  @keyframes logo-in {
    from { opacity: 0; transform: translate(-50%, -50%) scale(0.8); }
    to { opacity: 1; transform: translate(-50%, -50%) scale(1); }
  }
</style>