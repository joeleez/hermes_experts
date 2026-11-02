#!/opt/hermes/.venv/bin/python
"""gen-groups.py — 問每個專家「你在哪些群」，反轉成「每個群有哪些專家」。

輸出（每 60 秒重寫一次，給所有專家即時讀）：

```yaml
# 由 roster 服務自動生成
groups:
  - chat_id: oc_xxx
    name: ngb測試用
    experts:
      - name: developer
        title: NGB 程式開發員
      - name: ngb_tester
        title: NGB項目驗收專家
```

為什麼要繞這圈：飛書不提供「群內機器人清單」的 API（bot_count 只給數量），
但每個 bot 自己可以查「我在哪些群」。逐個問再反轉，就得到群組成員表。
"""
import json
import os
import sys
import urllib.error
import urllib.request

SRC = sys.argv[1] if len(sys.argv) > 1 else "/src"
OUT = sys.argv[2] if len(sys.argv) > 2 else "/out/groups.yaml"


def load_env(path, base=None):
    d = dict(base or {})
    if os.path.exists(path):
        for line in open(path, encoding="utf-8"):
            s = line.strip()
            if s and not s.startswith("#") and "=" in s:
                k, v = s.split("=", 1)
                d[k.strip()] = v.strip()
    return d


def read_expert(path):
    """極簡讀取 expert.yml 的 name/title（不引入 yaml 依賴）。"""
    name = os.path.basename(os.path.dirname(path))
    title = name
    for line in open(path, encoding="utf-8"):
        s = line.strip()
        if s.startswith("name:"):
            name = s.split(":", 1)[1].strip().strip('"') or name
        elif s.startswith("title:"):
            title = s.split(":", 1)[1].strip().strip('"') or title
    return name, title


def tenant_token(base, app_id, secret):
    req = urllib.request.Request(
        base + "/open-apis/auth/v3/tenant_access_token/internal",
        data=json.dumps({"app_id": app_id, "app_secret": secret}).encode(),
        headers={"Content-Type": "application/json"})
    return json.load(urllib.request.urlopen(req, timeout=15))["tenant_access_token"]


def chats_of(base, tok):
    req = urllib.request.Request(base + "/open-apis/im/v1/chats?page_size=100",
                                 headers={"Authorization": "Bearer " + tok})
    data = json.load(urllib.request.urlopen(req, timeout=15)).get("data", {})
    return data.get("items", []) or []


def main():
    shared = load_env(os.path.join(os.path.dirname(os.path.dirname(SRC)), ".env"))
    groups = {}
    problems = []

    if not os.path.isdir(SRC):
        print(f"找不到 {SRC}")
        return 0

    for entry in sorted(os.listdir(SRC)):
        d = os.path.join(SRC, entry)
        cfg = os.path.join(d, "expert.yml")
        if not os.path.isfile(cfg):
            continue
        name, title = read_expert(cfg)
        env = load_env(os.path.join(d, ".env"), shared)
        app_id, secret = env.get("FEISHU_APP_ID", ""), env.get("FEISHU_APP_SECRET", "")
        if not app_id or not secret:
            problems.append(f"{name}: 缺憑證")
            continue
        base = "https://open.larksuite.com" if (env.get("FEISHU_DOMAIN") or "lark").startswith("lark") \
            else "https://open.feishu.cn"
        try:
            tok = tenant_token(base, app_id, secret)
            for it in chats_of(base, tok):
                cid = it.get("chat_id")
                if not cid:
                    continue
                g = groups.setdefault(cid, {"chat_id": cid, "name": it.get("name") or "", "experts": []})
                if not any(e["name"] == name for e in g["experts"]):
                    g["experts"].append({"name": name, "title": title})
        except urllib.error.HTTPError as exc:
            problems.append(f"{name}: HTTP {exc.code}")
        except Exception as exc:  # noqa: BLE001
            problems.append(f"{name}: {type(exc).__name__}")

    # 手寫 YAML（不依賴 pyyaml，讓這支腳本在任何映像都能跑）
    lines = ["# 由 roster 服務自動生成，每 60 秒更新（此檔不進 git）", "groups:"]
    if not groups:
        lines.append("  []")
    for cid in sorted(groups, key=lambda c: (groups[c].get("name") or "", c)):
        g = groups[cid]
        lines.append(f"  - chat_id: {g['chat_id']}")
        lines.append(f"    name: \"{g['name']}\"")
        lines.append("    experts:")
        for e in sorted(g["experts"], key=lambda x: x["name"]):
            lines.append(f"      - name: {e['name']}")
            lines.append(f"        title: \"{e['title']}\"")

    # 必須「就地覆寫」而不是原子替換：OUT 是 bind-mount 的單一檔案，
    # os.replace 會換掉 inode，容器就看不到新內容了。
    with open(OUT, "w", encoding="utf-8") as fh:
        fh.write("\n".join(lines) + "\n")

    print(f"[groups] {len(groups)} 個群、{sum(len(g['experts']) for g in groups.values())} 個群組成員"
          + (f"；問題：{'; '.join(problems)}" if problems else ""))
    return 0


if __name__ == "__main__":
    sys.exit(main())
