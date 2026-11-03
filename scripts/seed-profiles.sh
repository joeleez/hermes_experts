#!/bin/bash
# seed-profiles.sh — s6 cont-init：把 private/experts/* 變成同一個容器內的 N 個 profile
#
# 為什麼用 profile 而不是 N 個容器：
#   每個 profile 有自己的 .env（飛書憑證）、config.yaml、SOUL.md、skills/、memories/，
#   但共用同一個 gateway 進程（gateway.multiplex_profiles: true）。
#   憑證仍然互不相通 —— multiplexer 會用「該 profile 自己的憑證」啟動該 profile 的平台。
#
# 三個踩過的坑：
#   1. s6 會清空環境變數 → 從 /run/s6/container_environment 還原
#   2. 官方 01-hermes-setup 會先塞預設 SOUL/config → 用 marker 判斷首次
#   3. bind-mount 來源檔不存在時 docker 會建成目錄 → 由 gen-compose.sh 先建立
set -euo pipefail

if [ -d /run/s6/container_environment ]; then
  for f in /run/s6/container_environment/*; do
    [ -f "$f" ] || continue
    export "$(basename "$f")=$(cat "$f")"
  done
fi

H="${HERMES_HOME:-/opt/data}"
SRC="${EXPERTS_DIR:-/opt/bootstrap/experts}"
K="${KNOWLEDGE_DIR:-/opt/bootstrap/knowledge}"
log() { echo "[seed-profiles] $*"; }

mkdir -p "$H/profiles"

# ── 0. 預設 profile 開啟 multiplex ──────────────────────
cat > "$H/config.yaml" <<YAML
# 由 seed-profiles.sh 產生：一個進程服務所有 profile
model:
  default: "${HERMES_MODEL:-}"

gateway:
  multiplex_profiles: true
  bot_loop_guard:
    enabled: true
    max_events: 20
    window_seconds: 300
    cooldown_seconds: 600

security:
  redact_secrets: true
YAML
log "config.yaml：multiplex_profiles=true（model=${HERMES_MODEL:-未設定}）"

# ── 1. 逐個 expert → profile ────────────────────────────
[ -d "$SRC" ] || { log "找不到 $SRC，結束"; exit 0; }

for d in "$SRC"/*/; do
  [ -f "${d}expert.yml" ] || continue
  NAME="$(basename "$d")"
  P="$H/profiles/$NAME"
  MARKER="$P/.seeded-by-hermes-experts"

  # 1a. 建立 profile（已存在就跳過）
  if [ ! -d "$P" ]; then
    # 用絕對路徑：cont-init 的 PATH 不含 .venv/bin（實測 hermes 找不到）
    if ERRTXT="$(HERMES_HOME="$H" PATH="/opt/hermes/.venv/bin:$PATH" \
                 /opt/hermes/.venv/bin/hermes profile create "$NAME" 2>&1)"; then
      log "$NAME：profile 已建立"
    else
      log "$NAME：profile 建立失敗 → $(printf '%s' "$ERRTXT" | tail -2 | tr '\n' ' ')"
      continue
    fi
  fi
  mkdir -p "$P/skills" "$P/memories"

  # 1b. 憑證 → profile 的 .env（每次刷新）
  TMP="$P/.env.tmp"
  : > "$TMP"
  # 共用金鑰（模型）
  for v in DEEPSEEK_API_KEY OPENAI_API_KEY ANTHROPIC_API_KEY OPENROUTER_API_KEY \
           GOOGLE_API_KEY XAI_API_KEY; do
    val="${!v:-}"
    [ -n "$val" ] && printf '%s=%s\n' "$v" "$val" >> "$TMP"
  done
  # 該專家的 app 憑證（從 private/experts/<name>/.env）
  if [ -f "${d}.env" ]; then
    while IFS= read -r line; do
      case "$line" in
        FEISHU_APP_ID=*|FEISHU_APP_SECRET=*|FEISHU_DOMAIN=*|FEISHU_CONNECTION_MODE=*|\
        FEISHU_GROUP_POLICY=*|FEISHU_ALLOWED_USERS=*|HERMES_MODEL=*|[A-Z_]*_TOKEN=*|\
        [A-Z_]*_PASSWORD=*|[A-Z_]*_KEY=*)
          printf '%s\n' "$line" >> "$TMP" ;;
      esac
    done < "${d}.env"
  fi
  # 該 profile 的行為設定
  # FEISHU_DOMAIN 必須明確寫入：缺少時 lark_oapi 會用中國域名連海外 App，
  # 錯誤訊息是「1000040351: Incorrect domain name」（實際踩過）。
  DOMAIN_VAL="$(awk -F= '/^FEISHU_DOMAIN=/{print $2}' "${d}.env" 2>/dev/null | tail -1)"
  DOMAIN_VAL="${DOMAIN_VAL:-${FEISHU_DOMAIN:-lark}}"
  {
    printf 'AGENT_NAME=%s\n' "$NAME"
    printf 'FEISHU_DOMAIN=%s\n' "$DOMAIN_VAL"
    printf 'FEISHU_CONNECTION_MODE=websocket\n'
    printf 'FEISHU_GROUP_POLICY=open\n'
    printf 'FEISHU_REQUIRE_MENTION=true\n'
    printf 'FEISHU_ALLOW_BOTS=none\n'
  } >> "$TMP"
  mv "$TMP" "$P/.env"
  chmod 600 "$P/.env"

  # 1c. config.yaml（模型可被 expert.yml 的 model: 覆蓋）
  MODEL="$(awk '/^model:/{print $2}' "${d}expert.yml" 2>/dev/null || true)"
  MODEL="${MODEL:-${HERMES_MODEL:-}}"
  cat > "$P/config.yaml" <<YAML
# 由 seed-profiles.sh 產生
model:
  default: "${MODEL}"

memory:
  memory_enabled: true
  user_profile_enabled: true
  memory_char_limit: 2200
YAML

  # 1d. 首次：SOUL.md（之後保留專家自己改的版本）
  if [ ! -f "$MARKER" ]; then
    [ -f "${d}SOUL.md" ] && cp "${d}SOUL.md" "$P/SOUL.md" && log "$NAME：SOUL.md 已套用"
    for f in MEMORY USER; do
      [ -f "$P/memories/$f.md" ] || printf '# %s\n\n（首次啟動建立，尚無內容。）\n' "$f" > "$P/memories/$f.md"
    done
    date -u +%Y-%m-%dT%H:%M:%SZ > "$MARKER"
  else
    log "$NAME：已 seed 過（$(cat "$MARKER")），保留記憶與 SOUL"
  fi

  # 1e. 共用知識（每次覆寫）
  if [ -d "$K" ]; then
    for kd in "$K"/*/; do
      [ -d "$kd" ] || continue
      skill="$(basename "$kd")"
      rm -rf "$P/skills/$skill"
      cp -r "$kd" "$P/skills/$skill"
    done
  fi

  # 1f. 專屬技能（每次覆寫）
  if [ -d "${d}skills" ]; then
    for sd in "${d}skills"/*/; do
      [ -d "$sd" ] || continue
      skill="$(basename "$sd")"
      rm -rf "$P/skills/$skill"
      cp -r "$sd" "$P/skills/$skill"
      log "$NAME：專屬技能 $skill"
    done
  fi

  # 1g. 身份檔（每次重寫）
  /opt/hermes/.venv/bin/python - "${d}expert.yml" "$P" "$H" <<'PY' || log "$NAME：identity 產生失敗"
import os, sys
import yaml

cfg_path, pdir, home = sys.argv[1], sys.argv[2], sys.argv[3]
me = yaml.safe_load(open(cfg_path, encoding="utf-8")) or {}

peers = []
peers_path = os.path.join(home, "peers.yaml")
if os.path.exists(peers_path):
    peers = yaml.safe_load(open(peers_path, encoding="utf-8")) or []
peers = [p for p in peers if p.get("name") != me.get("name")]

identity = {
    "agent": me.get("name", os.path.basename(pdir)),
    "title": me.get("title", ""),
    "role": "expert",
    "summary": me.get("summary", ""),
    "strengths": me.get("strengths") or [],
    "capabilities": me.get("capabilities") or [],
    "cannot": me.get("cannot") or [],
    "require_mention": True,
    "peers_source": "/opt/data/peers.yaml（每次讀都是最新）",
    "peers_detail": peers,
}
with open(os.path.join(pdir, "identity.yaml"), "w", encoding="utf-8") as fh:
    fh.write("# 由 seed-profiles.sh 每次啟動產生，請勿手改\n")
    yaml.safe_dump(identity, fh, allow_unicode=True, sort_keys=False)
PY
  log "$NAME：identity.yaml（$(grep '^title:' "$P/identity.yaml" 2>/dev/null | cut -d' ' -f2-)）"
done

# ── 2. 權限 ────────────────────────────────────────────
chown -R hermes:hermes "$H" 2>/dev/null || true

log "完成：$(ls -d "$H"/profiles/*/ 2>/dev/null | wc -l) 個 profile"
