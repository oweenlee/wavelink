#!/usr/bin/env python3
"""从 wavelink-audio-core 源码生成结构化的 Markdown API 参考手册。
AI 助手优先读此文件，而非读 src/ 源码。

用法: python3 gen_api_md.py
输出: API_REFERENCE.md
"""
import os, re, hashlib
from datetime import datetime

SRC = "src"
OUT = "API_REFERENCE.md"

# 层分组映射: {relpath: (layer_name, subtopic)}
# subtopic=None 表示用文件的 mod_doc 作为子标题
LAYER_MAP = {
    "lib.rs": ("Top-Level", None),
    "engine/mod.rs": ("Engine", None),
    "engine/command.rs": ("Engine", "Commands & Events"),
    "engine/handle.rs": ("Engine", "EngineHandle"),
    "engine/queue.rs": ("Engine", "Queue Entry"),
    "engine/recovery.rs": ("Engine", "Device Recovery"),
    "engine/state.rs": ("Engine", "Internal State"),
    "engine/worker.rs": ("Engine", "Worker Thread"),
    "engine/thread_priority.rs": ("Engine", "Thread Priority"),
    "capture.rs": ("Capture", None),
    "decoder.rs": ("Decoder", None),
    "dsp/mod.rs": ("DSP Pipeline", None),
    "dsp/pipeline.rs": ("DSP Pipeline", "Pipeline"),
    "dsp/biquad.rs": ("DSP Pipeline", "Biquad Filters"),
    "dsp/convolver.rs": ("DSP Pipeline", "FIR Convolution EQ"),
    "dsp/crossfeed.rs": ("DSP Pipeline", "Crossfeed"),
    "dsp/dither.rs": ("DSP Pipeline", "Dither & Noise Shaping"),
    "dsp/limiter.rs": ("DSP Pipeline", "True-Peak Limiter"),
    "dsp/speed.rs": ("DSP Pipeline", "Speed Changer"),
    "dsp/widener.rs": ("DSP Pipeline", "Stereo Widener"),
    "output.rs": ("Output", None),
    "output/output_audiounit.rs": ("Output", "iOS AudioUnit"),
    "output/output_cpal.rs": ("Output", "cpal (Desktop)"),
    "output/output_oboe.rs": ("Output", "Android Oboe"),
    "analysis/mod.rs": ("Analysis", None),
    "analysis/bpm.rs": ("Analysis", "BPM Detection"),
    "analysis/key.rs": ("Analysis", "Key Detection"),
    "dsd/mod.rs": ("DSD", None),
    "dsd/convert.rs": ("DSD", "Conversion"),
    "stream.rs": ("Stream", None),
    "cue/mod.rs": ("CUE", None),
    "playlist/mod.rs": ("Playlist", None),
    "consumer.rs": ("Consumer (Decode→DSP→Ringbuf)", None),
    "error.rs": ("Error", None),
    "exclusive.rs": ("Exclusive Mode", None),
}

LAYER_ORDER = [
    "Top-Level",
    "Engine",
    "Decoder",
    "Capture",
    "Consumer (Decode→DSP→Ringbuf)",
    "DSP Pipeline",
    "Output",
    "Analysis",
    "DSD",
    "Stream",
    "CUE",
    "Playlist",
    "Error",
    "Exclusive Mode",
]


def gather():
    """Walk all .rs files, return {relpath: (mod_doc, [(doc_block, sig_line), ...])}."""
    result = {}
    for root, _dirs, files in os.walk(SRC):
        for f in sorted(files):
            if not f.endswith(".rs"):
                continue
            path = os.path.join(root, f)
            rel = os.path.relpath(path, SRC)
            with open(path) as fh:
                text = fh.read()
            lines = text.split("\n")

            mod_doc = ""
            for line in lines:
                m = re.match(r'^//!\s?(.*)', line)
                if m:
                    mod_doc = m.group(1)
                    break

            items = []
            i = 0
            while i < len(lines):
                while i < len(lines):
                    s = lines[i].strip()
                    if s == "" or s.startswith("#["):
                        i += 1
                    else:
                        break
                docs = []
                while i < len(lines) and lines[i].lstrip().startswith("///"):
                    docs.append(re.sub(r'^\s*///\s?', '', lines[i]))
                    i += 1
                while i < len(lines):
                    s = lines[i].strip()
                    if s == "" or s.startswith("#[") or s.startswith("//!"):
                        i += 1
                    else:
                        break
                if docs and i < len(lines):
                    sig = lines[i].strip()
                    if "pub " in sig:
                        if "{" in sig:
                            sig = sig[:sig.index("{")].rstrip() + " { ..."
                        sig = re.sub(r'\s+', ' ', sig)
                        items.append((docs, sig))
                i += 1

            if items or mod_doc:
                result[rel] = (mod_doc, items)

    return result


def src_hash():
    h = hashlib.sha256()
    for root, _dirs, files in os.walk(SRC):
        for f in sorted(files):
            if not f.endswith(".rs"):
                continue
            path = os.path.join(root, f)
            with open(path, "rb") as fh:
                h.update(fh.read())
    return h.hexdigest()[:12]


def main():
    data = gather()
    total_items = sum(len(items) for _, items in data.values())
    stamp = src_hash()

    # 未映射的文件丢到 Misc
    mapped_rels = set(LAYER_MAP.keys())
    for rel in data:
        if rel not in mapped_rels:
            layer, sub = LAYER_MAP.get(rel, (None, None))
            if layer is None:
                LAYER_MAP[rel] = ("Misc", None)
    if "Misc" not in LAYER_ORDER:
        LAYER_ORDER.append("Misc")

    with open(OUT, "w") as out:
        out.write("# wavelink-audio-core API Reference\n\n")
        out.write(f"> Source hash: `{stamp}` | Generated: {datetime.now().strftime('%Y-%m-%d %H:%M')}\n")
        out.write("> AI 助手优先读此文件，而非读 `src/` 源码。若 AI 返回的代码与当前签名不匹配，请重新运行 `bash doc-api.sh`。\n\n")

        # ========== Table of Contents ==========
        out.write("## Table of Contents\n\n")
        for layer in LAYER_ORDER:
            files_in = sorted(rel for rel in data if LAYER_MAP.get(rel, (None, None))[0] == layer)
            if not files_in:
                continue
            out.write(f"- **{layer}**\n")
            for rel in files_in:
                sub = LAYER_MAP.get(rel, (None, None))[1]
                mod_doc, _ = data[rel]
                label = sub if sub else (mod_doc if mod_doc else rel)
                out.write(f"  - {label} (`{rel}`)\n")
        out.write("\n---\n\n")

        # ========== Content by Layer ==========
        for layer in LAYER_ORDER:
            files_in = sorted(rel for rel in data if LAYER_MAP.get(rel, (None, None))[0] == layer)
            if not files_in:
                continue

            out.write(f"## {layer}\n\n")

            for rel in files_in:
                mod_doc, items = data[rel]
                sub = LAYER_MAP.get(rel, (None, None))[1]

                if sub:
                    heading = f"{sub} (`{rel}`)"
                elif mod_doc:
                    heading = f"{mod_doc} (`{rel}`)"
                else:
                    heading = f"`{rel}`"

                out.write(f"### {heading}\n\n")
                if not items:
                    out.write(f"{mod_doc}\n\n") if mod_doc else None
                    continue

                for docs, sig in items:
                    for d in docs:
                        if d:
                            out.write(f"{d}  \n")
                    out.write(f"```rust\n{sig}\n```\n\n")

            out.write("---\n\n")

        out.write(f"> {total_items} pub items. ")
        out.write("Run `bash doc-api.sh` to refresh.\n")

    def plural(n, s): return f"{n} {s}" + ("" if n == 1 else "s")
    print(f"[OK] {OUT} ({sum(1 for _ in open(OUT))} lines, {plural(total_items, 'pub item')})")


if __name__ == "__main__":
    main()
