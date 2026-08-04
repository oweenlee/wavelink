#!/usr/bin/env bash
set -euo pipefail

APP_NAME="WaveLink"
ENGINE_DIR="../core"

usage() {
    echo "用法: ./build.sh <command>"
    echo ""
    echo "命令:"
    echo "  dev             开发模式 (Vite + Tauri)"
    echo "  build:web       仅构建前端 (vite build)"
    echo "  build:macos     构建 macOS DMG"
    echo "  build:windows   构建 Windows MSI (需 Windows)"
    echo "  build:linux     构建 Linux AppImage/deb (需 Linux)"
    echo "  test            运行前端测试"
    echo "  lint            检查前端代码"
    echo "  install:front   安装前端依赖 (npm ci)"
    echo "  engine:test     运行引擎测试"
    echo "  engine:build    构建引擎"
    echo "  engine:docs     生成引擎文档 (cargo doc)"
    echo "  check           完整检查: lint + 前端测试 + 引擎测试"
    echo "  clean           清理构建产物"
}

# ── 平台判断 ──
case "$(uname -s)" in
    Darwin)  OS="macos" ;;
    Linux)   OS="linux" ;;
    MINGW*|MSYS*|CYGWIN*) OS="windows" ;;
    *)       OS="unknown" ;;
esac

case "${1:-help}" in
    dev)
        echo "==> 启动开发模式 (Tauri dev server)"
        npm run tauri dev
        ;;
    build:web)
        echo "==> 构建前端 (vite)"
        npm run build
        ;;
    build:macos)
        echo "==> 构建 macOS DMG"
        if [ "$OS" != "macos" ]; then
            echo "错误: 仅支持 macOS" >&2
            exit 1
        fi
        npm run tauri build
        echo "==> DMG 位于: src-tauri/target/release/bundle/dmg/"
        ;;
    build:windows)
        echo "==> 构建 Windows MSI"
        if [ "$OS" != "windows" ]; then
            echo "错误: 仅支持 Windows" >&2
            exit 1
        fi
        npm run tauri build -- --bundles msi
        echo "==> MSI 位于: src-tauri/target/release/bundle/msi/"
        ;;
    build:linux)
        echo "==> 构建 Linux (deb + AppImage)"
        if [ "$OS" != "linux" ]; then
            echo "错误: 仅支持 Linux" >&2
            exit 1
        fi
        npm run tauri build
        echo "==> 安装包位于: src-tauri/target/release/bundle/"
        ;;
    test)
        echo "==> 运行前端测试"
        npm run test
        ;;
    lint)
        echo "==> 检查前端代码"
        npm run lint
        ;;
    install:front)
        echo "==> 安装前端依赖"
        npm ci
        ;;
    engine:test)
        echo "==> 运行引擎测试"
        if [ ! -d "$ENGINE_DIR" ]; then
            echo "错误: 未找到引擎目录 ($ENGINE_DIR)" >&2
            exit 1
        fi
        (cd "$ENGINE_DIR" && cargo test)
        ;;
    engine:build)
        echo "==> 构建引擎"
        if [ ! -d "$ENGINE_DIR" ]; then
            echo "错误: 未找到引擎目录 ($ENGINE_DIR)" >&2
            exit 1
        fi
        # path 依赖下，在 src-tauri workspace 内构建会自动编译 audio-core
        echo "引擎在 app 构建时自动编译，无需单独构建"
        (cd "$ENGINE_DIR" && cargo build --release)
        ;;
    engine:docs)
        echo "==> 生成引擎文档"
        if [ ! -d "$ENGINE_DIR" ]; then
            echo "错误: 未找到引擎目录 ($ENGINE_DIR)" >&2
            exit 1
        fi
        (cd "$ENGINE_DIR" && cargo doc --no-deps --document-private-items)
        echo "==> 文档位于: $ENGINE_DIR/target/doc/"
        ;;
    check)
        echo "==> 完整检查"
        echo "--- 前端 lint ---"
        npm run lint
        echo "--- 前端测试 ---"
        npm run test
        echo "--- 引擎测试 ---"
        if [ -d "$ENGINE_DIR" ]; then
            (cd "$ENGINE_DIR" && cargo t)
        else
            echo "跳过引擎测试 (未找到引擎目录)"
        fi
        echo "==> 全部通过"
        ;;
    clean)
        echo "==> 清理构建产物"
        rm -rf build/ .svelte-kit/
        if [ -d "src-tauri/target" ]; then
            (cd src-tauri && cargo clean)
        fi
        echo "清理完成"
        ;;
    help|*)
        usage
        ;;
esac
