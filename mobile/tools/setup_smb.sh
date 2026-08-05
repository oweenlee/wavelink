#!/bin/bash
# ============================================================
# WaveLink 移动端 SMB 联调一键配置（仅限本机开发调试）
#
# 用法：sudo bash mobile/tools/setup_smb.sh
#
# 做的事：
#   1. 创建共享目录 /Users/qin/Public/music 并发布为共享名 music
#   2. 给已有的 smbtest 专用账户设置固定密码 wavelink123
#   3. 把 smbtest 加入 SMB 访问白名单（com.apple.access_smb）
#
# 完成后 App NAS Settings 已预填全部配置，直接点 Test Connection。
# 注意：密码为调试用途硬编码，勿用于任何真实环境。
# ============================================================
set -e

if [ "$EUID" -ne 0 ]; then
  echo "错误：需要 sudo 运行 →  sudo bash mobile/tools/setup_smb.sh"
  exit 1
fi

SHARE_DIR="/Users/qin/Public/music"
SHARE_NAME="music"
SMB_USER="smbtest"
SMB_PASS="wavelink123"

# 1. 共享目录（755 保证其他用户可读）
mkdir -p "$SHARE_DIR"
chmod 755 "$SHARE_DIR"

# 2. 发布共享（已存在则跳过）
if sharing -l | grep -qE "name:[[:space:]]+$SHARE_NAME"; then
  echo "[skip] 共享 $SHARE_NAME 已存在"
else
  sharing -a "$SHARE_DIR" -S "$SHARE_NAME" -s 001
  echo "[ok] 已创建共享 $SHARE_NAME → $SHARE_DIR"
fi

# 3. 确认 smbtest 账户存在
if ! dscl . -read "/Users/$SMB_USER" >/dev/null 2>&1; then
  echo "错误：用户 $SMB_USER 不存在，请先在系统设置中创建"
  exit 1
fi

# 4. 设置 SMB 专用密码
# 注意：共享面板创建的"仅限共享"账户用 dscl . -passwd 写入不会生效
# （AuthenticationAuthority 缺失，SMB 认证必失败），必须用 passwd 交互式设置。
if dscl . -read "/Users/$SMB_USER" AuthenticationAuthority >/dev/null 2>&1; then
  echo "[skip] $SMB_USER 已有密码；如需重置请手动运行： sudo passwd $SMB_USER"
else
  echo "请为 $SMB_USER 设置密码（建议输入两次 $SMB_PASS）："
  passwd "$SMB_USER"
fi

# 5. 加入 SMB 访问白名单（若系统启用了白名单模式）
if dscl . -read /Groups/com.apple.access_smb >/dev/null 2>&1; then
  if ! dscl . -read /Groups/com.apple.access_smb GroupMembership | grep -qw "$SMB_USER"; then
    dseditgroup -o edit -a "$SMB_USER" -t user com.apple.access_smb
    echo "[ok] $SMB_USER 已加入 SMB 访问白名单"
  else
    echo "[skip] $SMB_USER 已在白名单"
  fi
fi

IP=$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || echo "<本机IP>")
echo ""
echo "========== 配置完成 =========="
echo "Host     : $IP"
echo "Share    : /$SHARE_NAME"
echo "Username : $SMB_USER"
echo "Password : $SMB_PASS"
echo "=============================="
echo "把音乐文件放进 $SHARE_DIR，然后在 App 里点 Test Connection。"
