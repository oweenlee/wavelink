#!/usr/bin/env bash
# 刷新 API_REFERENCE.md（AI 读此文件，不读 src/ 源码）
set -euo pipefail
cd "$(dirname "$0")"

echo "==> 运行测试..."
cargo test --lib 2>&1 | tail -1

echo "==> 生成 API_REFERENCE.md..."
python3 gen_api_md.py

echo "✅ 完成：`pwd`/API_REFERENCE.md 已更新"
echo "   把此文件发给 AI 即可"
