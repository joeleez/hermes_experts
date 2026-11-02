#!/usr/bin/env bash
# fix-perms.sh — 修正專家目錄權限（容器內 agent 是 uid 10000）
#
# 症狀：agent 說「讀不到 /opt/bootstrap/expert/.env（Permission denied）」
# 原因：宿主目錄是 700 root，容器內的 hermes(10000) 進不去
# 做法：把 private/experts/<name> 交給 10000:10000，.env 600、其餘 644/755
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

for name in $(list_experts); do
  d="$EXPERTS/$name"
  chown -R 10000:10000 "$d" 2>/dev/null || { warn "$name：chown 失敗（需要 root）"; continue; }
  find "$d" -type d -exec chmod 755 {} + 2>/dev/null || true
  find "$d" -type f ! -name ".env" -exec chmod 644 {} + 2>/dev/null || true
  [ -f "$d/.env" ] && chmod 600 "$d/.env"
  ok "$name 權限已修正"
done
