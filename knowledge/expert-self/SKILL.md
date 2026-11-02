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

**同時更新 `/opt/data/peers.yaml` 裡你自己那一段**（那是所有人共讀的即時檔案）：

```yaml
- name: mpf
  title: MPF專家
  summary: 強積金對帳、供款與收益核對     ← 跟 expert.yml 保持一致
  strengths: [強積金, 對帳]
```

只改你自己那一筆，**其他專家的資料一個字都不要動**。

寫完告訴人類：「已更新職責，其他專家下次讀名冊就會看到（不用重啟）。」

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

## 人類要給你密碼 / TOKEN 時

**絕對不要叫他們在群裡貼。** 正確做法：請他們在終端機執行這一條。

```
./hh secret "<你的代號>" "<這條密碼是做什麼的>" <KEY_NAME> [值]
```

例如有人問「我怎樣把 GitHub token 給你？」，你就回：

```
請在終端機執行（把 XXX 換成你的 token）：

./hh secret "developer" "NGB 專案的 Git Token" NGB_GIT_TOKEN XXX

或者省略最後的值，系統會用隱藏輸入問你：

./hh secret "developer" "NGB 專案的 Git Token" NGB_GIT_TOKEN
```

寫入後它在 `/opt/bootstrap/expert/.env`，你這樣讀：

```bash
grep '^NGB_GIT_TOKEN=' /opt/bootstrap/expert/.env | cut -d= -f2-
```

### 三條規則

1. **不要在任何回覆裡重複那個值**（連遮罩版本都不要）
2. `KEY_NAME` 用大寫，例如 `NGB_GIT_TOKEN`、`DB_PASSWORD`
3. 說明欄要寫清楚用途 —— 人類日後看 `.env` 時靠那句註解辨認

### 什麼時候該主動要求

當任務需要外部憑證（Git、資料庫、API）而你手上沒有時，**停下來要**，
不要假裝做到。回覆格式：

```
需要憑證：<做什麼用的>
請執行：./hh secret "<我的代號>" "<用途>" <KEY_NAME>
之後告訴我「好了」，我再繼續。
```

## 絕對不要做的事

| 禁止 | 原因 |
|---|---|
| 把密碼寫進 `expert.yml` / `SKILL.md` / `SOUL.md` | 這些檔案會被其他人與備份看到 |
| 在群組對話裡要求人類貼密碼 | 訊息會留在飛書、`state.db`、模型 API 三處。改用上面的 `./hh secret` |
| 改 `name` 欄位 | 它是目錄名與容器名，改了會對不上 |

需要密碼時：用上面那條 `./hh secret` 命令，之後讀 `/opt/bootstrap/expert/.env`。
