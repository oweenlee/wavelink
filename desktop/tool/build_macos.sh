#!/usr/bin/env bash
# 仅打包 macOS，目标产出 .xcarchive（供 Xcode Organizer 上传 App Store）：
#   - 每次构建自动 build 号 +1（pubspec.yaml version: x.y.z+N）
#   - flutter build macos --release 准备（生成 Generated.xcconfig、嵌入 Rust dylib）
#   - xcodebuild archive 出 .xcarchive（含 dSYM；dSYM 由 Xcode 的「Build Rust Engine」
#     阶段在 archive 时拷入，普通出 .app 不会带 dSYM）
#
# 用法：
#   tool/build_macos.sh              # build +1 + 出 .xcarchive（默认）
#   tool/build_macos.sh --no-bump    # 不递增 build 号
#   tool/build_macos.sh --no-archive # 只出 .app，不出 .xcarchive
#
# 说明：
#   - build 号来自 pubspec.yaml 的 version: x.y.z+N，由 tool/bump_build_number.sh 递增。
#   - Flutter 构建阶段会把 pubspec 的 N 自动同步进 Xcode 的 CURRENT_PROJECT_VERSION。
#   - 上传：Xcode → Window → Organizer 打开 build/WaveLink.xcarchive，Distribute App 选
#     App Store Connect，dSYM 已随归档一并上传，不会再报 missing dSYM。
set -euo pipefail

# 切到 desktop/ 根目录（脚本位于 tool/ 下）
cd "$(dirname "$0")/.."

BUMP=1
ARCHIVE=1
for arg in "$@"; do
  case "$arg" in
    --no-bump) BUMP=0 ;;
    --no-archive) ARCHIVE=0 ;;
    *) echo "⚠️  未知参数：$arg（忽略）" ;;
  esac
done

# 1) 递增 build 号
if [[ "$BUMP" -eq 1 ]]; then
  bash tool/bump_build_number.sh
else
  echo "ℹ️  --no-bump：跳过 build 号递增"
fi

VERSION=$(grep '^version:' pubspec.yaml | awk '{print $2}')
echo "📦 当前版本：$VERSION"

# 2) 准备 macOS release 构建（生成 Flutter 配置、嵌入 Rust dylib）
echo "🔨 flutter build macos --release ..."
flutter build macos --release

APP="build/macos/Build/Products/Release/WaveLink.app"
if [[ ! -d "$APP" ]]; then
  echo "❌ 未找到 .app，构建可能失败" >&2
  exit 1
fi
echo "✅ .app 已生成：$APP"

# 3) 出 .xcarchive（默认；App Store 上传需要，dSYM 由 Xcode 构建阶段拷入归档）
if [[ "$ARCHIVE" -eq 1 ]]; then
  ARCHIVE_PATH="build/WaveLink.xcarchive"
  echo "🔨 xcodebuild archive -> $ARCHIVE_PATH ..."
  xcodebuild -workspace macos/Runner.xcworkspace -scheme Runner \
    -destination generic/platform=macOS \
    -archivePath "$ARCHIVE_PATH" archive
  echo "✅ archive 已生成：$ARCHIVE_PATH"
  echo "   👉 Xcode → Window → Organizer 打开此归档，Distribute App 上传即可（dSYM 已包含）"
else
  echo "ℹ️  --no-archive：已跳过 archive，仅产出 .app"
fi

echo "🎉 完成。版本 $VERSION"
