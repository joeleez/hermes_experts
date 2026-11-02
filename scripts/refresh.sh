#!/usr/bin/env bash
# refresh.sh — 把最新的知識與名冊套用到正在運行的專家
#
# 為什麼要重啟：Hermes 在「啟動時」把 skills 載入記憶體。
# 只把檔案複製進容器（docker cp / 重跑 seed）不會讓它重讀 —— 實測踩過：
# 技能檔已是新版，專家仍照舊版回答（容器 06:46 啟動、技能檔 07:24 更新）。
#
# 所以這裡做兩件事：
#   1. 重生成名冊（peers.yaml 是即時掛載，內容更新後服務不用重啟就看得到）
#   2. 逐個重建容器 —— 開機的 seed 會重新複製 knowledge/ 與 expert/skills/
#      （marker 已存在，所以不會覆寫記憶與 SOUL）
#
# 用 --force-recreate 而不是 docker restart：檔案被重寫後 bind-mount 的 inode
# 會失效，restart 會直接 exit 127；重建才會重新解析掛載點。
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
  dc up -d --force-recreate "$name" >/dev/null 2>&1 || { bad "$name 重建失敗"; continue; }

  for _ in $(seq 1 30); do
    st="$(docker inspect "$c" --format '{{.State.Health.Status}}' 2>/dev/null || echo unknown)"
    [ "$st" = "healthy" ] && break
    sleep 2
  done

  n="$(docker exec "$c" sh -c "awk '/^- name:/{n++} END{print (n>0?n-1:0)}' /opt/data/peers.yaml" 2>/dev/null)"
  ok "$name 已重建（其他專家 ${n:-?} 位，知識已重新載入）"
done
