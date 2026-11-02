#!/usr/bin/env bash
# doctor.sh — 逐位專家體檢
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
need_docker

FAIL=0
EXPS="$(list_experts)"

if [ -z "$EXPS" ]; then
  warn "還沒有任何專家（./hh new 新增）"
  exit 0
fi

for name in $EXPS; do
  c="hermes-$name"
  printf '\n%s%s%s  (%s)\n' "$C_B" "$name" "$C_0" "$(expert_field "$name" title)"

  # 1. 檔案齊全
  for f in expert.yml SOUL.md .env; do
    [ -f "$EXPERTS/$name/$f" ] || { bad "缺 private/experts/$name/$f"; FAIL=1; }
  done
  [ -f "$EXPERTS/$name/expert.yml" ] && ok "檔案齊全"

  # 2. 容器
  if docker ps --format '{{.Names}}' | grep -qx "$c"; then
    st="$(docker inspect "$c" --format '{{.State.Health.Status}}' 2>/dev/null)"
    [ "$st" = "healthy" ] && ok "container healthy" || warn "container health=$st"
  else
    bad "container 未啟動（./hh start $name）"; FAIL=1; continue
  fi

  # 3. 連線
  if docker logs "$c" --since 30m 2>&1 | grep -q "connected to wss://"; then
    ok "Feishu websocket 已連線"
  else
    warn "最近 30 分鐘無連線紀錄（可能只是沒重啟）"
  fi

  # 4. 身份
  ident="$(docker exec "$c" cat /opt/data/identity.yaml 2>/dev/null)"
  if [ -n "$ident" ]; then
    printf '%s' "$ident" | grep -q '^role: expert' && ok "identity role=expert" || { bad "identity role 不對"; FAIL=1; }
    printf '%s' "$ident" | grep -q '^title: ' && ok "identity 有 title" || { bad "identity 缺 title"; FAIL=1; }
  else
    bad "缺 /opt/data/identity.yaml"; FAIL=1
  fi

  # 5. 技能
  docker exec "$c" test -d /opt/data/skills/group-protocol 2>/dev/null \
    && ok "共用知識 group-protocol" || { bad "缺 group-protocol"; FAIL=1; }
  docker exec "$c" test -d /opt/data/skills/expert-self 2>/dev/null \
    && ok "共用知識 expert-self" || { bad "缺 expert-self"; FAIL=1; }

  # 6. 准入設定
  rm_val="$(docker exec "$c" sh -c "grep -h '^FEISHU_REQUIRE_MENTION=' /opt/data/.env | cut -d= -f2" 2>/dev/null)"
  [ "$rm_val" = "true" ] && ok "require_mention=true（只被 @ 才回應）" || { bad "require_mention=$rm_val（應為 true）"; FAIL=1; }
  ab="$(docker exec "$c" sh -c "grep -h '^FEISHU_ALLOW_BOTS=' /opt/data/.env | cut -d= -f2" 2>/dev/null)"
  [ "$ab" = "none" ] && ok "allow_bots=none（不理其他 bot）" || warn "allow_bots=${ab:-未設定}"

  # 7. 憑證
  docker exec "$c" sh -c "grep -q '^FEISHU_APP_ID=cli_' /opt/data/.env" 2>/dev/null \
    && ok "App ID 已設定" || { bad "缺 App ID"; FAIL=1; }

  # 8. 名冊（peers.yaml 含自己，所以要扣掉）
  if docker exec "$c" test -f /opt/data/peers.yaml 2>/dev/null; then
    n="$(docker exec "$c" sh -c "awk '/^- name:/{n++} END{print (n>0?n-1:0)}' /opt/data/peers.yaml" 2>/dev/null)"
    ok "peers.yaml（其他專家 $n 位）"
  else
    warn "缺 peers.yaml（只影響「認識其他專家」）"
  fi
done

printf '\n'
[ "$FAIL" -eq 0 ] && printf '%s全部通過%s\n' "$C_OK" "$C_0" || printf '%s有項目未通過%s\n' "$C_BAD" "$C_0"
exit "$FAIL"
