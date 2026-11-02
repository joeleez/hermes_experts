#!/usr/bin/env bash
# common.sh — 所有腳本共用：路徑、顏色、compose 包裝
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PRIV="$ROOT/private"
EXPERTS="$PRIV/experts"
GEN_COMPOSE="$PRIV/compose.experts.yml"
PEERS="$PRIV/peers.yaml"
GROUPS="$PRIV/groups.yaml"
BASE_COMPOSE="$ROOT/docker-compose.base.yml"

if [ -t 1 ]; then
  C_OK=$'\033[32m'; C_BAD=$'\033[31m'; C_WARN=$'\033[33m'
  C_DIM=$'\033[2m'; C_B=$'\033[1m'; C_0=$'\033[0m'
else
  C_OK=''; C_BAD=''; C_WARN=''; C_DIM=''; C_B=''; C_0=''
fi

ok()   { printf '  %s✓%s %s\n' "$C_OK" "$C_0" "$*"; }
bad()  { printf '  %s✗%s %s\n' "$C_BAD" "$C_0" "$*"; }
warn() { printf '  %s!%s %s\n' "$C_WARN" "$C_0" "$*"; }
dim()  { printf '  %s%s%s\n' "$C_DIM" "$*" "$C_0"; }
hr()   { printf '%s\n' "────────────────────────────────────────────"; }

# 只在使用生成檔存在時才加 -f，否則 compose 會報錯
dc() {
  if [ -f "$GEN_COMPOSE" ]; then
    docker compose -f "$BASE_COMPOSE" -f "$GEN_COMPOSE" "$@"
  else
    docker compose -f "$BASE_COMPOSE" "$@"
  fi
}

# 列出所有專家代號（以目錄為準）
list_experts() {
  [ -d "$EXPERTS" ] || return 0
  for d in "$EXPERTS"/*/; do
    [ -f "${d}expert.yml" ] || continue
    basename "$d"
  done
}

expert_field() {  # expert_field <name> <key>
  python3 - "$EXPERTS/$1/expert.yml" "$2" <<'PY'
import sys
try:
    import yaml
except ImportError:
    sys.exit(2)
path, key = sys.argv[1], sys.argv[2]
d = yaml.safe_load(open(path, encoding="utf-8")) or {}
v = d.get(key, "")
if isinstance(v, list):
    print(", ".join(str(x) for x in v))
else:
    print(v)
PY
}

need_docker() {
  command -v docker >/dev/null 2>&1 || {
    bad "找不到 docker"
    exit 1
  }
  docker compose version >/dev/null 2>&1 || {
    bad "找不到 docker compose 外掛"
    exit 1
  }
}
