#!/usr/bin/env bash
# refresh.sh — 套用最新知識與名冊（重建主容器）
#
# 為什麼要重建：Hermes 在「進程啟動時」把 skills 載入記憶體，
# 只把檔案複製進容器不會讓它重讀（實際踩過）。
# 單容器模式下所有 profile 一起重啟，中斷約 20 秒。
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
need_docker

./scripts/gen-peers.sh
./scripts/gen-compose.sh >/dev/null
dc up -d --force-recreate

for _ in $(seq 1 40); do
  st="$(docker inspect hermes-experts --format '{{.State.Health.Status}}' 2>/dev/null || echo unknown)"
  [ "$st" = "healthy" ] && break
  sleep 2
done
ok "hermes-experts 已重建（$(docker exec hermes-experts sh -c 'ls -d /opt/data/profiles/*/ 2>/dev/null | wc -l') 個 profile 已載入）"
