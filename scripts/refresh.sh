#!/usr/bin/env bash
# refresh.sh — 把名冊與身份熱更新到正在運行的容器（不用重啟）
#
# 為什麼需要：peers.yaml / identity.yaml 由 seed 在「容器開機」時生成。
# 新專家加入後，舊專家的 peers.yaml 還是舊的 —— 它會答「群裡只有我一個」。
# 這裡直接重跑容器內的 seed 腳本（marker 已存在，所以不會覆寫記憶與 SOUL）。
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
need_docker

./scripts/gen-peers.sh
echo
for name in $(list_experts); do
  c="hermes-$name"
  if ! docker ps --format '{{.Names}}' | grep -qx "$c"; then
    dim "$name 未啟動，跳過（下次啟動自動套用）"
    continue
  fi
  docker cp "$PEERS" "$c:/opt/bootstrap/peers.yaml" >/dev/null 2>&1 || true
  if docker exec -u 0 "$c" /etc/cont-init.d/99-seed-agent >/dev/null 2>&1; then
    n="$(docker exec "$c" sh -c "awk '/^- name:/{n++} END{print (n>0?n-1:0)}' /opt/data/peers.yaml" 2>/dev/null)"
    ok "$name 已更新（其他專家 $n 位）"
  else
    bad "$name 更新失敗"
  fi
done
