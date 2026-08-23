#!/usr/bin/env bash
# 自动递增 pubspec.yaml 的构建号（1.0.0+3 -> 1.0.0+4），不改版本号。
# 用法：
#   tool/bump_build_number.sh          # 递增并写回
#   tool/bump_build_number.sh --dry-run  # 只预览，不写文件
set -euo pipefail

cd "$(dirname "$0")/.."
PUBSPEC="pubspec.yaml"
DRY_RUN=false
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=true

NEW=$(python3 - "$PUBSPEC" <<'EOF'
import re, sys
path = sys.argv[1]
with open(path) as f:
    content = f.read()
m = re.search(r'^version:\s*(\d+\.\d+\.\d+)\+(\d+)\s*$', content, re.M)
if not m:
    print("ERROR: 未找到 version: x.y.z+N（格式如 1.0.0+3）", file=sys.stderr)
    sys.exit(1)
base, build = m.group(1), int(m.group(2))
print(f"{base}+{build + 1}")
EOF
)

echo "构建号：$(grep '^version:' "$PUBSPEC" | awk '{print $2}') -> $NEW"
if $DRY_RUN; then
    echo "[dry-run] 未写入文件"
    exit 0
fi

sed -i '' -E "s/^version: .+$/version: $NEW/" "$PUBSPEC"
echo "✅ 已写入 pubspec.yaml（记得提交 git）"
