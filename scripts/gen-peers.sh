#!/usr/bin/env bash
# gen-peers.sh — 生成「其他專家是誰」的名冊給每個容器讀
#
# 產出：private/peers.yaml（不進 git）
# 只放 name / title / summary / strengths — 不含任何憑證或 open_id，
# 因為每位專家都需要看到全部人的資料，不能夾帶秘密。
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

mkdir -p "$EXPERTS"

python3 - "$EXPERTS" "$PEERS" <<'PY'
import os, sys
import yaml

experts_dir, out_path = sys.argv[1], sys.argv[2]

rows = []
for entry in sorted(os.listdir(experts_dir)):
    cfg_path = os.path.join(experts_dir, entry, "expert.yml")
    if not os.path.isfile(cfg_path):
        continue
    cfg = yaml.safe_load(open(cfg_path, encoding="utf-8")) or {}
    rows.append({
        "name": cfg.get("name", entry),
        "title": cfg.get("title", entry),
        "summary": cfg.get("summary", ""),
        "strengths": cfg.get("strengths") or [],
    })

with open(out_path, "w", encoding="utf-8") as fh:
    fh.write("# 由 scripts/gen-peers.sh 生成，請勿手改（此檔不進 git）\n")
    yaml.safe_dump(rows, fh, allow_unicode=True, sort_keys=False, default_flow_style=False)

print(f"peers.yaml：{len(rows)} 位專家")
PY

for name in $(list_experts); do
  printf '  %-12s %s\n' "$name" "$(expert_field "$name" title)"
done
