#!/bin/sh
# 校验 macOS 构建产物里 Rust 引擎 dylib 是否正确打包进 app bundle。
#
# 防止两类回归（本次修复踩过的坑）：
#   1. dylib 没被打进 Contents/Frameworks/（Engine.load() 找不到 → 无法播放）；
#   2. dylib 的 install_name / 自依赖指向构建目录绝对路径 target/.../deps/，
#      导致打包后的 app 硬依赖本机构建目录（cargo 在 macOS 编 cdylib 的已知行为）。
#
# 用法：
#   macos/Scripts/verify_rust_bundle.sh [<app路径>]
# 不传参则自动探测 build/macos/Build/Products/*/local_music_player.app（取最新）。
# 供 CI 或手动验证；校验失败以非 0 退出。
# 依赖：otool（Xcode 自带）。

set -e

APP="${1:-}"
if [ -z "$APP" ]; then
  APP=$(ls -d "$PWD"/build/macos/Build/Products/*/local_music_player.app 2>/dev/null | sort | tail -1)
fi

if [ -z "$APP" ] || [ ! -d "$APP" ]; then
  echo "error: 找不到 app bundle，请先 flutter build macos，或显式传入 .app 路径" >&2
  exit 1
fi

DYLIB="$APP/Contents/Frameworks/libwavelink_desktop.dylib"

if [ ! -f "$DYLIB" ]; then
  echo "FAIL: $DYLIB 不存在（Rust 引擎未打包进 app）" >&2
  exit 1
fi

ID=$(otool -D "$DYLIB" | tail -1)
case "$ID" in
  @rpath/libwavelink_desktop.dylib) ;;
  *)
    echo "FAIL: install_name 非 @rpath，而是: $ID" >&2
    echo "      应重跑 macos/Scripts/build_rust.sh 中的 install_name_tool 修复" >&2
    exit 1
    ;;
esac

if otool -L "$DYLIB" | grep -qE "/target/|/deps/libwavelink"; then
  echo "FAIL: dylib 仍依赖构建目录绝对路径:" >&2
  otool -L "$DYLIB" | grep -E "/target/|/deps/libwavelink" >&2
  exit 1
fi

echo "OK: $DYLIB 已正确打包"
echo "    install_name = @rpath/libwavelink_desktop.dylib"
echo "    无构建目录绝对路径依赖"
