<script lang="ts">
  import { onMount } from 'svelte';

  let { done = () => {} } = $props();
  let visible = $state(true);
  let canvasEl = $state<HTMLCanvasElement>();
  let clicked = $state(false);

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
    const ACCENT = '#a78bfa';
    const FG = '#eeeeee';
    const MUTED = '#999999';

    // particles
    const pCount = 24;
    const particles = Array.from({ length: pCount }, () => ({
      x: Math.random() * 2000,
      y: Math.random() * 2000,
      vx: (Math.random() - 0.5) * 0.2,
      vy: -0.15 - Math.random() * 0.15,
      baseAlpha: 0.15 + Math.random() * 0.2,
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
    let logoAlpha = 0;
    let logoScale = 0.6;
    let dGlowAlpha = 0;
    let titleAlpha = 0;
    let titleY = 0;
    let subtitleAlpha = 0;
    let skipAlpha = 0;
    let stageAlpha = 1;
    let breatheT = 0;
    let waveAlpha = 0;

    const startTime = performance.now();
    const DURATION = 3.8;
    const FADE_DURATION = 0.8;

    const skip = () => {
      if (clicked) return;
      clicked = true;
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
      const glow = ctx.createRadialGradient(W() / 2, H() / 2, 0, W() / 2, H() / 2, 200);
      glow.addColorStop(0, 'rgba(167,139,250,0.06)');
      glow.addColorStop(1, 'rgba(167,139,250,0)');
      ctx.fillStyle = glow;
      ctx.fillRect(0, 0, W(), H());

      // ---- breathing glow center ----
      if (t > 1.5 && t < DURATION - FADE_DURATION) {
        const bg = ctx.createRadialGradient(W() / 2, H() / 2, 0, W() / 2, H() / 2, 200);
        const ba = 0.06 + Math.sin(t * 1.5) * 0.03;
        bg.addColorStop(0, `rgba(167,139,250,${ba})`);
        bg.addColorStop(1, 'rgba(167,139,250,0)');
        ctx.fillStyle = bg;
        ctx.fillRect(0, 0, W(), H());
      }

      // ---- waveform bars ----
      if (t < 1.5) {
        const prog = Math.min(t / 1.2, 1);
        const easeProg = 1 - Math.pow(1 - prog, 2);
        waveAlpha = Math.min(prog * 2, 0.7);

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
          ctx.fillStyle = `rgba(167,139,250,${Math.min(a * waveAlpha, 0.8)})`;
          ctx.fillRect(sx + i * (barW + barGap), barCenterY() - bd.cur, barW, bd.cur * 2);
        });
      } else {
        const sx = barStartX();
        barData.forEach((bd, i) => {
          const wave = Math.sin(t * 2.5 - i * 0.45) * 0.08;
          bd.target = bd.target * (1 + wave);
          bd.cur += (bd.target - bd.cur) * 0.06;
          ctx.fillStyle = `rgba(167,139,250,0.55)`;
          ctx.fillRect(sx + i * (barW + barGap), barCenterY() - bd.cur, barW, bd.cur * 2);
        });
      }

      // ---- diamond logo ----
      if (t > 0.6 && t < 2.0) {
        const p = Math.min((t - 0.6) / 1.0, 1);
        const ep = 1 - Math.pow(1 - p, 3);
        logoAlpha = ep;
        dGlowAlpha = ep * 0.3;
        logoScale = 0.6 + ep * 0.4;
      }

      const cx = W() / 2;
      const cy = H() / 2 - 55;
      const s = 22 * logoScale;

      // diamond glow
      if (dGlowAlpha > 0.01 || (t > 1.5 && t < DURATION - FADE_DURATION)) {
        const dg = ctx.createRadialGradient(cx, cy, 0, cx, cy, 50 * logoScale);
        const da = t > 1.5 && t < DURATION - FADE_DURATION
          ? (0.25 + Math.sin(t * 1.5) * 0.1) * logoAlpha
          : dGlowAlpha;
        dg.addColorStop(0, `rgba(167,139,250,${da})`);
        dg.addColorStop(1, 'rgba(167,139,250,0)');
        ctx.fillStyle = dg;
        ctx.beginPath();
        ctx.arc(cx, cy, 50 * logoScale, 0, Math.PI * 2);
        ctx.fill();
      }

      // diamond shape
      if (logoAlpha > 0.01) {
        ctx.globalAlpha = logoAlpha;
        ctx.fillStyle = ACCENT;
        ctx.beginPath();
        ctx.moveTo(cx, cy - s);
        ctx.lineTo(cx + s, cy);
        ctx.lineTo(cx, cy + s);
        ctx.lineTo(cx - s, cy);
        ctx.closePath();
        ctx.fill();
        ctx.globalAlpha = 1;
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
        ctx.fillText('高音质音乐播放器', W() / 2, H() / 2 + 78);
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
        ctx.fillText('点击跳过', W() / 2, H() - 40);
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

      // ---- fade out ----
      if (t > DURATION - FADE_DURATION && !clicked) {
        const fp = Math.min((t - (DURATION - FADE_DURATION)) / FADE_DURATION, 1);
        stageAlpha = 1 - fp;
      }
      if (stageAlpha < 1) {
        ctx.globalAlpha = stageAlpha;
        // redraw everything with reduced alpha - simpler approach:
        // just overlay a fade-to-black
      }
      ctx.globalAlpha = 1;

      // overlay fade to black
      if (t > DURATION - FADE_DURATION && !clicked) {
        const fp = Math.min((t - (DURATION - FADE_DURATION)) / FADE_DURATION, 1);
        ctx.fillStyle = `rgba(10,10,14,${fp})`;
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
  <canvas bind:this={canvasEl} class="splash-overlay"></canvas>
{/if}

<style>
  .splash-overlay {
    position: fixed;
    top: 0;
    left: 0;
    width: 100vw;
    height: 100vh;
    z-index: 99999;
    background: #0a0a0e;
  }
</style>
