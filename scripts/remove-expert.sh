#!/usr/bin/env bash
# remove-expert.sh — 停止並移除一位專家
#
# 預設「保留記憶」（volume 留著），加 --purge 才刪 volume 與檔案。
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
need_docker

NAME="${1:-}"
PURGE=0
[ "${2:-}" = "--purge" ] && PURGE=1
[ -n "$NAME" ] || { bad "用法：$0 <name> [--purge]"; exit 1; }
[ -d "$EXPERTS/$NAME" ] || { bad "找不到 private/experts/$NAME"; exit 1; }

echo "即將處理專家：$NAME"
[ "$PURGE" = "1" ] && echo "  ⚠ --purge：會刪除記憶 volume（不可復原）"
read -rp "確定？(yes/N) " ans
[ "$ans" = "yes" ] || { echo "取消"; exit 0; }

dc stop "$NAME" 2>/dev/null || true
dc rm -f "$NAME" 2>/dev/null || true

if [ "$PURGE" = "1" ]; then
  docker volume rm "hermes-$NAME-data" 2>/dev/null || true
  rm -rf "${EXPERTS:?}/$NAME"
  ok "已刪除容器、volume、private/experts/$NAME"
else
  ok "已停止容器（記憶保留在 hermes-$NAME-data）"
  dim "  目錄仍在 private/experts/$NAME —— 要移除請加 --purge"
fi

./scripts/gen-peers.sh >/dev/null 2>&1 || true
./scripts/gen-compose.sh >/dev/null 2>&1 || true
dim "  名冊與 compose 已重新生成"
