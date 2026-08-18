#!/bin/sh
# 构建 Rust 音频引擎动态库并打包进 macOS app bundle 的 Frameworks 目录。
#
# 由 Runner target 的 "Build Rust Engine" Run Script 阶段调用。
# Xcode 会把所有 build settings（PROJECT_DIR / BUILT_PRODUCTS_DIR /
# FRAMEWORKS_FOLDER_PATH / CONFIGURATION 等）作为环境变量传入，脚本直接使用。

set -e

# 确保 cargo 在 PATH 上（rustup 默认装到 ~/.cargo/bin）。
export PATH="$HOME/.cargo/bin:$PATH"

# PROJECT_DIR = <app>/macos，上两级即 cargo 虚拟工作区根（Cargo.toml 所在）。
ROOT_DIR="$PROJECT_DIR/../.."
RUST_MANIFEST="$ROOT_DIR/Cargo.toml"

if [ "$CONFIGURATION" = "Release" ]; then
  PROFILE="--release"
  SRC="$ROOT_DIR/target/release/libwavelink_desktop.dylib"
else
  PROFILE=""
  SRC="$ROOT_DIR/target/debug/libwavelink_desktop.dylib"
fi

echo "[rust] building wavelink_desktop ($CONFIGURATION)..."
cargo build --manifest-path "$RUST_MANIFEST" -p wavelink_desktop $PROFILE

DST_DIR="$BUILT_PRODUCTS_DIR/$FRAMEWORKS_FOLDER_PATH"
mkdir -p "$DST_DIR"
cp -f "$SRC" "$DST_DIR/libwavelink_desktop.dylib"
DST="$DST_DIR/libwavelink_desktop.dylib"

# 修复 macOS 上 cargo 编 cdylib 的已知坑：dylib 的 install_name 被设为
# target/.../deps/libwavelink_desktop.dylib（绝对路径）并自依赖该路径。
# 把 id 与自依赖都改到 @rpath，使打包后的 app 不再依赖构建目录绝对路径
# （Frameworks 已在 LD_RUNPATH_SEARCH_PATHS 的 @executable_path/../Frameworks 中）。
OLD_ID=$(otool -D "$DST" | tail -1)
install_name_tool -id @rpath/libwavelink_desktop.dylib "$DST"
if [ -n "$OLD_ID" ]; then
  install_name_tool -change "$OLD_ID" @rpath/libwavelink_desktop.dylib "$DST" 2>/dev/null || true
fi

# 随 app 一起 ad-hoc 签名，避免嵌套 dylib 触发库校验导致加载失败（本地分发足够）。
codesign --force --sign - "$DST" 2>/dev/null || true

echo "[rust] bundled + fixed + signed dylib -> $DST"
