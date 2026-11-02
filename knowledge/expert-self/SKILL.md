# 認識並更新自己（所有專家共用）

## 你的三個家

| 路徑 | 內容 | 誰寫 |
|---|---|---|
| `/opt/data/` | 你的記憶、session、`.env`、`identity.yaml` | 系統 |
| `/opt/data/skills/` | 你現在會用的技能 | 系統 + 你 |
| `/opt/bootstrap/expert/` | **你的持久化身份**（`expert.yml`、`SOUL.md`、`skills/`） | 你 |

`/opt/bootstrap/expert/` 是你唯一「寫了會留下來」的地方 —— 它對應到宿主機的
`private/experts/<你的名字>/`。容器重建、升級映像，這裡的檔案都不會消失。

## 當人類告訴你「你負責什麼」

人類可能在群裡直接講：「你負責 MPF 對帳，不碰程式碼」。
這時你要**寫進 `expert.yml`**，否則只有你記得，其他專家永遠不知道。

```yaml
# /opt/bootstrap/expert/expert.yml
name: mpf
title: MPF專家
summary: 強積金對帳、供款與收益核對          ← 改這裡
strengths: [強積金, 對帳, 基金表現]           ← 改這裡
capabilities:
  - 核對供款與收益，驗算「總額 = 供款 + 收益」
cannot:
  - 修改程式碼或部署
updated_at: "2026-10-30"
```

改完之後**保留其他欄位**，不要整份重寫（`name` 絕對不能改）。

寫完告訴人類：「已更新職責，其他專家下次重啟就會看到。」

## 當人類教你一套做法

把它變成技能檔，**同時寫兩份**：

```bash
mkdir -p /opt/bootstrap/expert/skills/<主題>
# 寫 /opt/bootstrap/expert/skills/<主題>/SKILL.md
cp -r /opt/bootstrap/expert/skills/<主題> /opt/data/skills/<主題>
```

- `/opt/bootstrap/expert/skills/` → 永久保存（宿主機可見）
- `/opt/data/skills/` → 你這次執行立刻可用

`SKILL.md` 開頭要有 frontmatter：

```markdown
---
name: mpf-reconcile
description: Use when 對帳 MPF 供款與收益。驗算總額 = 供款 + 收益。
---

## 步驟
1. ...
```

## 絕對不要做的事

| 禁止 | 原因 |
|---|---|
| 把密碼寫進 `expert.yml` / `SKILL.md` / `SOUL.md` | 這些檔案會被其他人與備份看到 |
| 在群組對話裡要求人類貼密碼 | 訊息會留在飛書、`state.db`、模型 API 三處 |
| 改 `name` 欄位 | 它是目錄名與容器名，改了會對不上 |

需要密碼時：告訴人類「請用 `./hh secret <專家> <變數名>` 寫入我的 `.env`」，
你之後用 `printenv <變數名>` 或讀 `/opt/data/.env` 取得，不要經過對話。
