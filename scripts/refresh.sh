#!/usr/bin/env bash
# refresh.sh — 套用知識／設定變更（要不要現在重啟，由人決定）
#
# 為什麼要問：重啟會讓「所有專家」一起中斷（單容器、N 個 profile）。
# 所以提供兩種模式：
#   --now     立即重建容器，約 20 秒後全部專家回來
#   --later   什麼都不做 —— 變更已在磁碟上，等下一次定時重啟自動生效
#
# 無互動終端（例如排程）時預設 --later，避免半夜被自己重啟。
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
need_docker

MODE="${1:-}"
sched_time() {
  local line; line="$(crontab -l 2>/dev/null | grep -F 'hermes-experts daily restart' | head -1)"
  if [ -n "$line" ]; then
    set -- $line
    printf '%s:%s' "$2" "$1"
  else
    printf '未設定'
  fi
}

./scripts/gen-peers.sh >/dev/null
./scripts/gen-compose.sh >/dev/null

if [ -z "$MODE" ]; then
  if [ -t 0 ]; then
    echo
    printf '%s要如何套用？%s\n' "$C_B" "$C_0"
    cat <<TXT
  1) 立即套用   —— 重建容器，所有專家中斷約 20 秒後自動恢復
  2) 排到定時   —— 變更已寫入磁碟，等下次定時重啟生效（目前：$(sched_time)）
TXT
    read -rp "請選擇 [1/2，預設 2]: " ans
    case "$ans" in
      1) MODE="--now" ;;
      *) MODE="--later" ;;
    esac
  else
    MODE="--later"
  fi
fi

case "$MODE" in
  --now)
    dc up -d --force-recreate
    for _ in $(seq 1 40); do
      st="$(docker inspect hermes-experts --format '{{.State.Health.Status}}' 2>/dev/null || echo unknown)"
      [ "$st" = "healthy" ] && break
      sleep 2
    done
    n="$(docker exec hermes-experts sh -c 'ls -d /opt/data/profiles/*/ 2>/dev/null | wc -l')"
    ok "已立即套用：hermes-experts 已重建（$n 個 profile）"
    ;;
  --later)
    dim "變更已在磁碟上，等下次定時重啟生效（目前排程：$(sched_time)）"
    dim "  想現在就生效請跑：./hh refresh --now"
    ;;
  *)
    bad "未知參數：$MODE（用 --now 或 --later）"
    exit 1
    ;;
esac
