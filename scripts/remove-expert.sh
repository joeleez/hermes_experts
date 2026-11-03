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

# 刪掉容器內的 profile（記憶在 volume 裡，profile 目錄也一起移除）
docker exec hermes-experts hermes profile delete "$NAME" --force >/dev/null 2>&1 || true

if [ "$PURGE" = "1" ]; then
  rm -rf "${EXPERTS:?}/$NAME"
  ok "已刪除 profile、private/experts/$NAME（記憶一併移除）"
else
  ok "已移除 profile（記憶保留在 hermes-experts-data 內的殘留目錄）"
  dim "  目錄仍在 private/experts/$NAME —— 要移除請加 --purge"
fi

./scripts/gen-peers.sh >/dev/null 2>&1 || true
./scripts/gen-compose.sh >/dev/null 2>&1 || true
./scripts/refresh.sh >/dev/null 2>&1 || true
dim "  名冊已重新生成，容器已重建"
