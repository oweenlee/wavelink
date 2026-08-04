<script lang="ts">
  let { rms = 0, peak = 0, clip = false }: { rms?: number; peak?: number; clip?: boolean } = $props();

  let segments = $derived.by(() => {
    const count = 12;
    const threshold = peak;
    return Array.from({ length: count }, (_, i) => {
      const level = (i + 1) / count;
      const active = threshold >= level;
      let cls = 'seg';
      if (active) {
        cls += i >= count - 2 ? ' seg-clip' : i >= count - 4 ? ' seg-warn' : ' seg-ok';
      }
      return { active, cls };
    });
  });
</script>

<div class="meter" class:clip>
  {#each segments as seg}
    <div class={seg.cls}></div>
  {/each}
</div>

<style>
  .meter {
    display: flex; align-items: flex-end; gap: 2px; height: 18px;
    opacity: 0.6; transition: opacity 0.15s;
  }
  .meter.clip { opacity: 1; }
  .seg {
    width: 3px; border-radius: 1px;
    background: rgba(255,255,255,0.08);
    transition: background 0.08s, transform 0.08s;
  }
  .seg.active { background: var(--accent); }
  .seg-ok.active { background: #4ade80; }
  .seg-warn.active { background: #facc15; }
  .seg-clip.active { background: #ef4444; }
</style>
