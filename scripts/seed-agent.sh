#!/bin/bash
# seed-agent.sh — s6 cont-init 鉤子（容器內以 root 執行，服務啟動前）
#
# 三個踩過的坑，這裡都處理了：
#   1. s6 在執行 cont-init 前會清空環境變數 → 從 /run/s6/container_environment rehydrate
#   2. 官方 01-hermes-setup 會先塞自己的 SOUL.md / config.yaml → 用 marker 判斷首次啟動
#   3. bind-mount 的來源檔若不存在，docker 會建成目錄 → 由 gen-compose.sh 先建立空檔
set -euo pipefail

if [ -d /run/s6/container_environment ]; then
  for f in /run/s6/container_environment/*; do
    [ -f "$f" ] || continue
    export "$(basename "$f")=$(cat "$f")"
  done
fi

NAME="${AGENT_NAME:?AGENT_NAME 未設定}"
H="${HERMES_HOME:-/opt/data}"
K="/opt/bootstrap/knowledge"
E="/opt/bootstrap/expert"
MARKER="$H/.seeded-by-hermes-experts"

log() { echo "[seed:$NAME] $*"; }

mkdir -p "$H/skills" "$H/memories"

# ── 1. 首次啟動：套用性格與設定 ─────────────────────────
if [ ! -f "$MARKER" ]; then
  log "首次啟動"

  if [ -f "$E/SOUL.md" ]; then
    cp "$E/SOUL.md" "$H/SOUL.md"
    log "SOUL.md ← expert/SOUL.md"
  else
    log "警告：找不到 $E/SOUL.md"
  fi

  for f in MEMORY USER; do
    [ -f "$H/memories/$f.md" ] || printf '# %s\n\n（首次啟動建立，尚無內容。）\n' "$f" > "$H/memories/$f.md"
  done

  cat > "$H/config.yaml" <<YAML
# 由 seed-agent.sh 產生（首次啟動）。之後可自由編輯；
# 要重新產生請刪 $MARKER 後重啟。
model:
  default: "${HERMES_MODEL:-}"

memory:
  memory_enabled: true
  user_profile_enabled: true
  memory_char_limit: 2200

gateway:
  multiplex_profiles: false
  bot_loop_guard:
    enabled: true
    max_events: 20
    window_seconds: 300
    cooldown_seconds: 600

security:
  redact_secrets: true
YAML
  log "config.yaml 已寫入（model=${HERMES_MODEL:-未設定}）"
  date -u +%Y-%m-%dT%H:%M:%SZ > "$MARKER"
else
  log "已 seed 過（$(cat "$MARKER")），保留記憶"
fi

# ── 2. 共用知識（每次啟動覆寫，確保與 repo 同步）─────────
if [ -d "$K" ]; then
  for d in "$K"/*/; do
    [ -d "$d" ] || continue
    skill="$(basename "$d")"
    rm -rf "${H:?}/skills/$skill"
    cp -r "$d" "$H/skills/$skill"
  done
  log "共用知識：$(ls "$K" | tr '\n' ' ')"
fi

# ── 3. 專家專屬技能（每次啟動覆寫，來源是宿主 private/）──
if [ -d "$E/skills" ]; then
  for d in "$E"/skills/*/; do
    [ -d "$d" ] || continue
    skill="$(basename "$d")"
    rm -rf "${H:?}/skills/$skill"
    cp -r "$d" "$H/skills/$skill"
    log "專屬技能：$skill"
  done
fi

# ── 4. 憑證 → $H/.env（每次刷新）────────────────────────
TMP="$H/.env.tmp"
: > "$TMP"
n=0
for v in DEEPSEEK_API_KEY OPENAI_API_KEY ANTHROPIC_API_KEY OPENROUTER_API_KEY \
         GOOGLE_API_KEY XAI_API_KEY \
         FEISHU_APP_ID FEISHU_APP_SECRET FEISHU_DOMAIN FEISHU_CONNECTION_MODE \
         FEISHU_GROUP_POLICY FEISHU_REQUIRE_MENTION FEISHU_ALLOW_BOTS; do
  val="${!v:-}"
  if [ -n "$val" ]; then
    printf '%s=%s\n' "$v" "$val" >> "$TMP"
    n=$((n + 1))
  fi
done
mv "$TMP" "$H/.env"
chmod 600 "$H/.env" 2>/dev/null || true
log ".env（$n 個變數）"

# ── 5. 名冊：其他專家（每次刷新）────────────────────────
if [ -f /opt/bootstrap/peers.yaml ]; then
  cp /opt/bootstrap/peers.yaml "$H/peers.yaml"
  log "peers.yaml（$(grep -c '^- name:' "$H/peers.yaml" 2>/dev/null || echo 0) 位專家）"
fi

# ── 7. 我是誰（每次重寫）────────────────────────────────
if [ -f "$E/expert.yml" ]; then
  /opt/hermes/.venv/bin/python - "$E/expert.yml" "$H" <<'PY' || log "警告：identity.yaml 產生失敗"
import os, sys
import yaml

cfg_path, home = sys.argv[1], sys.argv[2]
me = yaml.safe_load(open(cfg_path, encoding="utf-8")) or {}

peers = []
peers_path = os.path.join(home, "peers.yaml")
if os.path.exists(peers_path):
    peers = yaml.safe_load(open(peers_path, encoding="utf-8")) or []
peers = [p for p in peers if p.get("name") != me.get("name")]

identity = {
    "agent": me.get("name", ""),
    "title": me.get("title", ""),
    "role": "expert",
    "summary": me.get("summary", ""),
    "strengths": me.get("strengths") or [],
    "capabilities": me.get("capabilities") or [],
    "cannot": me.get("cannot") or [],
    "require_mention": True,
    "peers": [p.get("name") for p in peers],
    "peers_detail": peers,
}
with open(os.path.join(home, "identity.yaml"), "w", encoding="utf-8") as fh:
    fh.write("# 由 seed-agent.sh 每次啟動產生，請勿手改\n")
    yaml.safe_dump(identity, fh, allow_unicode=True, sort_keys=False)
PY
  log "identity.yaml 已寫入（$(grep '^title:' "$H/identity.yaml" 2>/dev/null | cut -d' ' -f2-)）"
fi

# ── 8. 權限 ──────────────────────────────────────────────
id hermes >/dev/null 2>&1 && chown -R hermes:hermes "$H" 2>/dev/null || true

log "完成"
