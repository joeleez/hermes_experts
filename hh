#!/usr/bin/env bash
# hh — Hermes 專家系統的唯一入口（單容器，N 個 profile）
#
#   ./hh             互動選單
#   ./hh new         新增專家
#   ./hh list        列出專家（狀態、在哪個群）
#   ./hh doctor      體檢
#   ./hh refresh [--now|--later]  套用變更（會問你立即或排到定時）
#   ./hh fix-perms   修正專家目錄權限
#   ./hh logs [n]    看日誌（可只看某位專家）
#   ./hh secret_create <n> "<說明>" <KEY_NAME> [值]
#   ./hh secret_update <n> <KEY_NAME> [值] [--desc "<新說明>"]
#   ./hh secret_delete <n> <KEY_NAME>
#   ./hh secret_list   <n>
#   ./hh approve <n> [配對碼]
#   ./hh start|stop|restart
#   ./hh rm <n>      移除專家（保留記憶）
#   ./hh schedule [HH:MM|off]  設定每日定時重啟
#   ./hh admin       後台管理員是否在運作（心跳）
#   ./hh update      拉新版框架並重建
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source scripts/lib/common.sh

C="hermes-experts"   # 唯一的主容器（內含所有 profile）

container_up() { docker ps --format '{{.Names}}' | grep -qx "$C"; }
profile_exists() { docker exec "$C" test -d "/opt/data/profiles/$1" 2>/dev/null; }

# 把 private/experts 的變更同步到各 profile（.env、SOUL、技能、identity）
sync_profiles() {
  container_up || return 0
  docker exec -u 0 "$C" /etc/cont-init.d/99-seed-profiles >/dev/null 2>&1 || true
}

cmd_list() {
  need_docker
  local exps; exps="$(list_experts)"
  [ -z "$exps" ] && { warn "還沒有專家（./hh new）"; return 0; }

  local up="否"; container_up && up="是"

  # 群組即時查詢：用每位專家自己的憑證問飛書「我在哪些群」
  local gmap; gmap="$(python3 - "$EXPERTS" "$ROOT" <<'PY' 2>/dev/null
import json, os, sys, urllib.error, urllib.request
experts_dir, root = sys.argv[1], sys.argv[2]

def load_env(path, base):
    d = dict(base)
    if os.path.exists(path):
        for line in open(path, encoding="utf-8"):
            s = line.strip()
            if s and not s.startswith("#") and "=" in s:
                k, v = s.split("=", 1)
                d[k.strip()] = v.strip()
    return d

shared = load_env(os.path.join(root, ".env"), {})
for name in sorted(os.listdir(experts_dir)):
    cfg = os.path.join(experts_dir, name, "expert.yml")
    if not os.path.isfile(cfg):
        continue
    env = load_env(os.path.join(experts_dir, name, ".env"), shared)
    app_id, secret = env.get("FEISHU_APP_ID", ""), env.get("FEISHU_APP_SECRET", "")
    if not app_id or not secret:
        print(f"{name}\t(憑證缺失)"); continue
    base = "https://open.larksuite.com" if (env.get("FEISHU_DOMAIN") or "lark").startswith("lark") \
        else "https://open.feishu.cn"
    try:
        req = urllib.request.Request(
            base + "/open-apis/auth/v3/tenant_access_token/internal",
            data=json.dumps({"app_id": app_id, "app_secret": secret}).encode(),
            headers={"Content-Type": "application/json"})
        tok = json.load(urllib.request.urlopen(req, timeout=15))["tenant_access_token"]
        req = urllib.request.Request(base + "/open-apis/im/v1/chats?page_size=100",
                                     headers={"Authorization": "Bearer " + tok})
        items = json.load(urllib.request.urlopen(req, timeout=15)).get("data", {}).get("items", []) or []
        names = [i.get("name") or i.get("chat_id") for i in items]
        print(f"{name}\t{', '.join(names) if names else '未加入任何群'}")
    except urllib.error.HTTPError as e:
        print(f"{name}\t(查詢失敗 HTTP {e.code})")
    except Exception:
        print(f"{name}\t(連不上飛書)")
PY
)"

  printf '\n%s%-12s %-18s %-12s %s%s\n' "$C_B" "代號" "群裡名稱" "profile" "所在群" "$C_0"
  hr
  for n in $exps; do
    local title st groups
    title="$(expert_field "$n" title)"
    if [ "$up" = "是" ] && profile_exists "$n"; then
      st="${C_OK}已載入${C_0}"
    elif [ "$up" = "是" ]; then
      st="${C_WARN}未載入${C_0}"
    else
      st="${C_DIM}容器停${C_0}"
    fi
    groups="$(printf '%s\n' "$gmap" | awk -F'\t' -v k="$n" '$1==k{print $2}')"
    printf '%-12s %-18s %-12b %s\n' "$n" "$title" "$st" "${groups:-?}"
  done
  printf '\n%s容器：%s（%s）%s\n' "$C_DIM" "$C" "$([ "$up" = "是" ] && echo 運行中 || echo 已停止)" "$C_0"
  printf '\n'
}

cmd_approve() {
  local name="${1:-}" code="${2:-}"
  [ -n "$name" ] || { bad "用法：./hh approve <專家> [配對碼]"; return 1; }
  container_up || { bad "$C 未啟動（./hh start）"; return 1; }
  if [ -z "$code" ]; then
    dim "$name 目前待批准的請求："
    docker exec -e HERMES_HOME=/opt/data "$C" hermes -p "$name" pairing list 2>&1 | sed 's/^/    /'
    read -rp "配對碼（專家在飛書給你那個 8 位碼）: " code
  fi
  [ -n "$code" ] || { bad "沒有配對碼"; return 1; }
  docker exec -e HERMES_HOME=/opt/data "$C" hermes -p "$name" pairing approve feishu "$code" 2>&1 | tail -3
  docker exec -e HERMES_HOME=/opt/data "$C" hermes -p "$name" pairing list 2>&1 | tail -6
}

cmd_secret_create() {
  local name="${1:-}" desc="${2:-}" key="${3:-}" val="${4:-}"
  if [ -z "$name" ] || [ -z "$desc" ] || [ -z "$key" ]; then
    bad '用法：./hh secret_create <專家> "<說明>" <KEY_NAME> [值]'
    dim '  例：./hh secret_create developer "NGB 專案的 Git Token" NGB_GIT_TOKEN'
    return 1
  fi
  [ -f "$EXPERTS/$name/.env" ] || { bad "找不到 private/experts/$name/.env"; return 1; }
  if [ -z "$val" ]; then
    read -rsp "輸入 $key 的值（不顯示）: " val; echo
    [ -n "$val" ] || { bad "空值，取消"; return 1; }
  fi
  python3 scripts/secrets.py create "$EXPERTS/$name/.env" "$key" "$desc" "$val" && sync_profiles
}

cmd_secret_update() {
  local name="${1:-}" key="${2:-}"; shift 2 2>/dev/null || shift $# 2>/dev/null || true
  local val="" desc=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --desc) desc="${2:-}"; shift 2 2>/dev/null || shift ;;
      *) [ -z "$val" ] && val="$1"; shift ;;
    esac
  done
  if [ -z "$name" ] || [ -z "$key" ]; then
    bad '用法：./hh secret_update <專家> <KEY_NAME> [值] [--desc "<新說明>"]'
    return 1
  fi
  [ -f "$EXPERTS/$name/.env" ] || { bad "找不到 private/experts/$name/.env"; return 1; }
  if [ -z "$val" ] && [ -z "$desc" ]; then
    read -rsp "輸入 $key 的新值（不顯示）: " val; echo
    [ -n "$val" ] || { bad "空值，取消"; return 1; }
  fi
  python3 scripts/secrets.py update "$EXPERTS/$name/.env" "$key" "$desc" "$val" && sync_profiles
}

cmd_secret_delete() {
  local name="${1:-}" key="${2:-}"
  [ -n "$name" ] && [ -n "$key" ] || { bad '用法：./hh secret_delete <專家> <KEY_NAME>'; return 1; }
  [ -f "$EXPERTS/$name/.env" ] || { bad "找不到 private/experts/$name/.env"; return 1; }
  read -rp "確定刪除 $name 的 $key？(yes/N) " ans
  [ "$ans" = "yes" ] || { echo "取消"; return 0; }
  python3 scripts/secrets.py delete "$EXPERTS/$name/.env" "$key" && sync_profiles
}

cmd_secret_list() {
  local name="${1:-}"
  [ -n "$name" ] || { bad "用法：./hh secret_list <專家>"; return 1; }
  [ -f "$EXPERTS/$name/.env" ] || { bad "找不到 private/experts/$name/.env"; return 1; }
  python3 scripts/secrets.py list "$EXPERTS/$name/.env"
}

cmd_logs() {
  local name="${1:-}"
  if [ -n "$name" ]; then
    docker logs -f --tail 100 "$C" 2>&1 | grep --line-buffered -i "$name"
  else
    docker logs -f --tail 100 "$C"
  fi
}

cmd_update() {
  need_docker
  git pull --ff-only || { bad "git pull 失敗（請先處理本地改動）"; return 1; }
  ./scripts/gen-peers.sh
  ./scripts/gen-compose.sh
  docker compose -f "$BASE_COMPOSE" -f "$GEN_COMPOSE" build
  dc up -d --force-recreate
  ok "已更新並重建 $C（所有 profile 一起重啟）"
}

menu() {
  while :; do
    echo
    printf '%s Hermes 專家系統 %s\n' "$C_B" "$C_0"
    hr
    cat <<'TXT'
 1) 新增專家
 2) 列出專家
 3) 套用技能更新（改了 knowledge/ 之後）
 4) 體檢
 5) 看日誌
 6) 管理專家密碼（新增／更新／刪除／列出）
 7) 批核飛書使用者（配對碼）
 8) 重啟容器（所有專家）
 9) 移除專家
 0) 離開
TXT
    hr
    read -rp "請選擇: " choice || exit 0
    case "$choice" in
      1) ./scripts/add-expert.sh ;;
      2) cmd_list ;;
      3) ./scripts/refresh.sh ;;
      4) ./scripts/doctor.sh ;;
      5) read -rp "專家代號（可留空看全部）: " n; cmd_logs "$n" ;;
      6) read -rp "專家代號: " n
         read -rp "動作（1=新增 2=更新 3=刪除 4=列出）: " act
         case "$act" in
           1) read -rp "說明（這條密碼做什麼）: " d
              read -rp "KEY_NAME（大寫，例 NGB_GIT_TOKEN）: " k
              cmd_secret_create "$n" "$d" "$k" ;;
           2) read -rp "KEY_NAME: " k; cmd_secret_update "$n" "$k" ;;
           3) read -rp "KEY_NAME: " k; cmd_secret_delete "$n" "$k" ;;
           4) cmd_secret_list "$n" ;;
           *) warn "沒有這個選項" ;;
         esac ;;
      7) read -rp "專家代號: " n; cmd_approve "$n" ;;
      8) dc restart ;;
      9) read -rp "專家代號: " n; ./scripts/remove-expert.sh "$n" ;;
      10) read -rp "每日重啟時間（HH:MM，留空=取消）: " tm
          if [ -z "$tm" ]; then ./scripts/schedule.sh off; else ./scripts/schedule.sh "$tm"; fi ;;
      0) exit 0 ;;
      *) warn "沒有這個選項" ;;
    esac
    echo
    read -rp "按 Enter 回主選單…" _ || true
  done
}


# ── 後台管理員（建立這套系統的 agent）存活狀態 ───────────────
HB="$ROOT/private/.admin-heartbeat"
cmd_admin() {
  if [ "${1:-}" = "beat" ]; then
    mkdir -p "$(dirname "$HB")"
    local _note="${2:-}"
    # 沒帶說明時沿用上一次的說明（排程心跳不會蓋掉真正的工作紀錄）
    if [ -z "$_note" ] && [ -f "$HB" ]; then _note=$(sed -n 2p "$HB"); fi
    { date +%s; printf '%s\n' "$_note"; } > "$HB"
    ok "心跳已更新"
    return 0
  fi
  local now ts age note
  now=$(date +%s)
  printf '\n%s\n' "後台管理員（Hermes · WSL 那側）"
  if [ ! -f "$HB" ]; then
    warn "沒有心跳紀錄 —— 可能從未啟動，或心跳排程沒跑"
    printf '  %s\n' "（./hh admin beat 可手動打一次）"
    return 0
  fi
  ts=$(sed -n 1p "$HB" | tr -dc '0-9')
  note=$(sed -n 2p "$HB")
  [ -n "$ts" ] || { warn "心跳檔格式不對：$HB"; return 0; }
  age=$(( now - ts ))
  printf '  最後心跳：%s（%s）\n' "$(date -d "@$ts" '+%Y-%m-%d %H:%M')" "$(human_age "$age")"
  if [ "$age" -lt 600 ]; then
    printf '  狀態：%s\n' "運作中"
  elif [ "$age" -lt 3600 ]; then
    printf '  狀態：%s\n' "閒置（沒有進行中的工作）"
  else
    printf '  狀態：%s\n' "未運作（超過一小時沒有心跳）"
  fi
  [ -n "$note" ] && printf '  上次工作：%s\n' "$note"
  printf '\n'
}

human_age() {
  local s=$1
  if [ "$s" -lt 90 ]; then printf '剛剛'
  elif [ "$s" -lt 5400 ]; then printf '%d 分鐘前' $(( s / 60 ))
  elif [ "$s" -lt 172800 ]; then printf '%d 小時前' $(( s / 3600 ))
  else printf '%d 天前' $(( s / 86400 )); fi
}

case "${1:-}" in
  "")            menu ;;
  new)           ./scripts/add-expert.sh ;;
  list|ls)       cmd_list ;;
  sync)          cmd_list ;;   # 相容別名（群組為即時查詢）
  refresh)       shift; ./scripts/refresh.sh "${1:-}" ;;
  doctor)        ./scripts/doctor.sh ;;
  logs)          cmd_logs "${2:-}" ;;
  secret_create) shift; cmd_secret_create "$@" ;;
  secret_update) shift; cmd_secret_update "$@" ;;
  secret_delete) shift; cmd_secret_delete "$@" ;;
  secret_list)   cmd_secret_list "${2:-}" ;;
  secret)        bad "./hh secret 已取消，改用 secret_create / secret_update / secret_delete" ;;
  approve)       cmd_approve "${2:-}" "${3:-}" ;;
  fix-perms)     ./scripts/fix-perms.sh ;;
  start)         dc up -d && ok "已啟動 $C" ;;
  stop)          dc stop && ok "已停止 $C" ;;
  restart)       dc restart && ok "已重啟 $C" ;;
  restart-all)   dc restart && ok "已重啟 $C" ;;
  rm)            ./scripts/remove-expert.sh "${2:-}" "${3:-}" ;;
  schedule)      ./scripts/schedule.sh "${2:-}" ;;
  admin)         shift; cmd_admin "${1:-}" "${2:-}" ;;
  update)        cmd_update ;;
  -h|--help|help) sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//' ;;
  *)             bad "未知指令：$1（./hh --help）"; exit 1 ;;
esac
