#!/usr/bin/env bash
# hh — Hermes 專家系統的唯一入口
#
#   ./hh             互動選單
#   ./hh new         新增專家
#   ./hh list        列出專家（狀態、在哪個群）
#   ./hh sync        重新掃描群組
#   ./hh refresh     套用技能更新（名冊已即時同步，不需這步）
#   ./hh doctor      體檢
#   ./hh logs <n>    看日誌
#   ./hh secret <n> "<說明>" <KEY_NAME> [值]
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

  # 群組即時查詢：用每位專家自己的憑證問飛書「我在哪些群」
  # 不落地成檔案，所以「把專家拉進群」之後不需要跑任何指令。
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

  printf '\n%s%-12s %-18s %-10s %s%s\n' "$C_B" "代號" "群裡名稱" "容器" "所在群" "$C_0"
  hr
  for n in $exps; do
    local title status groups
    title="$(expert_field "$n" title)"
    if docker ps --format '{{.Names}}' | grep -qx "hermes-$n"; then
      status="$(docker inspect "hermes-$n" --format '{{.State.Health.Status}}' 2>/dev/null)"
      [ "$status" = "healthy" ] && status="${C_OK}運行中${C_0}" || status="${C_WARN}$status${C_0}"
    else
      status="${C_DIM}已停止${C_0}"
    fi
    groups="$(printf '%s\n' "$gmap" | awk -F'\t' -v k="$n" '$1==k{print $2}')"
    printf '%-12s %-18s %-10b %s\n' "$n" "$title" "$status" "${groups:-?}"
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
  # 用法：./hh secret <專家> <說明> <KEY_NAME> <KEY>
  #   例：./hh secret developer "NGB 專案的 Git Token" NGB_GIT_TOKEN ghp_xxxxx
  # 省略 KEY 時會以隱藏輸入方式詢問（適合不想讓值出現在 shell history 的情況）
  local name="${1:-}" desc="${2:-}" key="${3:-}" val="${4:-}"
  if [ -z "$name" ] || [ -z "$desc" ] || [ -z "$key" ]; then
    bad '用法：./hh secret <專家> "<說明>" <KEY_NAME> [KEY]'
    dim '  例：./hh secret developer "NGB 專案的 Git Token" NGB_GIT_TOKEN ghp_xxxxx'
    dim '  省略 KEY 則以隱藏輸入詢問（不進 shell history）'
    return 1
  fi
  [ -f "$EXPERTS/$name/.env" ] || { bad "找不到 private/experts/$name/.env"; return 1; }
  [[ "$key" =~ ^[A-Z][A-Z0-9_]*$ ]] || { bad "KEY_NAME 要大寫字母開頭，只含 A-Z 0-9 _（例：NGB_GIT_TOKEN）"; return 1; }

  if [ -z "$val" ]; then
    read -rsp "輸入 $key 的值（不顯示）: " val; echo
    [ -n "$val" ] || { bad "空值，取消"; return 1; }
  fi

  SECRET_VAL="$val" SECRET_DESC="$desc" SECRET_KEY="$key" \
    python3 - "$EXPERTS/$name/.env" <<'PY'
import os, sys
path = sys.argv[1]
key = os.environ["SECRET_KEY"]
desc = os.environ["SECRET_DESC"]
val = os.environ["SECRET_VAL"]

lines = open(path, encoding="utf-8").read().splitlines()
out, skip_next = [], False
for line in lines:
    if skip_next:            # 舊說明行
        skip_next = False
        continue
    if line.strip() == f"# {desc}":
        skip_next = True
        continue
    if line.startswith(key + "="):
        continue
    out.append(line)

while out and not out[-1].strip():
    out.pop()
out.append(f"# {desc}")
out.append(f"{key}={val}")
open(path, "w", encoding="utf-8").write("\n".join(out) + "\n")
PY
  unset val SECRET_VAL SECRET_DESC SECRET_KEY
  chmod 600 "$EXPERTS/$name/.env"
  ok "$key 已寫入 private/experts/$name/.env（說明：$desc）"
  # 不用重啟：.env 是整份目錄掛載，專家需要時直接讀 /opt/bootstrap/expert/.env
  dim "  專家讀取方式：grep '^$key=' /opt/bootstrap/expert/.env | cut -d= -f2-"
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
 3) 套用技能更新（改了 knowledge/ 之後）
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
      3) ./scripts/refresh.sh ;;
      4) ./scripts/doctor.sh ;;
      5) read -rp "專家代號: " n; cmd_logs "$n" ;;
      6) read -rp "專家代號: " n
         read -rp "這條密碼是做什麼的（說明）: " d
         read -rp "KEY_NAME（大寫，例 NGB_GIT_TOKEN）: " k
         cmd_secret "$n" "$d" "$k" ;;
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
  sync)          cmd_list ;;   # 群組已改為即時查詢，sync 保留為相容別名
  refresh)       ./scripts/refresh.sh ;;
  doctor)        ./scripts/doctor.sh ;;
  logs)          cmd_logs "${2:-}" ;;
  secret)        cmd_secret "${2:-}" "${3:-}" "${4:-}" "${5:-}" ;;
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
