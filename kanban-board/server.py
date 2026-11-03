#!/usr/bin/env python3
"""唯讀看板網頁：把 kanban.db 畫成看板。

只讀，不寫入任何東西 —— 所以看壞了也不會影響真正的看板資料。
每個看板有自己的網址：  /<看板名>      例如 /smoke-test
根目錄列出所有看板。
"""
import html
import json
import os
import sqlite3
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import unquote, urlparse

DATA = os.environ.get("KANBAN_DATA", "/data")
BOARDS = os.path.join(DATA, "kanban", "boards")
PORT = int(os.environ.get("PORT", "8770"))

COLUMNS = [
    ("todo", "待辦"),
    ("ready", "可開始"),
    ("running", "進行中"),
    ("review", "待驗收"),
    ("done", "完成"),
    ("blocked", "卡住"),
]


def board_paths():
    out = {}
    if not os.path.isdir(BOARDS):
        return out
    for name in sorted(os.listdir(BOARDS)):
        db = os.path.join(BOARDS, name, "kanban.db")
        if os.path.isfile(db):
            out[name] = db
    return out


def read_board(name):
    """回傳 {id, title, assignee, status, ...} 清單；讀不到就丟例外。"""
    db = board_paths().get(name)
    if not db:
        raise KeyError(name)
    conn = sqlite3.connect("file:%s?mode=ro" % db, uri=True, timeout=3)
    conn.row_factory = sqlite3.Row
    try:
        rows = conn.execute(
            "SELECT id, title, assignee, status, priority, created_at, completed_at,"
            " last_heartbeat_at, consecutive_failures, block_kind"
            " FROM tasks ORDER BY priority DESC, created_at ASC"
        ).fetchall()
    finally:
        conn.close()
    return [dict(r) for r in rows]


def fmt_time(ts):
    if not ts:
        return ""
    try:
        ts = float(ts)
    except (TypeError, ValueError):
        return ""
    if ts > 1e11:  # 毫秒
        ts /= 1000.0
    return time.strftime("%m-%d %H:%M", time.localtime(ts))


PAGE = """<!doctype html>
<html lang="zh-HK"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>{title}</title>
<style>
 :root {{ --bg:#0f1115; --card:#1a1d24; --line:#262b35; --fg:#e6e9ef; --dim:#8b93a3; --accent:#4f8cff; }}
 * {{ box-sizing:border-box; }}
 body {{ margin:0; background:var(--bg); color:var(--fg);
        font-family:-apple-system,"Segoe UI","Microsoft JhengHei",sans-serif; }}
 header {{ display:flex; align-items:center; gap:16px; padding:14px 20px;
           border-bottom:1px solid var(--line); position:sticky; top:0; background:var(--bg); z-index:5; }}
 header h1 {{ font-size:16px; margin:0; font-weight:600; }}
 header .meta {{ color:var(--dim); font-size:12px; margin-left:auto; }}
 .board {{ display:grid; grid-template-columns:repeat(6,minmax(210px,1fr)); gap:12px; padding:16px; overflow-x:auto; }}
 .col {{ background:#141821; border:1px solid var(--line); border-radius:10px; padding:10px; min-height:120px; }}
 .col h2 {{ font-size:12px; letter-spacing:.06em; text-transform:uppercase; color:var(--dim);
            margin:2px 0 10px; display:flex; justify-content:space-between; }}
 .card {{ background:var(--card); border:1px solid var(--line); border-left:3px solid var(--accent);
          border-radius:8px; padding:9px 10px; margin-bottom:8px; }}
 .card.done {{ border-left-color:#3fb950; opacity:.75; }}
 .card.blocked {{ border-left-color:#f85149; }}
 .card.running {{ border-left-color:#d29922; }}
 .card .t {{ font-size:13px; line-height:1.35; word-break:break-word; }}
 .card .m {{ font-size:11px; color:var(--dim); margin-top:6px; display:flex; gap:8px; flex-wrap:wrap; }}
 .code {{ font-family:ui-monospace,Consolas,monospace; font-size:11px; color:#7d8590; }}
 .empty {{ color:var(--dim); font-size:12px; padding:6px 2px; }}
 a {{ color:var(--accent); text-decoration:none; }}
 .list {{ padding:20px; max-width:640px; }}
 .list li {{ margin:10px 0; padding:12px 14px; background:var(--card); border:1px solid var(--line);
             border-radius:8px; list-style:none; }}
 .badge {{ font-size:11px; background:#243043; color:#9fb6d9; padding:1px 7px; border-radius:999px; }}
</style></head>
<body>
{body}
<script>
async function tick() {{
  const el = document.getElementById("board");
  if (!el) return;
  try {{
    const r = await fetch("/api/board/{board_name}", {{cache:"no-store"}});
    if (!r.ok) throw 0;
    const d = await r.json();
    el.innerHTML = d.html;
    document.getElementById("updated").textContent = "更新於 " + d.now;
  }} catch (e) {{}}
}}
setInterval(tick, 5000);
</script>
</body></html>
"""


def esc(v):
    return html.escape("" if v is None else str(v))


def render_cards(tasks):
    buckets = {k: [] for k, _ in COLUMNS}
    for t in tasks:
        st = (t.get("status") or "todo").lower()
        buckets.setdefault(st, []).append(t)
    cols = list(COLUMNS)
    for st in buckets:
        if st not in dict(COLUMNS):
            cols.append((st, st))
    out = []
    for st, label in cols:
        items = buckets.get(st, [])
        cards = []
        for t in items:
            cls = st if st in ("done", "blocked", "running") else ""
            meta = []
            if t.get("assignee"):
                meta.append(esc(t["assignee"]))
            ts = t.get("completed_at") if st == "done" else (
                t.get("last_heartbeat_at") or t.get("created_at"))
            if fmt_time(ts):
                meta.append(fmt_time(ts))
            if (t.get("consecutive_failures") or 0) > 0:
                meta.append("✖%s" % t["consecutive_failures"])
            cards.append(
                '<div class="card %s"><div class="t">%s</div>'
                '<div class="m"><span class="code">%s</span>%s</div></div>'
                % (cls, esc(t.get("title")), esc(t.get("id")),
                   "".join("<span>%s</span>" % m for m in meta))
            )
        body = "".join(cards) or '<div class="empty">—</div>'
        out.append('<div class="col"><h2><span>%s</span><span>%d</span></h2>%s</div>'
                   % (esc(label), len(items), body))
    return '<div class="board">%s</div>' % "".join(out)


def board_page(name):
    tasks = read_board(name)
    now = time.strftime("%H:%M:%S")
    body = (
        '<header><h1>看板 <span class="code">%s</span></h1>'
        '<span class="badge">%d 張卡</span>'
        '<a href="/">← 所有看板</a>'
        '<span class="meta" id="updated">更新於 %s</span></header>'
        '<div id="board">%s</div>' % (esc(name), len(tasks), now, render_cards(tasks))
    )
    return PAGE.format(title="看板 " + name, body=body, board_name=esc(name))


def index_page():
    boards = board_paths()
    items = []
    for name in boards:
        try:
            n = len(read_board(name))
        except Exception:
            n = "?"
        items.append('<li><a href="/%s">%s</a> <span class="badge">%s 張卡</span></li>'
                     % (esc(name), esc(name), n))
    body = ('<header><h1>看板</h1><span class="meta">唯讀 · 每 5 秒自動更新</span></header>'
            '<div class="list"><ul>%s</ul></div>' % ("".join(items) or '<li>沒有看板</li>'))
    return PAGE.format(title="看板", body=body, board_name="")


class Handler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):  # noqa: A002
        pass

    def _send(self, code, body, ctype="text/html; charset=utf-8"):
        raw = body.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(raw)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(raw)

    def do_GET(self):
        path = unquote(urlparse(self.path).path).strip("/")
        try:
            if path == "":
                return self._send(200, index_page())
            if path.startswith("api/board/"):
                name = path[len("api/board/"):]
                tasks = read_board(name)
                return self._send(200, json.dumps({
                    "now": time.strftime("%H:%M:%S"),
                    "html": render_cards(tasks),
                }, ensure_ascii=False), "application/json; charset=utf-8")
            if path == "healthz":
                return self._send(200, "ok", "text/plain; charset=utf-8")
            if path in board_paths():
                return self._send(200, board_page(path))
            return self._send(404, PAGE.format(
                title="找不到看板",
                body='<header><h1>找不到看板 <span class="code">%s</span></h1>'
                     '<a href="/">← 所有看板</a></header>' % esc(path),
                board_name=""))
        except KeyError:
            return self._send(404, "unknown board", "text/plain; charset=utf-8")
        except Exception as exc:  # 讀取失敗也要看得到原因
            return self._send(500, "error: %s" % esc(exc), "text/plain; charset=utf-8")


if __name__ == "__main__":
    print("kanban board on :%d  data=%s  boards=%s" % (PORT, DATA, list(board_paths())))
    ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
