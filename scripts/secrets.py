#!/usr/bin/env python3
"""secrets.py — 專家 .env 的原子操作（create / update / delete / list）

設計約束：
- `.env` 是宿主檔案，格式是「說明註解 + KEY=VALUE」成對出現
- create 遇到已存在的 KEY 必須失敗（避免覆蓋掉正在用的憑證）
- update / delete 遇到不存在的 KEY 必須失敗（避免打錯字靜默新增）
- 永不印出值
"""
import os
import re
import sys

KEY_RE = re.compile(r"^[A-Z][A-Z0-9_]*$")


def read(path):
    if not os.path.exists(path):
        sys.exit(f"✗ 找不到 {path}")
    return open(path, encoding="utf-8").read().splitlines()


def write(path, lines):
    while lines and not lines[-1].strip():
        lines.pop()
    with open(path, "w", encoding="utf-8") as fh:
        fh.write("\n".join(lines) + "\n")
    os.chmod(path, 0o600)


def find(lines, key):
    """回傳 (key 行索引, 緊接其上的說明行索引或 None)"""
    for i, line in enumerate(lines):
        if line.startswith(key + "="):
            desc_i = i - 1 if i > 0 and lines[i - 1].lstrip().startswith("#") else None
            return i, desc_i
    return None, None


def cmd_create(path, key, desc, value):
    lines = read(path)
    i, _ = find(lines, key)
    if i is not None:
        sys.exit(f"✗ {key} 已存在，請用 ./hh secret_update 更新它")
    while lines and not lines[-1].strip():
        lines.pop()
    lines.append(f"# {desc}")
    lines.append(f"{key}={value}")
    write(path, lines)
    print(f"✓ 已新增 {key}（{desc}）")


def cmd_update(path, key, desc, value):
    lines = read(path)
    i, desc_i = find(lines, key)
    if i is None:
        sys.exit(f"✗ {key} 不存在，請用 ./hh secret_create 新增它")
    lines[i] = f"{key}={value}"
    if desc and desc_i is not None:
        lines[desc_i] = f"# {desc}"
    write(path, lines)
    print(f"✓ 已更新 {key}")


def cmd_delete(path, key):
    lines = read(path)
    i, desc_i = find(lines, key)
    if i is None:
        sys.exit(f"✗ {key} 不存在，無法刪除")
    drop = {i} | ({desc_i} if desc_i is not None else set())
    write(path, [l for n, l in enumerate(lines) if n not in drop])
    print(f"✓ 已刪除 {key}")


def cmd_list(path, agent):
    lines = read(path)
    print(f"{agent} 的 KEY（只列名稱，不顯示值）：")
    shown = 0
    for i, line in enumerate(lines):
        m = re.match(r"^([A-Z][A-Z0-9_]*)=", line)
        if not m:
            continue
        desc = lines[i - 1].lstrip("# ").strip() if i > 0 and lines[i - 1].startswith("#") else ""
        print(f"  {m.group(1):24s} {desc}")
        shown += 1
    if not shown:
        print("  （沒有任何 KEY）")


def main():
    if len(sys.argv) < 3:
        sys.exit("用法：secrets.py <create|update|delete|list> <env路徑> [...]")
    action, path = sys.argv[1], sys.argv[2]

    if action == "list":
        cmd_list(path, os.path.basename(os.path.dirname(path)))
        return

    if len(sys.argv) < 4:
        sys.exit("缺少 KEY_NAME")
    key = sys.argv[3]
    if not KEY_RE.match(key):
        sys.exit(f"✗ KEY_NAME 不合法：{key}（要大寫字母開頭，只含 A-Z 0-9 _）")

    if action == "delete":
        cmd_delete(path, key)
        return

    if len(sys.argv) < 5:
        sys.exit("缺少說明或值")
    desc, value = sys.argv[4], sys.argv[5]
    if action == "create":
        cmd_create(path, key, desc, value)
    elif action == "update":
        cmd_update(path, key, desc, value)
    else:
        sys.exit(f"✗ 未知動作：{action}")


if __name__ == "__main__":
    main()
