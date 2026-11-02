#!/usr/bin/env bash
# gen-compose.sh — 從 private/experts/*/expert.yml 生成每個專家的 service
#
# 產出：private/compose.experts.yml（不進 git）
# 為什麼要生成而不是手寫：手寫就等於把「你有哪幾個專家」寫進 git 了。
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

mkdir -p "$EXPERTS"

# bind-mount 的來源檔若不存在，docker 會自動建成「目錄」，容器內就變成讀不到檔案。
# 所以先確保這兩個檔案存在。
[ -f "$PEERS" ] || printf '# 尚無專家\n' > "$PEERS"

python3 - "$EXPERTS" "$GEN_COMPOSE" "$ROOT" <<'PY'
import os, sys
import yaml

experts_dir, out_path, root = sys.argv[1], sys.argv[2], sys.argv[3]

services, volumes = {}, {}
for entry in sorted(os.listdir(experts_dir)):
    d = os.path.join(experts_dir, entry)
    cfg_path = os.path.join(d, "expert.yml")
    if not os.path.isfile(cfg_path):
        continue
    cfg = yaml.safe_load(open(cfg_path, encoding="utf-8")) or {}
    name = cfg.get("name") or entry
    title = cfg.get("title") or name

    services[name] = {
        "build": {"context": "."},
        "image": "hermes-experts:local",
        "container_name": f"hermes-{name}",
        "restart": "unless-stopped",
        "command": ["gateway"],
        "env_file": [".env", f"private/experts/{name}/.env"],
        "environment": {
            "AGENT_NAME": name,
            "EXPERT_TITLE": title,
            "HERMES_HOME": "/opt/data",
            # 只有被 @ 才回應；不理其他 bot（專家之間不互通）
            "FEISHU_REQUIRE_MENTION": "true",
            "FEISHU_ALLOW_BOTS": "none",
        },
        "volumes": [
            f"{name}-data:/opt/data",
            # 直接掛同一個檔案：宿主重寫 → 容器即時看到，不需要重啟或 refresh
            "./private/peers.yaml:/opt/data/peers.yaml",
            "./scripts/seed-agent.sh:/etc/cont-init.d/99-seed-agent:ro",
            "./knowledge:/opt/bootstrap/knowledge:ro",
            f"./private/experts/{name}:/opt/bootstrap/expert",
        ],
        "networks": ["experts"],
        "stop_grace_period": "30s",
        "healthcheck": {
            "test": ["CMD-SHELL", "test -f /opt/data/config.yaml || exit 1"],
            "interval": "30s",
            "timeout": "5s",
            "retries": 3,
            "start_period": "60s",
        },
    }
    # volume 用獨立前綴，避免與舊部署（hermes_helper）的 volume 撞名而被「收養」
    volumes[f"{name}-data"] = {"name": f"hermes-expert-{name}-data"}

doc = {
    "services": services,
    "volumes": volumes,
}
with open(out_path, "w", encoding="utf-8") as fh:
    fh.write("# 由 scripts/gen-compose.sh 生成，請勿手改（此檔不進 git）\n")
    yaml.safe_dump(doc, fh, allow_unicode=True, sort_keys=False, default_flow_style=False)
print(f"生成 {len(services)} 個 service：{', '.join(services) or '（無）'}")
PY

# 驗證：compose 解析不了就別讓人啟動
if docker compose -f "$BASE_COMPOSE" -f "$GEN_COMPOSE" config -q 2>/dev/null; then
  ok "compose 驗證通過"
else
  bad "compose 驗證失敗"
  docker compose -f "$BASE_COMPOSE" -f "$GEN_COMPOSE" config -q || true
  exit 1
fi
