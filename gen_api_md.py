#!/usr/bin/env python3
"""从 wavelink-audio-core 源码生成结构化的 Markdown API 参考手册。
AI 助手优先读此文件，而非读 src/ 源码。

用法: python3 gen_api_md.py
输出: API_REFERENCE.md
"""
import os, re, hashlib
from datetime import datetime

SRC = "src"
HEADER = "include/wavelink_audio_core.h"
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
    "ffi.rs": ("FFI (C Bindings)", None),
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
    "FFI (C Bindings)",
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


def parse_header():
    """解析 C 头文件中的函数声明和类型定义。"""
    if not os.path.exists(HEADER):
        return set(), set()
    with open(HEADER) as f:
        text = f.read()
    funcs = set(re.findall(r'\b(ac_\w+)\s*\(', text))
    # 匹配 typedef struct/union/enum 后的名字，以及 typedef 返回类型后的函数指针名
    types = set()
    for m in re.finditer(r'typedef\s+(?:struct|union|enum)?\s*\{?[^;]*?\}\s*(\w+)', text, re.DOTALL):
        name = m.group(1)
        if name.startswith("Ac"):
            types.add(name)
    # also match standalone struct/union/enum names used as parameter types
    for m in re.finditer(r'\b(Ac\w+)\s*\*', text):
        types.add(m.group(1))
    for m in re.finditer(r'\b(Ac\w+)\s+\w+', text):
        types.add(m.group(1))
    # filter out function names
    types = {t for t in types if t.startswith("Ac") and not t.startswith("ac_")}
    return funcs, types


def parse_ffi_functions(data):
    """从 ffi.rs 提取 FFI 函数名和类型名。"""
    relpath = "ffi.rs"
    if relpath not in data:
        return [], []
    _, items = data[relpath]
    funcs = []
    types = []
    for docs, sig in items:
        m = re.match(r'pub\s+unsafe\s+extern\s+"C"\s+fn\s+(\w+)', sig)
        if m:
            funcs.append(m.group(1))
        m = re.match(r'pub\s+(struct|enum|type)\s+(\w+)', sig)
        if m:
            types.append(m.group(2))
    return sorted(funcs), sorted(types)


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

    header_funcs, header_types = parse_header()
    ffi_funcs, ffi_types = parse_ffi_functions(data)

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
        out.write("- **C Header Cross-Reference**\n")
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

        # ========== C Header Cross-Reference ==========
        out.write("## C Header Cross-Reference\n\n")
        def plural(n, s): return f"{n} {s}" + ("" if n == 1 else "s")
        out.write(f"`include/wavelink_audio_core.h` declares {plural(len(header_funcs), 'function')} and {plural(len(header_types), 'type')};\n")
        out.write(f"`src/ffi.rs` defines {plural(len(ffi_funcs), 'exported function')} and {plural(len(ffi_types), 'type')}.\n\n")

        missing_funcs = sorted(set(ffi_funcs) - set(header_funcs))
        extra_funcs = sorted(set(header_funcs) - set(ffi_funcs))
        # AcEngine is internal (opaque void* in C API), not expected in header
        missing_types = sorted(set(ffi_types) - set(header_types) - {"AcEngine"})

        if missing_funcs:
            out.write("### Functions in Rust but missing from C header\n\n")
            for fn in missing_funcs:
                out.write(f"- `{fn}`\n")
            out.write("\n")

        if extra_funcs:
            out.write("### Functions in C header but missing from Rust\n\n")
            for fn in extra_funcs:
                out.write(f"- `{fn}`\n")
            out.write("\n")

        if missing_types:
            out.write("### Types in Rust but missing from C header\n\n")
            for t in missing_types:
                out.write(f"- `{t}`\n")
            out.write("\n")

        if not missing_funcs and not extra_funcs and not missing_types:
            out.write("FFI layer and C header are fully in sync.\n\n")

        out.write("---\n\n")
        out.write(f"> {total_items} pub items ({len(ffi_funcs)} FFI exports). ")
        out.write("Run `bash doc-api.sh` to refresh.\n")

    def plural(n, s): return f"{n} {s}" + ("" if n == 1 else "s")
    print(f"[OK] {OUT} ({sum(1 for _ in open(OUT))} lines, {plural(total_items, 'pub item')}, {plural(len(ffi_funcs), 'FFI function')})")
    if missing_funcs:
        print(f"     WARNING: {plural(len(missing_funcs), 'FFI function')} missing from C header")
    if extra_funcs:
        print(f"     WARNING: {plural(len(extra_funcs), 'function')} in C header but not in Rust")
    if missing_types:
        print(f"     WARNING: {plural(len(missing_types), 'FFI type')} missing from C header")


if __name__ == "__main__":
    main()
