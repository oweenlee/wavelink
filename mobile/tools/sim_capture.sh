#!/bin/bash
# App Store 截图宿主抓屏器（模拟器）
#
# 配合 integration_test/capture_screens_test.dart：
#   测试导航到目标屏 → 写 Documents/.cap_ready_<tag> → 等 Documents/.cap_done_<tag>
#   本脚本看到 ready 后用 simctl 抓真实屏幕，再写 done 放行。
#
# 用法: tools/sim_capture.sh <UDID> [输出目录] [演示音乐目录]
set -u

UDID="${1:?用法: tools/sim_capture.sh <UDID> [outdir] [musicdir]}"
OUT="${2:-build/asc-captures}"
MUSIC="${3:-$HOME/Desktop/WaveLink-Demo-Pack/music}"
BUNDLE="com.wavelink.player"
TIMEOUT="${CAPTURE_TIMEOUT:-1200}"

mkdir -p "$OUT"

# 单实例锁：两个实例会互相覆盖同一张截图
LOCK="$OUT/.capture.lock"
if ! mkdir "$LOCK" 2>/dev/null; then
  echo "[capture] 已有实例在运行，退出"
  exit 1
fi
trap 'rmdir "$LOCK" 2>/dev/null || true' EXIT

echo "[capture] udid=$UDID out=$OUT music=$MUSIC"

resolve_docs() {
  local c
  c=$(xcrun simctl get_app_container "$UDID" "$BUNDLE" data 2>/dev/null)
  if [ -n "$c" ] && [ -d "$c/Documents" ]; then
    echo "$c/Documents"
  fi
}

docs=""
deadline=$(( $(date +%s) + TIMEOUT ))
while [ -z "$docs" ]; do
  docs=$(resolve_docs)
  [ -n "$docs" ] && break
  [ "$(date +%s)" -ge "$deadline" ] && { echo "[capture] 超时：未找到 app 容器"; exit 2; }
  sleep 0.5
done
echo "[capture] documents=$docs"

SEEN=""
while [ "$(date +%s)" -lt "$deadline" ]; do
  # app 被重装后容器路径会变，失效则重新解析
  if [ ! -d "$docs" ]; then
    docs=$(resolve_docs)
    [ -z "$docs" ] && { sleep 0.5; continue; }
    echo "[capture] documents(re-resolved)=$docs"
  fi

  found=0
  for f in "$docs"/.shotreq_*; do
    [ -e "$f" ] || continue
    tag=$(basename "$f" | sed 's/^\.shotreq_//')
    # 同一个标记只处理一次：测试删标记有延迟，否则会二次抓拍覆盖前一张
    case "$SEEN" in
      *"|$tag|"*) continue ;;
    esac
    SEEN="$SEEN|$tag|"
    found=1
    if [ "$tag" = "seed" ]; then
      echo "[capture $(date +%T)] seed → 拷贝演示 FLAC"
      mkdir -p "$docs/Imported"
      cp "$MUSIC"/*.flac "$docs/Imported/" 2>/dev/null
      echo "[capture $(date +%T)] seeded $(ls "$docs/Imported" 2>/dev/null | wc -l | tr -d ' ') 个文件"
    else
      sleep 0.45
      if xcrun simctl io "$UDID" screenshot --type=png "$OUT/$tag.png" >/dev/null 2>&1; then
        w=$(sips -g pixelWidth "$OUT/$tag.png" 2>/dev/null | awk '/pixelWidth/{print $2}')
        h=$(sips -g pixelHeight "$OUT/$tag.png" 2>/dev/null | awk '/pixelHeight/{print $2}')
        echo "[capture $(date +%T)] shot $tag  ${w}x${h}"
      else
        echo "[capture $(date +%T)] FAILED shot $tag"
      fi
    fi
    touch "$docs/.shotack_$tag"
  done

  if [ "$found" = "0" ]; then
    sleep 0.2
  fi
done

echo "[capture] 结束（超时或完成）"
ls -la "$OUT"
