#!/usr/bin/env bash
# doctor.sh — 逐位專家體檢（單容器 / N 個 profile）
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
need_docker

FAIL=0
C="hermes-experts"
EXPS="$(list_experts)"

if [ -z "$EXPS" ]; then
  warn "還沒有任何專家（./hh new）"
  exit 0
fi

if docker ps --format '{{.Names}}' | grep -qx "$C"; then
  st="$(docker inspect "$C" --format '{{.State.Health.Status}}' 2>/dev/null)"
  [ "$st" = "healthy" ] && ok "容器 $C healthy" || warn "容器 health=$st"
else
  bad "容器 $C 未啟動（./hh start）"
  exit 1
fi

if docker exec "$C" sh -c "grep -q 'multiplex_profiles: true' /opt/data/config.yaml" 2>/dev/null; then
  ok "multiplex_profiles=true（一個進程服務所有 profile）"
else
  bad "multiplex_profiles 未開啟"
  FAIL=1
fi

for name in $EXPS; do
  printf '\n%s%s%s  (%s)\n' "$C_B" "$name" "$C_0" "$(expert_field "$name" title)"
  P="/opt/data/profiles/$name"

  if docker exec "$C" test -d "$P" 2>/dev/null; then
    ok "profile 已建立"
  else
    bad "profile 不存在（./hh refresh）"
    FAIL=1
    continue
  fi

  pid="$(docker exec "$C" sh -c "grep -h '^FEISHU_APP_ID=' $P/.env 2>/dev/null | cut -d= -f2" || true)"
  if [ -n "$pid" ]; then
    ok "專屬 Feishu App（${pid:0:12}…）"
  else
    bad "缺 FEISHU_APP_ID"
    FAIL=1
  fi

  rm_val="$(docker exec "$C" sh -c "grep -h '^FEISHU_REQUIRE_MENTION=' $P/.env | cut -d= -f2" || true)"
  [ "$rm_val" = "true" ] && ok "require_mention=true（只被 @ 才回應）" || { bad "require_mention=$rm_val"; FAIL=1; }

  ab="$(docker exec "$C" sh -c "grep -h '^FEISHU_ALLOW_BOTS=' $P/.env | cut -d= -f2" || true)"
  [ "$ab" = "none" ] && ok "allow_bots=none" || warn "allow_bots=${ab:-未設定}"

  docker exec "$C" test -d "$P/skills/group-protocol" 2>/dev/null \
    && ok "共用知識 group-protocol" || { bad "缺 group-protocol"; FAIL=1; }
  docker exec "$C" test -d "$P/skills/expert-self" 2>/dev/null \
    && ok "共用知識 expert-self" || { bad "缺 expert-self"; FAIL=1; }

  # 共用知識副本是否與來源一致（不一致＝過期或有專家動過）
  drift=0
  for kdir in group-protocol expert-self; do
    src="$(docker exec "$C" sh -c "md5sum /opt/bootstrap/knowledge/$kdir/SKILL.md 2>/dev/null | cut -d' ' -f1")"
    dst="$(docker exec "$C" sh -c "md5sum $P/skills/$kdir/SKILL.md 2>/dev/null | cut -d' ' -f1")"
    [ -n "$src" ] && [ "$src" != "$dst" ] && drift=1
  done
  [ "$drift" = "0" ] && ok "共用知識與來源一致" || warn "共用知識與來源不同（./hh refresh 可同步）"

  if docker exec "$C" test -f "$P/identity.yaml" 2>/dev/null; then
    docker exec "$C" sh -c "grep -q '^role: expert' $P/identity.yaml" \
      && ok "identity role=expert" || { bad "identity 缺 role"; FAIL=1; }
  else
    bad "缺 identity.yaml"
    FAIL=1
  fi

  docker exec "$C" test -f "$P/SOUL.md" 2>/dev/null && ok "SOUL.md（人格）" || { bad "缺 SOUL.md"; FAIL=1; }

  n="$(docker exec "$C" sh -c "awk '/^- name:/{n++} END{print (n>0?n-1:0)}' /opt/data/peers.yaml" 2>/dev/null)"
  ok "peers.yaml（其他專家 ${n:-?} 位）"

  if docker exec -u hermes "$C" sh -c "test -r /opt/bootstrap/experts/$name/.env" 2>/dev/null; then
    ok "agent 可讀 secrets"
  else
    bad "agent 讀不到 secrets（./hh fix-perms）"
    FAIL=1
  fi
  if docker exec -u hermes "$C" sh -c "test -w /opt/bootstrap/experts/$name/expert.yml" 2>/dev/null; then
    ok "agent 可寫自己的 expert.yml"
  else
    warn "agent 不能寫 expert.yml（職責無法自我更新；./hh fix-perms）"
  fi
done

echo
n_conn="$(docker logs "$C" --since 60m 2>&1 | grep -c "connected to wss://" || true)"
if [ "${n_conn:-0}" -gt 0 ]; then
  ok "飛書 WebSocket 連線紀錄 $n_conn 次（最近 60 分鐘）"
else
  warn "最近 60 分鐘沒有連線紀錄（可能只是沒重啟）"
fi

printf '\n'
[ "$FAIL" -eq 0 ] && printf '%s全部通過%s\n' "$C_OK" "$C_0" || printf '%s有項目未通過%s\n' "$C_BAD" "$C_0"
exit "$FAIL"
