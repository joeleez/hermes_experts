#!/usr/bin/env bash
# gen-compose.sh — 生成「單一容器 + N 個 profile」的 compose 檔
#
# 為什麼不再每個專家一個 service：一個 gateway 進程配 gateway.multiplex_profiles=true
# 就能服務所有 profile，而每個 profile 仍保有自己的憑證、技能、記憶、人格。
# 詳見 scripts/seed-profiles.sh。
#
# 產出：private/compose.experts.yml（不進 git）
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

mkdir -p "$EXPERTS"

# bind-mount 的來源檔若不存在，docker 會建成目錄 → 先確保存在
[ -f "$PEERS" ] || printf '# 尚無專家\n' > "$PEERS"
[ -f "$GROUPS" ] || printf '# 尚未生成（roster 服務啟動後會寫入）\n' > "$GROUPS"
mkdir -p "$ROOT/projects"

python3 - "$GEN_COMPOSE" <<'PY'
import sys
import yaml

out_path = sys.argv[1]

experts = {
    "build": {"context": "."},
    "image": "hermes-experts:local",
    "container_name": "hermes-experts",
    "restart": "unless-stopped",
    "command": ["gateway"],
    "env_file": [".env"],
    "environment": {
        "HERMES_HOME": "/opt/data",
        "FEISHU_REQUIRE_MENTION": "true",
        "FEISHU_ALLOW_BOTS": "none",
    },
    "volumes": [
        "experts-data:/opt/data",
        "./scripts/seed-profiles.sh:/etc/cont-init.d/99-seed-profiles:ro",
        "./knowledge:/opt/bootstrap/knowledge:ro",
        "./private/experts:/opt/bootstrap/experts",
        "./private/peers.yaml:/opt/data/peers.yaml",
        "./private/groups.yaml:/opt/data/groups.yaml:ro",
        # 專案資料夾：每個專案的產出檔（CSV、報告）都在這裡
        "./projects:/opt/data/projects",
    ],
    "networks": ["experts"],
    "stop_grace_period": "30s",
    "healthcheck": {
        "test": ["CMD-SHELL", "test -d /opt/data/profiles || exit 1"],
        "interval": "30s",
        "timeout": "5s",
        "retries": 3,
        "start_period": "90s",
    },
}

roster = {
    "build": {"context": "."},
    "image": "hermes-experts:local",
    "container_name": "hermes-roster",
    "restart": "unless-stopped",
    "entrypoint": ["/bin/sh", "/scripts/groups-watch.sh"],
    "volumes": [
        "./scripts:/scripts:ro",
        "./private/experts:/src:ro",
        "./private/groups.yaml:/out/groups.yaml",
    ],
    "networks": ["experts"],
    "environment": {"GROUPS_REFRESH_SECONDS": "60"},
}

doc = {
    "services": {"experts": experts, "roster": roster},
    "volumes": {"experts-data": {"name": "hermes-experts-data"}},
}

with open(out_path, "w", encoding="utf-8") as fh:
    fh.write("# 由 scripts/gen-compose.sh 生成，請勿手改（此檔不進 git）\n")
    yaml.safe_dump(doc, fh, allow_unicode=True, sort_keys=False, default_flow_style=False)
print("生成：1 個主容器（內含 N 個 profile）+ roster 服務")
PY

if docker compose -f "$BASE_COMPOSE" -f "$GEN_COMPOSE" config -q 2>/dev/null; then
  ok "compose 驗證通過"
else
  bad "compose 驗證失敗"
  docker compose -f "$BASE_COMPOSE" -f "$GEN_COMPOSE" config -q || true
  exit 1
fi
