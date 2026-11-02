#!/usr/bin/env bash
# add-expert.sh — 新增一位專家（互動式；也可用參數自動化）
#
# 互動用法： ./scripts/add-expert.sh
# 自動用法： ./scripts/add-expert.sh --name mpf --title "MPF專家" \
#              --summary "強積金對帳" --strengths "強積金,對帳" \
#              --app-id cli_xxx --app-secret yyy [--no-start]
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
need_docker

NAME=""; TITLE=""; SUMMARY=""; STRENGTHS=""; APP_ID=""; APP_SECRET=""; DO_START=1

while [ $# -gt 0 ]; do
  case "$1" in
    --name) NAME="$2"; shift 2 ;;
    --title) TITLE="$2"; shift 2 ;;
    --summary) SUMMARY="$2"; shift 2 ;;
    --strengths) STRENGTHS="$2"; shift 2 ;;
    --app-id) APP_ID="$2"; shift 2 ;;
    --app-secret) APP_SECRET="$2"; shift 2 ;;
    --no-start) DO_START=0; shift ;;
    *) bad "未知參數：$1"; exit 1 ;;
  esac
done

ASK() {  # ASK <變數名> <提示> <是否秘密>
  local __var="$1" __prompt="$2" __secret="${3:-0}" __val=""
  if [ -n "${!__var}" ]; then return 0; fi
  while :; do
    if [ "$__secret" = "1" ]; then
      read -rsp "$__prompt" __val; echo
    else
      read -rp "$__prompt" __val
    fi
    [ -n "$__val" ] && break
    warn "不能留空"
  done
  printf -v "$__var" '%s' "$__val"
}

hr; printf '%s新增專家%s\n' "$C_B" "$C_0"; hr

ASK NAME "英文代號（小寫，例：mpf）: "
[[ "$NAME" =~ ^[a-z][a-z0-9_-]*$ ]] || { bad "代號只能小寫字母開頭，含 a-z 0-9 - _"; exit 1; }
[ -e "$EXPERTS/$NAME" ] && { bad "private/experts/$NAME 已存在"; exit 1; }

ASK TITLE "群裡顯示的名稱（例：MPF專家）: "
ASK SUMMARY "一句話簡介（其他專家靠這句話決定該不該建議找你）: "
if [ -z "$STRENGTHS" ]; then
  read -rp "專長（逗號分隔，可留空）: " STRENGTHS || true
fi

echo
hr
printf '%s現在需要在飛書後台建一個自建應用%s\n' "$C_B" "$C_0"
cat <<'TXT'
  最快：open.larksuite.com/app 首頁 →「創建 Lark 智能體 應用」→ 立即創建
        （一鍵設好機器人能力與權限），然後：
          1. 應用名稱填上面的顯示名稱
          2. 檢查事件訂閱方式是「長連線」
          3. 建立版本 → 發布

  若沒有那張卡片，手動做：
          1. 建立企業自建應用 → 名稱填顯示名稱
          2. 添加「機器人」能力
          3. 權限：im:message、im:chat:readonly
          4. 事件訂閱：im.message.receive_v1（長連線）
          5. 建立版本 → 發布
TXT
hr
read -rp "完成後按 Enter 繼續…" _ || true

ASK APP_ID "App ID: "
ASK APP_SECRET "App Secret（輸入不顯示）: " 1

# ── 驗證憑證（打錯字就立刻知道，不留半成品）────────────
echo
ID="$APP_ID" SEC="$APP_SECRET" DOMAIN="$(grep -E '^FEISHU_DOMAIN=' "$ROOT/.env" 2>/dev/null | cut -d= -f2 || echo lark)" \
python3 - <<'PY'
import json, os, sys, urllib.error, urllib.request
app_id, secret = os.environ["ID"], os.environ["SEC"]
domain = os.environ.get("DOMAIN") or "lark"
base = "https://open.larksuite.com" if domain.startswith("lark") else "https://open.feishu.cn"
try:
    req = urllib.request.Request(
        base + "/open-apis/auth/v3/tenant_access_token/internal",
        data=json.dumps({"app_id": app_id, "app_secret": secret}).encode(),
        headers={"Content-Type": "application/json"})
    tok = json.load(urllib.request.urlopen(req, timeout=20))["tenant_access_token"]
    req = urllib.request.Request(base + "/open-apis/bot/v3/info",
                                 headers={"Authorization": "Bearer " + tok})
    bot = json.load(urllib.request.urlopen(req, timeout=20)).get("bot", {})
    print(f"  \033[32m✓\033[0m 憑證可用，飛書應用名稱：{bot.get('app_name','(未知)')}")
except urllib.error.HTTPError as e:
    print(f"  \033[31m✗\033[0m 憑證驗證失敗 HTTP {e.code}（App ID/Secret 錯，或應用未發布）")
    sys.exit(1)
except Exception as e:
    print(f"  \033[31m✗\033[0m 無法連上飛書：{e}")
    sys.exit(1)
PY

# ── 建立專家目錄 ────────────────────────────────────────
D="$EXPERTS/$NAME"
mkdir -p "$D/skills"

export E_NAME="$NAME" E_TITLE="$TITLE" E_SUMMARY="$SUMMARY" E_STR="$STRENGTHS"
python3 - "$ROOT/templates/expert.yml.template" "$D/expert.yml" <<'PY'
import os, sys, datetime
tpl, out = sys.argv[1], sys.argv[2]
text = open(tpl, encoding="utf-8").read()
now = datetime.datetime.now().strftime("%Y-%m-%d")
text = (text.replace("__NAME__", os.environ["E_NAME"])
            .replace("__TITLE__", os.environ["E_TITLE"])
            .replace("__SUMMARY__", os.environ["E_SUMMARY"])
            .replace("__CREATED_AT__", now))
strengths = [s.strip() for s in os.environ["E_STR"].replace("，", ",").split(",") if s.strip()]
if strengths:
    block = "\n".join(f"  - {s}" for s in strengths)
    text = text.replace("  - __STRENGTH_1__", block)
else:
    text = text.replace("  - __STRENGTH_1__\n", "")
open(out, "w", encoding="utf-8").write(text)
PY

python3 - "$ROOT/templates/SOUL.md.template" "$D/SOUL.md" \
         "$TITLE" "$SUMMARY" <<'PY'
import sys
tpl, out, title, summary = sys.argv[1:5]
text = open(tpl, encoding="utf-8").read()
open(out, "w", encoding="utf-8").write(
    text.replace("__TITLE__", title).replace("__SUMMARY__", summary))
PY

cat > "$D/.env" <<ENV
AGENT_NAME=$NAME
FEISHU_APP_ID=$APP_ID
FEISHU_APP_SECRET=$APP_SECRET
ENV
chmod 600 "$D/.env"

# 專家目錄必須讓「容器內的 hermes（uid 10000）」讀寫：
#   讀 .env 拿憑證、寫 expert.yml 更新自己的職責。
# 用 700 root 會讓 agent 得到 Permission denied（實際踩過）。
# 宿主 root 不受權限限制，所以 ./hh 仍然寫得進去。
chown -R 10000:10000 "$D" 2>/dev/null || true
chmod 755 "$D" "$D/skills" 2>/dev/null || true
chmod 644 "$D/SOUL.md" "$D/expert.yml" 2>/dev/null || true
chmod 600 "$D/.env"

ok "private/experts/$NAME/（expert.yml、SOUL.md、skills/、.env）"

# ── 共享 .env 檢查 ──────────────────────────────────────
if [ ! -f "$ROOT/.env" ]; then
  cp "$ROOT/.env.example" "$ROOT/.env"
  chmod 600 "$ROOT/.env"
  warn "已建立 .env（從 .env.example）—— 記得填 DEEPSEEK_API_KEY，否則專家無法思考"
fi

# ── 生成名冊與 service ──────────────────────────────────
./scripts/gen-peers.sh
./scripts/gen-compose.sh

if [ "$DO_START" = "1" ]; then
  echo
  dc up -d "$NAME"
  echo
  printf '等待連線'
  for i in $(seq 1 30); do
    sleep 2; printf '.'
    if docker logs "hermes-$NAME" --since 2m 2>&1 | grep -q "connected to wss://"; then
      echo; ok "Feishu websocket 已連線"; break
    fi
    [ "$i" = "30" ] && { echo; warn "60 秒內未看到連線，看 ./hh logs $NAME"; }
  done
fi

# ── 下一步 ──────────────────────────────────────────────
echo
hr
printf '%s下一步%s\n' "$C_B" "$C_0"
cat <<TXT
  1. 群設定 → 群組機械人 → 添加機械人 → 搜尋「$TITLE」→ 加入
  2. 在群裡打：@$TITLE 你好
  3. 回到終端機：./hh sync        （記錄它在哪些群）

  之後你可以直接在群裡告訴它「你負責什麼、照什麼步驟做」，
  它會自己寫回 private/experts/$NAME/expert.yml。
TXT
hr
