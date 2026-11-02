#!/usr/bin/env bash
# sync-groups.sh — 用每位專家自己的憑證問飛書「我在哪些群」，合成 groups.yaml
#
# 為什麼這樣問：飛書的群組成員 API 只回人類，不回 bot；
# 要知「這個群有哪幾個專家」，只能由上往下反推 —— 問每個專家它在哪些群，再反轉。
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

EOF_MARK="__SYNC__"

python3 - "$EXPERTS" "$ROOT" "$GROUPS" <<'PY'
import json, os, sys, urllib.error, urllib.request
import yaml

experts_dir, root, out_path = sys.argv[1], sys.argv[2], sys.argv[3]

def load_env(path, base=None):
    d = dict(base or {})
    if os.path.exists(path):
        for line in open(path, encoding="utf-8"):
            s = line.strip()
            if s and not s.startswith("#") and "=" in s:
                k, v = s.split("=", 1)
                d[k.strip()] = v.strip()
    return d

shared = load_env(os.path.join(root, ".env"))

def token(app_id, secret, base):
    req = urllib.request.Request(
        base + "/open-apis/auth/v3/tenant_access_token/internal",
        data=json.dumps({"app_id": app_id, "app_secret": secret}).encode(),
        headers={"Content-Type": "application/json"})
    return json.load(urllib.request.urlopen(req, timeout=20))["tenant_access_token"]

def get(path, tok, base):
    req = urllib.request.Request(base + path, headers={"Authorization": "Bearer " + tok})
    return json.load(urllib.request.urlopen(req, timeout=20))

groups = {}   # chat_id -> {name, experts:[...]}
problems = []

names = sorted(n for n in os.listdir(experts_dir)
               if os.path.isfile(os.path.join(experts_dir, n, "expert.yml")))

for name in names:
    env = load_env(os.path.join(experts_dir, name, ".env"), shared)
    app_id = env.get("FEISHU_APP_ID", "")
    secret = env.get("FEISHU_APP_SECRET", "")
    if not app_id or not secret:
        problems.append(f"{name}: 缺 App ID/Secret")
        continue
    base = "https://open.larksuite.com" if (env.get("FEISHU_DOMAIN") or "lark").startswith("lark") \
        else "https://open.feishu.cn"
    try:
        tok = token(app_id, secret, base)
        data = get("/open-apis/im/v1/chats?page_size=100", tok, base).get("data", {})
        items = data.get("items", []) or []
        if not items:
            problems.append(f"{name}: 不在任何群（把它拉進群後再 sync）")
        for it in items:
            cid = it.get("chat_id")
            g = groups.setdefault(cid, {"chat_id": cid, "name": it.get("name", ""), "experts": []})
            g["experts"].append(name)
    except urllib.error.HTTPError as e:
        problems.append(f"{name}: 查群失敗 HTTP {e.code}")
    except Exception as e:
        problems.append(f"{name}: {str(e)[:60]}")

rows = []
for cid in sorted(groups, key=lambda c: groups[c].get("name", "")):
    g = groups[cid]
    rows.append({"chat_id": cid, "name": g["name"], "experts": sorted(g["experts"])})

with open(out_path, "w", encoding="utf-8") as fh:
    fh.write("# 由 scripts/sync-groups.sh 生成，請勿手改（此檔不進 git）\n")
    yaml.safe_dump(rows, fh, allow_unicode=True, sort_keys=False, default_flow_style=False)

for r in rows:
    print(f"  {r['name'] or '(無名)'}  {r['chat_id']}")
    print(f"     專家：{', '.join(r['experts'])}")
for p in problems:
    print(f"  ! {p}")
if not rows:
    print("  （沒有任何群）")
PY

# 讓容器讀到最新版本（不需要重啟：下次 seed 或手動 cp）
for e in $(list_experts); do
  c="hermes-$e"
  docker ps --format '{{.Names}}' | grep -qx "$c" && \
    docker cp "$GROUPS" "$c:/opt/data/groups.yaml" >/dev/null 2>&1 || true
done
ok "groups.yaml 已更新"
