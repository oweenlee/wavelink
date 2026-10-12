#!/usr/bin/env python3
"""生成 App Store 截图用的「零版权」演示素材包。

背景：2026-10-09 / 10-12 两次被 Apple 以 Guideline 5.2.1 拒审
（"protected album cover artworks in app icons, screenshots or previews"）。
根因是 App Store 截图里出现了真实专辑封面与真实歌词。

本脚本产出可安全用于截图的替代素材：
  1) 8 张**程序化生成**的原创专辑封面（纯几何/渐变/噪点，无文字、无人物、无 logo）
  2) 8 首合成的环境音演示曲目（FLAC，内嵌上面对应封面）
     —— 元数据全部为虚构名称，且**不含任何歌词**（不写 lyrics 标签、不含 .lrc）

所有内容由代码生成，不含任何第三方素材，可长期复用。

用法：
    python3 tools/gen_asc_demo_assets.py                 # 输出到 ~/Desktop/WaveLink-Demo-Pack
    python3 tools/gen_asc_demo_assets.py --out /path/to  # 自定义输出目录
    python3 tools/gen_asc_demo_assets.py --covers-only   # 只生成封面

依赖：pillow、numpy（隔离环境 ~/.workbuddy/binaries/python/envs/default）+ ffmpeg
"""

from __future__ import annotations

import argparse
import json
import math
import os
import shutil
import subprocess
import sys
import tempfile
import wave
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

SIZE = 1024  # 封面边长

# ---------------------------------------------------------------- 演示曲目清单
# 全部为虚构的艺人 / 专辑 / 曲名，避免与任何真实作品重名。
# hi_res=True 的曲目输出 96 kHz / 24-bit，用于在截图里体现 hi-res 播放能力。
TRACKS = [
    dict(n=1, title="Driftwood",        artist="Lumen Bay",    album="Neon Shoreline",
         palette=("#0B2E33", "#E8D9C0"), motif="horizon",  seconds=20, hi_res=True),
    dict(n=2, title="Apogee",           artist="Halden",       album="Low Orbit",
         palette=("#0B1D3A", "#F2762E"), motif="orb",      seconds=20, hi_res=True),
    dict(n=3, title="Meridian",         artist="Aurora Field", album="Glass Meridian",
         palette=("#0E1116", "#7C93A6"), motif="rings",    seconds=40),
    dict(n=4, title="Paper Lantern",    artist="Nine Volt",    album="Quiet Machines",
         palette=("#141414", "#E4B363"), motif="grid",     seconds=40),
    dict(n=5, title="Undertow",         artist="Mira Sound",   album="Salt & Static",
         palette=("#0D1A33", "#EDEDED"), motif="halftone", seconds=40),
    dict(n=6, title="静水流深",          artist="青禾",          album="远山",
         palette=("#161C2A", "#D9A566"), motif="ridge",    seconds=40),
    dict(n=7, title="午后",              artist="拾光",          album="旧胶片",
         palette=("#2A211B", "#E8DCC8"), motif="bands",    seconds=40),
    dict(n=8, title="Snowline",         artist="Kestrel",      album="Winter Atlas",
         palette=("#26303A", "#BFD3E0"), motif="contour",  seconds=40),
]


def _hex(c: str) -> tuple[int, int, int]:
    c = c.lstrip("#")
    return tuple(int(c[i : i + 2], 16) for i in (0, 2, 4))  # type: ignore[return-value]


def _lerp(a, b, t):
    return tuple(int(round(a[i] + (b[i] - a[i]) * t)) for i in range(3))


def _grain(img: Image.Image, strength: int = 6) -> Image.Image:
    """叠一层细噪点，模拟胶片质感（纯程序生成，不是任何素材）。"""
    noise = Image.effect_noise((img.width, img.height), strength).convert("L")
    noise = noise.filter(ImageFilter.GaussianBlur(0.4))
    return Image.blend(img, Image.merge("RGB", (noise, noise, noise)), 0.06)


def _vertical_gradient(c0, c1, w=SIZE, h=SIZE) -> Image.Image:
    t = np.linspace(0.0, 1.0, h)[:, None]
    rows = np.array([_lerp(c0, c1, float(v)) for v in t[:, 0]], dtype=np.uint8)
    arr = np.repeat(rows[:, None, :], w, axis=1)
    return Image.fromarray(arr, "RGB")


def _diag_gradient(c0, c1, w=SIZE, h=SIZE) -> Image.Image:
    yy, xx = np.mgrid[0:h, 0:w]
    t = (xx / max(w - 1, 1) * 0.55 + yy / max(h - 1, 1) * 0.45)
    c0a, c1a = np.array(c0, float), np.array(c1, float)
    arr = (c0a[None, None, :] * (1 - t[..., None]) + c1a[None, None, :] * t[..., None])
    return Image.fromarray(arr.astype(np.uint8), "RGB")


# ------------------------------------------------------------------- 八种母题
def cov_horizon(c0, c1) -> Image.Image:
    img = _vertical_gradient(c1, c0)
    d = ImageDraw.Draw(img)
    horizon = int(SIZE * 0.62)
    d.rectangle([0, horizon, SIZE, SIZE], fill=c0)
    glow = Image.new("RGB", (SIZE, SIZE), c1)
    m = Image.new("L", (SIZE, SIZE), 0)
    ImageDraw.Draw(m).ellipse(
        [SIZE * 0.12, horizon - SIZE * 0.30, SIZE * 0.88, horizon + SIZE * 0.10], fill=110
    )
    img = Image.composite(glow, img, m.filter(ImageFilter.GaussianBlur(70)))
    d = ImageDraw.Draw(img)
    d.rectangle([0, horizon, SIZE, horizon + 3], fill=c1)
    for i in range(5):  # 水面横纹
        y = horizon + 40 + i * 46
        d.rectangle([SIZE * 0.10, y, SIZE * (0.90 - i * 0.06), y + 2],
                    fill=_lerp(c0, c1, 0.35 - i * 0.05))
    return _grain(img)


def cov_orb(c0, c1) -> Image.Image:
    img = _diag_gradient(c0, _lerp(c0, c1, 0.35))
    d = ImageDraw.Draw(img)
    cx, cy, r = SIZE * 0.58, SIZE * 0.42, SIZE * 0.30
    d.ellipse([cx - r, cy - r, cx + r, cy + r], fill=c1)
    d.ellipse([cx - r * 0.62, cy - r * 0.62, cx + r * 0.62, cy + r * 0.62], fill=c0)
    d.arc([cx - r * 1.55, cy - r * 1.55, cx + r * 1.55, cy + r * 1.55],
          200, 340, fill=c1, width=6)
    return _grain(img)


def cov_rings(c0, c1) -> Image.Image:
    img = Image.new("RGB", (SIZE, SIZE), c0)
    d = ImageDraw.Draw(img)
    cx, cy = SIZE * 0.42, SIZE * 0.38
    for i in range(26):
        rr = 26 + i * 21
        col = _lerp(c0, c1, max(0.0, 1.0 - i / 26.0) * 0.95)
        d.ellipse([cx - rr, cy - rr, cx + rr, cy + rr], outline=col, width=2 if i % 3 else 4)
    return _grain(img).filter(ImageFilter.GaussianBlur(0.3))


def cov_grid(c0, c1) -> Image.Image:
    img = Image.new("RGB", (SIZE, SIZE), c0)
    d = ImageDraw.Draw(img)
    n, gap = 8, 18
    cell = (SIZE - gap * (n + 1)) / n
    for r in range(n):
        for c in range(n):
            x = gap + c * (cell + gap)
            y = gap + r * (cell + gap)
            k = ((r * 3 + c * 5) % 7) / 6.0
            col = _lerp(_lerp(c0, c1, 0.15), c1, k)
            d.rectangle([x, y, x + cell, y + cell], fill=col)
    return _grain(img)


def cov_halftone(c0, c1) -> Image.Image:
    img = Image.new("RGB", (SIZE, SIZE), c0)
    d = ImageDraw.Draw(img)
    step = 34
    for y in range(step // 2, SIZE, step):
        for x in range(step // 2, SIZE, step):
            t = 1.0 - math.hypot(x - SIZE * 0.32, y - SIZE * 0.68) / (SIZE * 1.05)
            t = max(0.0, min(1.0, t * 1.55))
            if t < 0.05:
                continue
            rr = t * step * 0.52
            d.ellipse([x - rr, y - rr, x + rr, y + rr],
                      fill=_lerp(c0, c1, min(1.0, 0.25 + t)))
    return _grain(img)


def cov_ridge(c0, c1) -> Image.Image:
    img = _vertical_gradient(_lerp(c0, c1, 0.72), c0)
    d = ImageDraw.Draw(img)
    rng = np.random.default_rng(20261012)
    for layer in range(4):
        base = SIZE * (0.50 + layer * 0.13)
        amp = 60 - layer * 9
        pts = [(0, SIZE)]
        for x in range(0, SIZE + 1, 16):
            y = base + amp * math.sin(x / (120 + layer * 30) + layer) + rng.normal(0, 4)
            pts.append((x, y))
        pts.append((SIZE, SIZE))
        d.polygon(pts, fill=_lerp(c0, c1, 0.10 + layer * 0.16))
    d.ellipse([SIZE * 0.60, SIZE * 0.16, SIZE * 0.84, SIZE * 0.40],
              fill=_lerp(c1, (255, 255, 255), 0.35))
    return _grain(img)


def cov_bands(c0, c1) -> Image.Image:
    img = Image.new("RGB", (SIZE, SIZE), c0)
    d = ImageDraw.Draw(img)
    y = 0
    i = 0
    while y < SIZE:
        h = 12 + (i * 17) % 46
        d.rectangle([0, y, SIZE, y + h], fill=_lerp(c0, c1, ((i * 7) % 10) / 10 * 0.85))
        y += h + 6
        i += 1
    edge = Image.new("RGB", (SIZE, SIZE), c1)
    m = Image.new("L", (SIZE, SIZE), 0)
    ImageDraw.Draw(m).rectangle([SIZE * 0.78, 0, SIZE, SIZE], fill=150)
    img = Image.composite(edge, img, m.filter(ImageFilter.GaussianBlur(3)))
    return _grain(img, 8)


def cov_contour(c0, c1) -> Image.Image:
    img = Image.new("RGB", (SIZE, SIZE), c0)
    d = ImageDraw.Draw(img)
    for k in range(22):
        pts = []
        phase = k * 0.42
        for x in range(0, SIZE + 1, 8):
            y = SIZE * 0.5 + (k - 11) * 22 + 46 * math.sin(x / 150 + phase) * (1 - k / 40)
            pts.append((x, y))
        d.line(pts, fill=_lerp(c0, c1, 0.20 + (k % 5) * 0.13), width=2)
    d.ellipse([SIZE * 0.20, SIZE * 0.20, SIZE * 0.46, SIZE * 0.46], outline=c1, width=3)
    return _grain(img)


MOTIFS = {
    "horizon": cov_horizon,
    "orb": cov_orb,
    "rings": cov_rings,
    "grid": cov_grid,
    "halftone": cov_halftone,
    "ridge": cov_ridge,
    "bands": cov_bands,
    "contour": cov_contour,
}


# ------------------------------------------------------------------ 音频合成
def synth(seconds: float, sr: int, seed: int) -> np.ndarray:
    """合成一段柔和的环境音（和弦垫 + 极轻噪声），返回 (n, 2) float。"""
    rng = np.random.default_rng(seed)
    n = int(seconds * sr)
    t = np.arange(n) / sr
    root = 110.0 * (2 ** (rng.integers(0, 4) / 12))  # 略作变化
    sig = np.zeros(n)
    for mult, gain in ((1.0, 0.5), (1.5, 0.30), (2.0, 0.20), (2.997, 0.12), (4.0, 0.07)):
        lfo = 1.0 + 0.05 * np.sin(2 * math.pi * (0.07 + mult * 0.02) * t + rng.random())
        sig += gain * lfo * np.sin(2 * math.pi * root * mult * t + rng.random())
    air = 0.012 * rng.standard_normal(n)
    sig = sig + air
    # 5 秒周期的缓慢起伏，让波形有内容
    sig *= 0.72 + 0.28 * np.sin(2 * math.pi * t / (seconds / 2.5) + rng.random())
    # 淡入淡出
    fade = int(sr * 1.8)
    sig[:fade] *= np.linspace(0, 1, fade)
    sig[-fade:] *= np.linspace(1, 0, fade)
    peak = float(np.max(np.abs(sig))) or 1.0
    sig = sig / peak * 0.62
    left = sig * 0.99
    right = np.roll(sig, int(sr * 0.004)) * 0.99  # 轻微立体声差
    return np.stack([left, right], axis=1)


def write_wav(path: Path, data: np.ndarray, sr: int, bits: int) -> None:
    if bits == 16:
        pcm = np.clip(data * 32767.0, -32768, 32767).astype("<i2")
        sampwidth, raw = 2, pcm.tobytes()
    else:  # 24-bit
        v = np.clip(data * 8388607.0, -8388608, 8388607).astype("<i4")
        raw = v.astype("<i4").tobytes()
        raw = b"".join(raw[i : i + 3] for i in range(0, len(raw), 4))
        sampwidth = 3
    with wave.open(str(path), "wb") as w:
        w.setnchannels(2)
        w.setsampwidth(sampwidth)
        w.setframerate(sr)
        w.writeframes(raw)


def run_ffmpeg(wav: Path, cover: Path, out: Path, tr: dict) -> None:
    cmd = [
        "ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
        "-i", str(wav), "-i", str(cover),
        "-map", "0:a", "-map", "1:v",
        "-c:a", "flac", "-compression_level", "5",
        "-c:v", "png", "-disposition:v", "attached_pic",
        "-metadata", f"title={tr['title']}",
        "-metadata", f"artist={tr['artist']}",
        "-metadata", f"album={tr['album']}",
        "-metadata", f"albumartist={tr['artist']}",
        "-metadata", f"track={tr['n']}",
        "-metadata", "date=2026",
        "-metadata", "genre=Ambient",
        "-metadata", "comment=WaveLink demo asset - procedurally generated, no third-party content",
        str(out),
    ]
    subprocess.run(cmd, check=True)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=str(Path.home() / "Desktop" / "WaveLink-Demo-Pack"))
    ap.add_argument("--covers-only", action="store_true")
    args = ap.parse_args()

    out = Path(args.out).expanduser().resolve()
    covers_dir = out / "covers"
    music_dir = out / "music"
    covers_dir.mkdir(parents=True, exist_ok=True)
    if not args.covers_only:
        music_dir.mkdir(parents=True, exist_ok=True)

    print(f"输出目录: {out}\n")

    # 1) 封面
    made = {}
    for tr in TRACKS:
        c0, c1 = _hex(tr["palette"][0]), _hex(tr["palette"][1])
        img = MOTIFS[tr["motif"]](c0, c1).resize((SIZE, SIZE), Image.LANCZOS)
        name = f"{tr['n']:02d} - {tr['album']}.png"
        p = covers_dir / name
        img.save(p, "PNG", optimize=True)
        made[tr["n"]] = p
        print(f"  封面 [{tr['motif']:8s}] {name}")

    if args.covers_only:
        print("\n完成（仅封面）。")
        return 0

    # 2) 曲目（临时 wav → flac + 内嵌封面）
    if shutil.which("ffmpeg") is None:
        print("\n⚠️ 找不到 ffmpeg（brew install ffmpeg），已只生成封面。", file=sys.stderr)
        return 0

    with tempfile.TemporaryDirectory() as td:
        for tr in TRACKS:
            hi = bool(tr.get("hi_res", False))
            sr = 96000 if hi else 44100
            bits = 24 if hi else 16
            data = synth(tr["seconds"], sr, seed=1000 + tr["n"])
            wav = Path(td) / f"{tr['n']:02d}.wav"
            write_wav(wav, data, sr, bits)
            name = f"{tr['n']:02d} {tr['artist']} - {tr['title']}.flac"
            run_ffmpeg(wav, made[tr["n"]], music_dir / name, tr)
            mb = (music_dir / name).stat().st_size / 1024 / 1024
            print(f"  曲目 {name}  ({sr//1000} kHz/{bits} bit, {tr['seconds']}s, {mb:.1f} MB)")

    # 3) 说明文件
    manifest = {
        "generated_by": "tools/gen_asc_demo_assets.py",
        "purpose": "App Store 截图用演示素材；全部由代码生成，不含任何第三方素材，且不含歌词",
        "tracks": [
            {
                "n": tr["n"], "title": tr["title"], "artist": tr["artist"],
                "album": tr["album"], "seconds": tr["seconds"],
                "hi_res": bool(tr.get("hi_res", False)),
            }
            for tr in TRACKS
        ],
    }
    (out / "manifest.json").write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2), encoding="utf-8"
    )
    (out / "README.txt").write_text(
        "WaveLink 演示素材包（用于 App Store 截图）\n"
        "=========================================\n\n"
        "为什么需要它：\n"
        "  App 因 Guideline 5.2.1 被拒 —— App Store 截图里出现了真实专辑封面与真实歌词。\n"
        "  本包提供完全无版权风险的替代素材：全部由代码程序化生成，不含任何第三方素材、\n"
        "  不含歌词（无 lyrics 标签、无 .lrc 文件）。\n\n"
        "内容：\n"
        "  covers/   8 张原创专辑封面（几何/渐变/噪点，无文字、无人物、无 logo，1024x1024）\n"
        "  music/    8 首合成演示曲目（FLAC，已内嵌对应封面；元数据为虚构名称；2 首 96kHz/24bit）\n\n"
        "用法（把素材放进 App 再重拍截图）：\n"
        "  1. 把本文件夹（或 music/ 目录）用 AirDrop 传到 iPhone\n"
        "  2. iPhone「文件」App 里解压/定位到这两个目录\n"
        "  3. 打开 WaveLink → 「文件导入」→ 选中 music/ 里的 8 个 .flac 全部导入\n"
        "  4. 确认曲库显示的是本包的封面（几何图案），且**不显示歌词**\n"
        "     （若有歌词开关，截图前关掉）\n"
        "  5. 按 ASC_ACTION_CHECKLIST.md 第 10 步重拍并替换 App Store 截图\n\n"
        "注意：iPhone 上原来的真实音乐文件请先移除/隐藏，避免它们出现在截图里。\n\n"
        "重新生成：python3 tools/gen_asc_demo_assets.py\n",
        encoding="utf-8",
    )
    print(f"\n完成 → {out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
