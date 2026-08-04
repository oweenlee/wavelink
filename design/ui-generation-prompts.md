# WaveLink — App UI 生成提示词包

> 用途：喂给 Figma Make / Figma AI / Galileo / Motiff / 即时设计 AI / Uizard / Midjourney 等工具，生成 WaveLink 移动端（iOS 优先）的 UX/UI 效果图。
> 约定：**不指定任何固定配色**。所有提示词只描述明暗模式、层级关系与"强调色由专辑封面动态提取"这一产品行为，颜色交给工具/后续设计自行发挥。

---

## 0. 使用说明

1. **先贴"全局风格前缀"（§1），再贴具体屏幕提示词（§3）**。两段拼接后一次性发给工具。
2. 提示词正文为英文（多数设计 AI 对英文理解更稳）。每段前的中文是给你看的说明，不要贴进去。
3. 国内工具（Motiff / 即时设计 AI）可直接吃中文，需要中文版时把英文段丢给翻译即可，结构不用动。
4. 生成顺序建议：Now Playing（定调）→ 库 → 详情页 → 弹层（歌词/队列/音效）→ 设置/诊断 → 组件表。
5. 每段提示词里的曲目/数据都是**真实感占位数据**，保留它们能让效果图立刻像真的产品截图。

**屏幕清单（14 项）**

| # | 屏幕 | 优先级 |
|---|------|--------|
| 1 | Now Playing 正在播放（核心屏） | P0 |
| 2 | 全屏歌词 | P0 |
| 3 | 播放队列 sheet | P0 |
| 4 | 曲库 · 歌曲 tab | P0 |
| 5 | 曲库 · 专辑 / 歌手 tab | P1 |
| 6 | 曲库 · 歌单 tab | P1 |
| 7 | 专辑详情 | P1 |
| 8 | 歌手详情 | P1 |
| 9 | 音效 sheet（DSP 开关 + 10 段 EQ） | P0 |
| 10 | 设置 | P1 |
| 11 | 播放诊断 | P2 |
| 12 | 导入音乐（多来源） | P1 |
| 13 | Mini Player + 通用组件表 | P1 |
| 14 | 空状态 / 首次启动 | P2 |

---

## 1. 全局风格前缀（每次必贴）

```
Design a screen for "WaveLink", a premium Hi-Fi music player app for audiophiles (iOS, single-hand phone layout, 393×852pt). The app is built around a professional Rust audio engine: lossless decoding (FLAC/WAV/DSD), bit-perfect sample-rate switching, 10-band parametric EQ, DSP chain, real-time spectrum, and BPM/musical-key analysis.

STYLE DIRECTION
- Mood: serious audio instrument, not a toy. Think high-end DAC control panel meets modern streaming app. Confident, dense-with-purpose, tactile.
- Mode: dark-first UI. Do NOT define a fixed brand palette. Surfaces are neutral (layered grays with clear elevation steps); the accent color is dynamically extracted from the dominant color of the current album artwork — show this behavior in the design (e.g. controls and highlights tinted by the artwork).
- Typography: pair a distinctive display face (for screen titles, track titles, large numerals) with a highly readable sans for body text. ALL technical readouts — sample rate ("96 kHz"), bit depth ("24-bit"), format badges ("FLAC" "DSD256"), BPM, key ("A min"), timecodes, counters — must use a monospace/technical face, small-caps or tabular figures.
- Layout: content-first and asymmetric where possible; avoid centered generic hero stacks and rows of equal cards. Let album artwork be large and physical. Use strong type-size contrast (huge now-playing titles vs tiny technical labels).
- Texture & depth: layered backgrounds — the now-playing screen uses a heavily blurred, darkened version of the album cover as ambient backdrop. Subtle grain or fine scanline texture is welcome on surfaces. Hairline separators only where needed; prefer elevation and spacing.
- Motion (annotate in the design): micro-interactions — play button morph, spectrum bars animating, EQ sliders with haptic-style detents, sheets sliding up with spring, lyric lines highlighting in sync.
- Iconography: thin-line, precise, engineering-style icons.
- No stock clichés: no generic purple gradients, no glassmorphism everywhere, no rounded-2xl-everything. Corners: small radii on controls, larger radius only on artwork and sheets.
```

---

## 2. Master 提示词（整 App 一次生成，适用于 Figma Make / Galileo）

```
[粘贴 §1 全局风格前缀]

Generate a coherent 8-screen mobile app flow for WaveLink:
1. Library → Songs tab: tab bar at bottom (Library / Now Playing / Settings), top has app wordmark + search + import button; a segmented control (Songs / Albums / Artists / Playlists); a list of tracks, each row: index or playing-indicator, title, artist, a small monospace format badge (FLAC 24/96, DSD256, MP3), duration; one row is currently playing with animated equalizer bars and accent tint.
2. Now Playing (the hero screen): full-bleed blurred album-art backdrop, large square artwork with soft shadow, track title in display face, artist below, a row of small technical tags (monospace: "FLAC · 24-bit/96kHz", "147 BPM", "A min"), a live spectrum visualizer strip, progress bar with monospace timecodes, transport controls (shuffle / previous / large play / next / repeat), secondary buttons (queue, lyrics, sound effects, favorite).
3. Lyrics overlay: full-screen synced lyrics, current line large and accented, past/future lines dimmed, blurred backdrop.
4. Queue sheet: bottom sheet listing upcoming tracks with drag handles and "now" marker.
5. Sound sheet: DSP toggle list (Crossfeed, Stereo Widener, True-Peak Limiter, TPDF Dither, ReplayGain, Bit-perfect) + 10-band EQ with vertical sliders and preset chips (Flat, Rock, Pop, Dance, Classical, Soft, Full Bass, Full Treble, Techno, Vocals).
6. Album detail: large header artwork, album meta (artist · year · n songs · total minutes), Play All / Shuffle actions, track list with track numbers.
7. Settings: grouped sections — Audio (DSP pipeline, ReplayGain, Bit-perfect, Output Device), Appearance (Theme, Dynamic Color, Cover Blur intensity slider, Spectrum toggle), Library (Scan Directory, Music Server, NAS), About.
8. Diagnostics: an instrument-panel screen showing underrun counters (Total / Recent 500ms) in large monospace numerals with status colors, plus a hint card.

Keep navigation, type scale, spacing and components consistent across all screens.
```

---

## 3. 分屏提示词

### 3.1 Now Playing 正在播放（核心屏，最先做）

> 这是产品的脸。要点：封面物理感、技术标签（格式/采样率/BPM/调性）、频谱、动态取色。

```
[粘贴 §1] Screen: "Now Playing" — the hero screen of WaveLink.

Layout, top to bottom:
- Top bar: down-chevron (collapse), a tiny monospace readout in the center: "FLAC · 24-bit / 96 kHz · bit-perfect" (this is the live output status), overflow menu icon.
- Ambient backdrop: the album cover, blurred ~60px, darkened, filling the whole screen edge-to-edge; the accent color of the screen is extracted from this artwork.
- Album artwork: large square (≈78% width), centered-upper, deep soft shadow, very slight rounded corners; when paused it dims and scales down to 92% (annotate this).
- Technical tag row under the artwork: small pill tags in monospace face — "147 BPM" with a gauge icon, "A min" with a music icon, "♥ Liked".
- Track title: display face, 28–32pt, bold; artist line below in secondary weight. Left-aligned, not centered, to feel editorial.
- Spectrum visualizer: a slim live spectrum strip (≈28pt tall, 48 bars, mirrored or baseline bars) sitting above the progress bar, tinted by the accent; annotate "animates in real time from the Rust engine FFT".
- Progress: thin slider with a precise thumb; monospace timecodes "02:41 / 06:31" at both ends.
- Transport row: shuffle, previous, PLAY (largest, circular, accent fill, icon morphs play↔pause), next, repeat (badge dot when Repeat-One). Generous tap targets, thumb-reachable.
- Secondary row (smaller, below or beside transport): queue (opens sheet), lyrics, sound-effects (opens EQ/DSP sheet), favorite heart.
States to show: playing (default) + paused (artwork scaled down, spectrum frozen flat).
```

### 3.2 全屏歌词

```
[粘贴 §1] Screen: full-screen synced lyrics overlay for WaveLink, shown above Now Playing.
- Backdrop: current album art, extreme blur + dark scrim.
- Close affordance top-right; a tiny monospace label "LRC · synced" top-left.
- Lyrics as a vertical scrolling column, left-aligned, generous line-height:
  · Current line: display face, largest, full opacity, accented (annotate: highlights in sync with playback).
  · Previous/next lines: body face, 45% / 65% opacity gradient by distance.
- Bottom: a slim progress hairline and monospace timecode.
- Empty state variant: a single quiet line "No lyrics found for this track" with a small icon.
Show one real lyric block (use any neutral poetic placeholder lines, 8–10 lines) so the hierarchy is visible.
```

### 3.3 播放队列 sheet

```
[粘贴 §1] Component: "Play Queue" bottom sheet for WaveLink (slides up over Now Playing, ~85% height, large top radius, grab handle).
- Header: "Play Queue" in display face + monospace count "14 tracks · 58 min" + "Clear" text action; a secondary action "Save as playlist".
- Current track row: pinned, accented, with animated mini equalizer bars and a "NOW" monospace chip.
- Upcoming rows: index number (monospace), title, artist, duration right-aligned in monospace; drag-handle icon on the right for reordering; swipe-left reveals delete (annotate).
- One row shown mid-swipe to demonstrate the delete state.
- Footer hint (tiny): "Queue follows play mode — Normal / Repeat All / Repeat One / Shuffle" with the current mode chip.
```

### 3.4 曲库 · 歌曲 tab

```
[粘贴 §1] Screen: Library → Songs tab for WaveLink.
- Bottom tab bar (3 tabs): Library (active), Now Playing (shows a tiny playing-indicator dot when music is playing), Settings.
- Top: app wordmark "WAVELINK" in display face (small, letter-spaced, engineering feel), search field, and an "Import" button.
- Below: an import banner (only when library is young): compact card "Discover songs — scan system library, pick files, connect a music server or NAS" with a chevron.
- Segmented control: Songs (active) / Albums / Artists / Playlists.
- A "Shuffle Play" pill + monospace count "1,284 songs".
- Track list rows (show 8–10): leading element is track number in monospace — replaced by animated equalizer bars on the playing row; title (medium weight) + artist (secondary); trailing: format badge in tiny monospace ("FLAC 24/96" / "DSD256" / "MP3 320") and duration in monospace.
- The playing row is tinted with the accent extracted from its own artwork.
- Row long-press context (annotate or show one floating menu): Play Next / Add to Queue / Add to Playlist / Favorite / Delete from Library.
```

### 3.5 曲库 · 专辑 / 歌手 tab

```
[粘贴 §1] Two variants of the Library screen for WaveLink, same chrome as the Songs tab:
Variant A — Albums: a 2-column grid of album cards: square artwork (small radius), album title below in medium weight, artist in secondary, a tiny monospace meta line "2011 · 12 songs · 48 min". One card is the currently-playing album with a subtle accent ring and a mini equalizer chip on the artwork.
Variant B — Artists: list layout: circular artist avatar (56pt) left, artist name, monospace meta "23 songs · 3 albums"; a "Shuffle All" pill at top.
Show 6 albums / 6 artists with plausible names; keep the grid airy (16pt gutters).
```

### 3.6 曲库 · 歌单 tab

```
[粘贴 §1] Screen: Library → Playlists tab for WaveLink.
- Top actions: "New Playlist" filled button + "Import / Export (M3U · PLS)" secondary button.
- Playlist rows: leading square is a 2×2 mosaic of member track artworks (or a single icon for empty lists), playlist name in medium weight, monospace meta "18 songs · 1 h 12 min", chevron.
- Include one special pinned row: "Liked Music" with a heart glyph and count.
- Empty state variant: quiet illustration-free typography state — "No playlists yet — create one, or save the current queue as a playlist." with a single action button.
```

### 3.7 专辑详情

```
[粘贴 §1] Screen: Album detail for WaveLink.
- Header: large artwork left (or full-width backdrop with artwork anchored bottom-left), album title in display face (large), artist name, monospace meta line "2008 · 11 songs · 52 min · FLAC 24/96".
- The screen's accent is extracted from the album artwork (annotate).
- Action row: "Play All" (accent fill) + "Shuffle" (outline) + favorite/overflow icons.
- Track list: monospace track numbers, titles, durations in monospace right-aligned; the playing track highlighted with equalizer bars.
- Sticky header behavior annotated: artwork shrinks into the top bar on scroll.
```

### 3.8 歌手详情

```
[粘贴 §1] Screen: Artist detail for WaveLink.
- Header: circular artist avatar on a blurred tint backdrop, artist name in display face, monospace meta "46 songs · 5 albums".
- Actions: Play All / Shuffle.
- Sections: "Albums" horizontal scroll of album cards, then "Songs" vertical list (same row anatomy as Library rows).
```

### 3.9 音效 sheet（DSP + 10 段 EQ）— 专业感的关键屏

```
[粘贴 §1] Screen: "Sound" bottom sheet for WaveLink — the pro-audio differentiator. ~92% height sheet over Now Playing.
- Header: "Sound" in display face + a master bypass switch "DSP Pipeline" (turning it off greys out everything below — annotate).
- Section 1 — EQUALIZER: 10 vertical sliders (31, 62, 125, 250, 500, 1k, 2k, 4k, 8k, 16k Hz labels in tiny monospace), each slider shows its dB value in monospace above the thumb ("+3.0"), a smooth curve line connecting the band points behind the sliders (annotate: redraws live). Above: horizontally scrollable preset chips — Flat (active), Rock, Pop, Dance, Classical, Soft, Full Bass, Full Treble, Techno, Vocals.
- Section 2 — EFFECTS: a list of toggle rows, each with icon + name + one-line description in secondary text + switch:
  · Bauer Crossfeed — "Natural headphone speaker placement"
  · Stereo Widening — "Widen the soundstage"
  · True-Peak Limiter — "Prevent clipping on loud passages"
  · TPDF Dither — "Clean 16-bit downsampling"
  · ReplayGain — "Normalize perceived loudness across tracks"
  · Bit-perfect — "Output follows source sample rate, no resampling" (show a tiny monospace status under it: "Now: 96 kHz → 96 kHz · direct")
- All switches in the accent color; the whole sheet feels like a mixing console, tight spacing, monospace numbers everywhere.
```

### 3.10 设置

```
[粘贴 §1] Screen: Settings for WaveLink. Grouped inset sections, small-caps section headers:
- AUDIO: "DSP Pipeline" (chevron → opens Sound sheet), "ReplayGain" switch, "Bit-perfect (sample-rate follow)" switch with monospace sub-status, "Output Device" with current device name.
- APPEARANCE: "Theme" (Dark / System), "Dynamic Color" switch (sub: "Accent from album art"), "Cover Blur Intensity" slider with live mini-preview, "Spectrum Visualizer" switch.
- LIBRARY: "Scan Directory", "Music Server (Navidrome / Jellyfin / Emby)" with connection status dot, "NAS (SMB)" with status, "Import / Export Playlists".
- ABOUT: version "v0.1.0" monospace, "Language" (System Default / 中文 / English / 日本語), "Open Source Licenses", "Playback Diagnostics" (chevron).
Rows use leading thin-line icons; switches and chevrons right-aligned.
```

### 3.11 播放诊断（仪器面板感）

```
[粘贴 §1] Screen: "Playback Diagnostics" for WaveLink — style it like an instrument readout panel.
- Two large counter cards side by side: "TOTAL UNDERRUNS" huge monospace numeral (e.g. 3), "RECENT (500ms)" huge monospace numeral (e.g. 0) with a healthy-status tint; annotate: recent counter flashes when it increments.
- A small live status line in monospace: "engine: running · output: 96 kHz · buffer: ok".
- Hint card: "If underruns keep increasing, close background apps or switch the output device."
- This screen should feel like opening the hood of the engine — technical, honest, minimal.
```

### 3.12 导入音乐（多来源）

```
[粘贴 §1] Screen: "Import Music" for WaveLink — a source-picker sheet or page listing four source cards (vertical list, NOT equal marketing cards — each row: icon, title, one-line description, status/chevron):
1. Discover Songs — "Auto-detect songs from the system music library and local files" (primary, accent).
2. Pick Files — "Choose audio files from device storage (FLAC, WAV, DSD, APE, CUE…)".
3. Music Server — "Connect Navidrome / Jellyfin / Emby" with a connection-status chip (Not connected).
4. NAS (SMB) — "Browse and import from a network share" with status chip.
Below the list: a monospace footnote of supported formats: "FLAC · WAV · AIFF · MP3 · AAC · OGG · OPUS · WAVPACK · DSF/DFF (DSD) · CUE · M3U/PLS".
Secondary variant: the NAS settings form (Host / Share / Username / Password fields + "Test Connection" outline button + "Connect" fill button) — show it as a follow-up screen.
```

### 3.13 Mini Player + 通用组件表

```
[粘贴 §1] Deliverable: a component sheet for WaveLink containing, each labeled:
- Mini player bar (docked above the tab bar): 44pt artwork thumbnail, title + artist, play/pause + next buttons, a hairline progress on the top edge, backdrop tinted by the artwork's dominant color; tapping opens Now Playing.
- Track row anatomy (default / playing / long-press menu).
- Format badges set: "FLAC 24/96" "DSD256" "WAV 16/44.1" "MP3 320" in tiny monospace pills.
- Buttons: primary fill, outline, icon button (44pt), transport play button (64pt, morphing).
- Switches, sliders (progress + EQ vertical + blur-intensity), segmented control, chips (EQ presets), tags (BPM / key).
- Bottom sheet shell with grab handle; empty-state typography pattern.
- Type scale table: display 32 / title 22 / body 16 / caption 12 / mono-technical 11.
```

### 3.14 空状态 / 首次启动

```
[粘贴 §1] Screen: first-launch empty Library for WaveLink. No generic illustration — use typography and a single strong action:
- Segmented control visible (Songs/Albums/Artists/Playlists), content area empty.
- Center: display-face line "Your library is empty", secondary line "WaveLink plays local files, DSD, and lossless streams from your own server — nothing is uploaded anywhere." (this honesty is the brand).
- One accent button "Import Music" + a quiet secondary link "Connect a music server".
- Tiny monospace footnote: "Supports FLAC · WAV · DSD (DSF/DFF) · CUE sheets".
```

---

## 4. 设计系统提示词（单独生成规范页）

```
[粘贴 §1] Deliverable: a one-page design system spec for WaveLink:
- Neutral surface ramp: 5 elevation steps (name them S0–S4), dark-first; note that accent is runtime-extracted from album art (show 2 example accents side by side applied to the same components).
- Type scale with the three faces (display / body / mono-technical) and usage rules — mono is mandatory for: sample rates, bit depths, formats, BPM, keys, timecodes, counters.
- 8pt spacing grid; corner-radius rules (controls 6–8pt, artwork 10–12pt, sheets 20pt top).
- Component inventory with states: track row, buttons, switches, sliders (horizontal/vertical), chips, tags, badges, tab bar, mini player, sheet shell, toggles list row.
- Icon set sample: 16 thin-line audio icons (play, pause, next, previous, shuffle, repeat, repeat-one, queue, lyrics, EQ slider, waveform, heart, import, server, NAS, gauge).
- Motion spec: spring sheet transitions, play-button morph, spectrum/lyrics sync, EQ slider detents.
```

---

## 5. 各工具适配要点

| 工具 | 用法 | 备注 |
|------|------|------|
| **Figma Make / Figma AI** | §1 + §2 Master 一次生成多屏，再用 §3 单屏迭代 | 支持交互原型；生成后让它"keep components consistent"二次收敛 |
| **Galileo AI** | §1 + §3 单屏逐张生成 | 对长 prompt 截断敏感，单屏提示词控制在 ~150 词内可裁剪描述细节 |
| **Motiff / 即时设计 AI** | 可直接中文；把 §3 英文段翻译后使用 | 中文语义理解好，适合批量出图 |
| **Uizard** | 用 §2 Master + 截图参考 | Autodesigner 模式适合快速低保真 |
| **Midjourney（情绪板/主视觉）** | 见下方示例 | 只出视觉氛围图，不出可用 UI；用来定调后喂给 Figma |

**Midjourney 示例（Now Playing 主视觉定调）：**

```
premium hi-fi music player app, now playing screen, dark UI, large square album artwork with deep shadow, heavily blurred album art as ambient backdrop, live audio spectrum bars, monospace technical readouts "24-bit / 96 kHz" "147 BPM", precise thin-line icons, engineering instrument aesthetic, editorial left-aligned typography, strong type contrast, subtle film grain, single accent color extracted from the artwork, ultra clean, dribbble shot, 9:19 --v 6
```

---

## 6. 验收清单（生成后对照检查）

- [ ] 技术读数（采样率/位深/格式/BPM/调性/时间码）全部是等宽字体且数值合理？
- [ ] Now Playing 的强调色看起来像"从封面里提取的"，而不是固定品牌色？
- [ ] 播放中的行/卡片有动效标识（均衡器条/呼吸点），静态截图也能读出"这是活的"？
- [ ] 音效屏像一个调音台：dB 数值、频段刻度、曲线连线的感觉对吗？
- [ ] 没有通用 AI 味：无紫色渐变、无满屏毛玻璃、无居中三件套、无等宽四卡片？
- [ ] 空状态/诊断页体现了"诚实的技术感"（文案直白、数字说话）？
- [ ] 拇指热区：播放键、进度条、tab bar 都在下半屏？
