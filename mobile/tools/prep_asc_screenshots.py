#!/usr/bin/env python3
"""ASC 截图预处理：一组原始截图 -> 两组可直接上传的成品图。

用法:
    python3 tools/prep_asc_screenshots.py ~/Desktop/asc-raw
    python3 tools/prep_asc_screenshots.py ~/Desktop/asc-raw -o ~/Desktop/asc-ready

为什么需要这一步:
    ASC 上 en-US 有两组截图 —— 「iPhone 6.1 英寸」(1179x2556) 与
    「iPhone 6.5 英寸」(1284x2778)。只要在真机上按 6.1" 拍一套，
    另一套由同一批图等比缩放即可（Apple 历来接受这种缩放）。

本脚本做的事（纯 sips，无第三方依赖）:
    1. 按文件名排序（用 01_xxx.png … 10_xxx.png 命名即可控制顺序）
    2. 缩放到两个目标尺寸
    3. 统一转成 JPEG —— 顺带去掉 alpha 通道
       （Apple 明确拒绝带 alpha/透明的 PNG，这是上传失败的高频原因）
    4. 回读校验实际像素，尺寸不对就报警（避免白跑一轮审核）

产出:
    <out>/iphone_61/  01_xxx.jpg … 10_xxx.jpg   (1179x2556)
    <out>/iphone_65/  01_xxx.jpg … 10_xxx.jpg   (1284x2778)
"""

from __future__ import annotations

import argparse
import os
import shutil
import subprocess
import sys
from pathlib import Path

# 目标尺寸：(目录名, 宽, 高) —— 宽在前，给人看的；调 sips 时用 (高, 宽)
TARGETS = [
    ("iphone_61", 1179, 2556),  # iPhone 6.1"
    ("iphone_65", 1284, 2778),  # iPhone 6.5" / 6.7"
]

SRC_EXTS = {".png", ".jpg", ".jpeg", ".heic", ".tif", ".tiff"}
MAX_PER_SET = 10


def die(msg: str) -> None:
    print(f"✗ {msg}", file=sys.stderr)
    sys.exit(1)


def have_sips() -> bool:
    return shutil.which("sips") is not None


def probe(path: Path) -> tuple[int, int]:
    """用 sips 回读实际像素尺寸。"""
    out = subprocess.run(
        ["sips", "-g", "pixelWidth", "-g", "pixelHeight", str(path)],
        capture_output=True,
        text=True,
        check=True,
    ).stdout
    w = h = 0
    for line in out.splitlines():
        line = line.strip()
        if line.startswith("pixelWidth:"):
            w = int(line.split(":")[1])
        elif line.startswith("pixelHeight:"):
            h = int(line.split(":")[1])
    return w, h


def convert(src: Path, dst: Path, w: int, h: int) -> None:
    """缩放 + 转 JPEG（顺带丢 alpha）。"""
    dst.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(
        [
            "sips",
            "-s", "format", "jpeg",
            "-s", "formatOptions", "92",
            "-z", str(h), str(w),          # sips 的顺序是 高 宽
            str(src),
            "--out", str(dst),
        ],
        capture_output=True,
        text=True,
        check=True,
    )


def main() -> int:
    ap = argparse.ArgumentParser(
        description="把一组原始截图转成 ASC 可直接上传的两组成品图"
    )
    ap.add_argument("raw_dir", help="原始截图所在目录（真机按 6.1\" 拍的那一套）")
    ap.add_argument(
        "-o", "--out",
        default=str(Path.home() / "Desktop" / "asc-ready"),
        help="输出目录（默认 ~/Desktop/asc-ready）",
    )
    args = ap.parse_args()

    if not have_sips():
        die("找不到 sips —— 这个脚本依赖 macOS 自带的 sips")

    raw = Path(args.raw_dir).expanduser()
    if not raw.is_dir():
        die(f"原始截图目录不存在：{raw}")

    srcs = sorted(
        p for p in raw.iterdir()
        if p.is_file() and p.suffix.lower() in SRC_EXTS and not p.name.startswith(".")
    )
    if not srcs:
        die(f"{raw} 里没有找到图片（支持 {'/'.join(sorted(SRC_EXTS))}）")

    if len(srcs) > MAX_PER_SET:
        print(f"⚠️  找到 {len(srcs)} 张，ASC 每组最多 {MAX_PER_SET} 张 —— 只会取前 {MAX_PER_SET} 张")
        srcs = srcs[:MAX_PER_SET]

    # 先看一眼原始尺寸，给个提示（不阻断）
    w0, h0 = probe(srcs[0])
    if (w0, h0) != (1179, 2556):
        print(f"ℹ️  原始截图是 {w0}x{h0}（常规 6.1\" 应为 1179x2556）——缩放照样会做，尺寸会以目标为准")

    out_root = Path(args.out).expanduser()
    print(f"原始：{raw}  （{len(srcs)} 张）")
    print(f"输出：{out_root}")
    print()

    problems: list[str] = []

    for name, tw, th in TARGETS:
        out_dir = out_root / name
        # 清掉旧的同名输出，避免上一轮的残图混进去
        if out_dir.is_dir():
            for old in out_dir.glob("*.jpg"):
                old.unlink()
        print(f"[{name}] 目标 {tw}x{th}")

        for i, src in enumerate(srcs, 1):
            dst = out_dir / f"{i:02d}_{src.stem}.jpg"
            try:
                convert(src, dst, tw, th)
            except subprocess.CalledProcessError as e:
                problems.append(f"{name}/{src.name} 转换失败：{e.stderr.strip()[:120]}")
                continue

            aw, ah = probe(dst)
            flag = "✓" if (aw, ah) == (tw, th) else "✗"
            if flag == "✗":
                problems.append(f"{dst.name} 实际 {aw}x{ah}，目标是 {tw}x{th}")
            print(f"   {flag} {dst.name:<40} {aw}x{ah}")
        print()

    print("─" * 60)
    if problems:
        print(f"⚠️  {len(problems)} 个问题：")
        for p in problems:
            print(f"   - {p}")
        return 1

    print("✅ 全部就绪。上传步骤：")
    print("   ASC → 版本页 → 「App 预览与屏幕快照」")
    print(f"   左侧选「iPhone 6.1 英寸」→ 删旧图 → 拖入 {out_root}/iphone_61/ 里的 10 张")
    print(f"   左侧选「iPhone 6.5 英寸」→ 删旧图 → 拖入 {out_root}/iphone_65/ 里的 10 张")
    print("   ⚠️ 只改 en-US（zh-Hans / ja 沿用主语言，无独立截图）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
