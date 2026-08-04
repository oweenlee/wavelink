#!/usr/bin/env bash
# 快速运行脚本，自动带上 primary-constructors 实验标志
set -euo pipefail

cd "$(dirname "$0")/.."

target="${1:-ios}"  # 默认 iOS，可以传 macos / chrome / android

if [ "$target" = "ios" ]; then
  flutter run --enable-experiment=primary-constructors "$@"
elif [ "$target" = "macos" ]; then
  flutter run -d macos --enable-experiment=primary-constructors "${@:2}"
elif [ "$target" = "chrome" ]; then
  flutter run -d chrome --enable-experiment=primary-constructors "${@:2}"
elif [ "$target" = "android" ]; then
  flutter run --enable-experiment=primary-constructors "$@"
else
  flutter run --enable-experiment=primary-constructors "$@"
fi
