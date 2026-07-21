#!/usr/bin/env python3
"""从 wavelink-audio-core 源码生成纯 Markdown API 参考手册。
AI 助手请优先读此文件，而非读 src/ 源码（~4500 行）。

用法: python3 gen_api_md.py
输出: API_REFERENCE.md
"""
import os, re

SRC = "src"
OUT = "API_REFERENCE.md"


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

            # Module-level doc (first //! line)
            mod_doc = ""
            for line in lines:
                m = re.match(r'^//!\s?(.*)', line)
                if m:
                    mod_doc = m.group(1)
                    break

            # Extract ///-documented pub items
            items = []
            i = 0
            while i < len(lines):
                # 跳过 doc 前的空行/属性行（不跳过 /// 行）
                while i < len(lines):
                    s = lines[i].strip()
                    if s == "" or s.startswith("#["):
                        i += 1
                    else:
                        break
                # 收集文档注释块
                docs = []
                while i < len(lines) and lines[i].lstrip().startswith("///"):
                    docs.append(re.sub(r'^\s*///\s?', '', lines[i]))
                    i += 1
                # 跳过 doc 和 pub 之间的空行/属性行
                while i < len(lines):
                    s = lines[i].strip()
                    if s == "" or s.startswith("#[") or s.startswith("//!"):
                        i += 1
                    else:
                        break
                # 如果找到了 doc 且下一行有 pub，记录
                if docs and i < len(lines):
                    sig = lines[i].strip()
                    if "pub " in sig:
                        # 去掉函数体/结构体体
                        if "{" in sig:
                            sig = sig[:sig.index("{")].rstrip() + " { ..."
                        # 压缩空白
                        sig = re.sub(r'\s+', ' ', sig)
                        if len(sig) > 120:
                            sig = sig[:117] + "..."
                        items.append((docs, sig))
                i += 1

            if items or mod_doc:
                result[rel] = (mod_doc, items)

    return result


def src_hash():
    """计算 src/ 目录下所有 .rs 文件的 hash，用于判断文档是否最新。"""
    import hashlib
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

    with open(OUT, "w") as out:
        out.write("# wavelink-audio-core API Reference\n\n")
        out.write(f"> 源码 hash: `{stamp}`  |  生成时间: {__import__('datetime').datetime.now().strftime('%Y-%m-%d %H:%M')}\n")
        out.write("> AI 助手优先读此文件，而非读 `src/` 源码。若 AI 返回的代码与当前签名不匹配，请重新运行 `bash doc-api.sh`。\n\n")

        # Sort: lib.rs first, then by module path
        order = sorted(data.keys(), key=lambda k: (0 if k == "lib.rs" else 1, k))

        for rel in order:
            mod_doc, items = data[rel]
            if not items and not mod_doc:
                continue

            out.write("---\n\n")
            if mod_doc:
                out.write(f"### `{rel}` — {mod_doc}\n\n")
            else:
                out.write(f"### `{rel}`\n\n")

            for docs, sig in items:
                for d in docs:
                    if d:
                        out.write(f"{d}  \n")
                out.write(f"```rust\n{sig}\n```\n\n")

        out.write("---\n\n")
        out.write(f"> {total_items} 个 pub 项。运行 `bash doc-api.sh` 刷新。\n")

    print(f"✅ {OUT} ({sum(1 for _ in open(OUT))} 行, {total_items} 个 pub 项)")


if __name__ == "__main__":
    main()
