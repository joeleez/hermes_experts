#!/usr/bin/env bash
# hh — Hermes 專家系統的唯一入口
#
#   ./hh             互動選單
#   ./hh new         新增專家
#   ./hh list        列出專家（狀態、在哪個群）
#   ./hh sync        重新掃描群組
#   ./hh refresh     熱更新名冊（不用重啟）
#   ./hh doctor      體檢
#   ./hh logs <n>    看日誌
#   ./hh secret <n> <變數名>
#   ./hh approve <n> [配對碼]
#   ./hh start|stop|restart <n> | restart-all
#   ./hh rm <n>      移除專家（保留記憶）
#   ./hh update      拉新版框架並重建
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source scripts/lib/common.sh

cmd_list() {
  need_docker
  local exps; exps="$(list_experts)"
  [ -z "$exps" ] && { warn "還沒有專家（./hh new）"; return 0; }

  printf '\n%s%-12s %-16s %-10s %s%s\n' "$C_B" "代號" "群裡名稱" "容器" "所在群" "$C_0"
  hr
  for n in $exps; do
    local title status groups base
    title="$(expert_field "$n" title)"
    if docker ps --format '{{.Names}}' | grep -qx "hermes-$n"; then
      status="$(docker inspect "hermes-$n" --format '{{.State.Health.Status}}' 2>/dev/null)"
      [ "$status" = "healthy" ] && status="${C_OK}運行中${C_0}" || status="${C_WARN}$status${C_0}"
    else
      status="${C_DIM}已停止${C_0}"
    fi
    groups="$(python3 - "$GROUPS" "$n" <<'PY' 2>/dev/null || true
import sys, yaml, os
p, name = sys.argv[1], sys.argv[2]
if not os.path.exists(p): print("-"); raise SystemExit
rows = yaml.safe_load(open(p, encoding="utf-8")) or []
hits = [r.get("name") or r.get("chat_id") for r in rows if name in (r.get("experts") or [])]
print(", ".join(hits) if hits else "-")
PY
)"
    printf '%-12s %-16s %-10b %s\n' "$n" "$title" "$status" "$groups"
  done
  printf '\n'
}

cmd_approve() {
  local name="${1:-}" code="${2:-}"
  [ -n "$name" ] || { bad "用法：./hh approve <專家> <配對碼>"; return 1; }
  local c="hermes-$name"
  docker ps --format '{{.Names}}' | grep -qx "$c" || { bad "$c 未啟動"; return 1; }
  if [ -z "$code" ]; then
    dim "$name 目前待批准的請求："
    docker exec -e HERMES_HOME=/opt/data "$c" hermes pairing list 2>&1 | sed 's/^/    /'
    read -rp "配對碼（專家在飛書給你那個 8 位碼）: " code
  fi
  [ -n "$code" ] || { bad "沒有配對碼"; return 1; }
  docker exec -e HERMES_HOME=/opt/data "$c" hermes pairing approve feishu "$code" 2>&1 | tail -3
  docker exec -e HERMES_HOME=/opt/data "$c" hermes pairing list 2>&1 | tail -6
}

cmd_secret() {
  local name="${1:-}" var="${2:-}"
  [ -n "$name" ] && [ -n "$var" ] || { bad "用法：./hh secret <專家> <變數名>（例：./hh secret mpf DB_PASSWORD）"; return 1; }
  [ -f "$EXPERTS/$name/.env" ] || { bad "找不到 private/experts/$name/.env"; return 1; }
  local val
  read -rsp "輸入 $var 的值（不顯示）: " val; echo
  [ -n "$val" ] || { bad "空值，取消"; return 1; }
  SECRET_VAL="$val" python3 - "$EXPERTS/$name/.env" "$var" <<'PY'
import os, sys
path, var = sys.argv[1], sys.argv[2]
val = os.environ["SECRET_VAL"]
lines = [l for l in open(path, encoding="utf-8").read().splitlines() if not l.startswith(var + "=")]
lines.append(f"{var}={val}")
open(path, "w", encoding="utf-8").write("\n".join(lines) + "\n")
PY
  unset val SECRET_VAL
  chmod 600 "$EXPERTS/$name/.env"
  ok "$var 已寫入 private/experts/$name/.env"
  # env_file 在建立容器時讀取 → 必須重建
  dc up -d --force-recreate "$name" >/dev/null 2>&1 && ok "容器已重建以載入新變數"
  dim "  專家可用 printenv $var 取得，不需經過對話"
}

cmd_logs() {
  local name="${1:-}"
  [ -n "$name" ] || { bad "用法：./hh logs <專家>"; return 1; }
  docker logs -f --tail 80 "hermes-$name"
}

cmd_update() {
  need_docker
  git pull --ff-only || { bad "git pull 失敗（請先處理本地改動）"; return 1; }
  ./scripts/gen-peers.sh
  ./scripts/gen-compose.sh
  docker compose -f "$BASE_COMPOSE" -f "$GEN_COMPOSE" build
  for n in $(list_experts); do
    dc up -d --force-recreate "$n"
  done
  ok "已更新並重建所有專家"
}

menu() {
  while :; do
    echo
    printf '%s Hermes 專家系統 %s\n' "$C_B" "$C_0"
    hr
    cat <<'TXT'
 1) 新增專家
 2) 列出專家
 3) 群組同步（哪些群、哪些專家在裡面）
10) 熱更新名冊（新專家加入後，讓所有人馬上認識它）
 4) 體檢
 5) 看日誌
 6) 設定專家密碼
 7) 批核飛書使用者（配對碼）
 8) 重啟全部
 9) 移除專家
 0) 離開
TXT
    hr
    read -rp "請選擇: " choice || exit 0
    case "$choice" in
      1) ./scripts/add-expert.sh ;;
      2) cmd_list ;;
      3) ./scripts/sync-groups.sh ;;
      10) ./scripts/refresh.sh ;;
      4) ./scripts/doctor.sh ;;
      5) read -rp "專家代號: " n; cmd_logs "$n" ;;
      6) read -rp "專家代號: " n; read -rp "變數名: " v; cmd_secret "$n" "$v" ;;
      7) read -rp "專家代號: " n; cmd_approve "$n" ;;
      8) for n in $(list_experts); do dc up -d --force-recreate "$n" >/dev/null 2>&1 && ok "重啟 $n"; done ;;
      9) read -rp "專家代號: " n; ./scripts/remove-expert.sh "$n" ;;
      0) exit 0 ;;
      *) warn "沒有這個選項" ;;
    esac
    echo
    read -rp "按 Enter 回主選單…" _ || true
  done
}

case "${1:-}" in
  "")            menu ;;
  new)           ./scripts/add-expert.sh ;;
  list|ls)       cmd_list ;;
  sync)          ./scripts/sync-groups.sh ;;
  refresh)       ./scripts/refresh.sh ;;
  doctor)        ./scripts/doctor.sh ;;
  logs)          cmd_logs "${2:-}" ;;
  secret)        cmd_secret "${2:-}" "${3:-}" ;;
  approve)       cmd_approve "${2:-}" "${3:-}" ;;
  start)         dc up -d "${2:?需要專家代號}" ;;
  stop)          dc stop "${2:?需要專家代號}" ;;
  restart)       dc up -d --force-recreate "${2:?需要專家代號}" ;;
  restart-all)   for n in $(list_experts); do dc up -d --force-recreate "$n" >/dev/null && ok "重啟 $n"; done ;;
  rm)            ./scripts/remove-expert.sh "${2:-}" "${3:-}" ;;
  update)        cmd_update ;;
  -h|--help|help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//' ;;
  *)             bad "未知指令：$1（./hh --help）"; exit 1 ;;
esac
