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

# App Store 上传要求 archive 内每个二进制都有配套 dSYM（否则报 missing dSYM）。
# cargo 的 split-debuginfo=packed 在 target/release 生成同名 .dSYM bundle；
# Archive 时 Xcode 注入 DWARF_DSYM_FOLDER_PATH（指向 .xcarchive/dSYMs），拷入即可。
# install_name_tool 只改 LC_ID_DYLIB 不动 UUID，与 dSYM 的匹配关系不受影响。
#
# ⚠️ 关键坑（本次报错根因）：split-debuginfo=packed 会把顶层
#   target/release/libwavelink_desktop.dylib.dSYM 建成「指向 deps/… 的符号链接」。
# 若直接 `cp -Rf` 会把符号链接原样拷进 archive，其相对目标 deps/… 在归档内不存在
# → 悬空链接 → App Store 校验报
#   "The archive did not include a dSYM for the libwavelink_desktop.dylib with the UUIDs [...]"。
# 因此必须先解引用到真实目录再拷贝，并保证落盘的是真实目录（非链接）。
if [ -n "${DWARF_DSYM_FOLDER_PATH:-}" ]; then
  DSYM_SRC="$SRC.dSYM"
  if [ -e "$DSYM_SRC" ]; then
    # 解引用符号链接（macOS 自带 readlink 无 -f，手动处理相对/绝对目标）
    if [ -L "$DSYM_SRC" ]; then
      _tgt=$(readlink "$DSYM_SRC")
      case "$_tgt" in
        /*) DSYM_SRC="$_tgt" ;;
        *)  DSYM_SRC="$(dirname "$DSYM_SRC")/$_tgt" ;;
      esac
    fi
    mkdir -p "$DWARF_DSYM_FOLDER_PATH"
    # 先清掉可能残留的悬空链接/旧目录，避免 cp 套娃成 dSYM.dSYM
    rm -rf "$DWARF_DSYM_FOLDER_PATH/libwavelink_desktop.dylib.dSYM"
    cp -Rf "$DSYM_SRC" "$DWARF_DSYM_FOLDER_PATH/libwavelink_desktop.dylib.dSYM"
    echo "[rust] copied dSYM -> $DWARF_DSYM_FOLDER_PATH/libwavelink_desktop.dylib.dSYM"
  else
    echo "[rust] WARNING: dSYM not found at $SRC.dSYM (App Store 上传会被拒；需 workspace [profile.release] debug=true + split-debuginfo=packed)"
  fi
fi

echo "[rust] bundled + fixed + signed dylib -> $DST"
