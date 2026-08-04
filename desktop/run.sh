#!/bin/bash
# WaveLink — 一条命令启动项目

cd "$(dirname "$0")"
echo "🧹 清理旧进程..."
pkill -f "wavelink" 2>/dev/null
pkill -f "vite" 2>/dev/null
sleep 1

echo "🚀 启动 WaveLink..."
cargo tauri dev
