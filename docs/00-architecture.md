# 架構 — 為什麼是「扁平專家」而不是「主持人 + 專員」

## 結論

```
你 ──@專家A──► 只有專家A回應（人類看不到其他專家被喚醒）
你 ──@專家B──► 只有專家B回應
     專家之間：知道彼此職責，但互不呼叫
```

## 為什麼放棄主持人

原本的設計是「主持人讀所有訊息 → 判斷 → @ 專員 → 彙總」。實測後放棄，原因三個：

| 問題 | 實測結果 |
|---|---|
| **open_id 無法自動取得** | 飛書的 open_id 是「(App, 對象) 配對值」。主持人眼中的專員 ID，只有「有人在那個群 @ 專員、而主持人收到那條訊息」時才會出現。試過 6 個 API 端點全部落空，訊息 sender 永遠只回 `app_id` |
| **成本** | 主持人 `require_mention=false` + `allow_bots=all`，群裡每一句話都要跑一次 LLM |
| **迴圈風險** | bot 互相 @ 會成鏈，要靠規則 + `bot_loop_guard` 三層防護 |

扁平化之後，這三個問題**同時消失**：沒有人 @ 人，就不需要 open_id；沒有人讀全部訊息，成本只剩被 @ 的那一次。

## 三層資料

| 層 | 內容 | 位置 | git |
|---|---|---|---|
| 框架 | compose、Dockerfile、腳本、共用知識、schema | repo 根目錄、`knowledge/`、`scripts/` | ✅ |
| 專家 | 名稱、簡介、長處、能力 | `private/experts/<name>/expert.yml` | ❌ |
| 部署 | 群組對照、生成的 compose、名冊 | `private/groups.yaml`、`peers.yaml`、`compose.experts.yml` | ❌ |

`git clone` 之後是空機 —— 這是刻意的：**repo 是機器，不是你的專家名單**。

## 容器隔離

```
        hermes-experts:local（同一個映像，只 build 一次）
                   │
     ┌─────────────┼─────────────┐
   expert A     expert B      expert C
     │             │             │
 hermes-expert-A-data …  每個自己的 state.db / memories / skills / .env
```

| 共用 | 隔離 |
|---|---|
| 映像（3 GB，只一份） | 記憶 `state.db` |
| `knowledge/`（唯讀） | `SOUL.md` 性格 |
| `peers.yaml`（唯讀） | `skills/` 技能 |
| Docker network | `.env` 憑證 |

實測記憶體：每位專家約 450 MB 常駐（gateway 長連線）。

## 開機時發生什麼（seed-agent.sh）

```
s6 cont-init（root）
 ├─ 從 /run/s6/container_environment 還原環境變數（s6 會清空）
 ├─ 首次：複製 SOUL.md、寫 config.yaml、建立記憶骨架（用 marker 判斷）
 ├─ 每次：共用知識 knowledge/* → /opt/data/skills/
 ├─ 每次：專屬技能 expert/skills/* → /opt/data/skills/
 ├─ 每次：憑證 → /opt/data/.env（600）
 ├─ 每次：peers.yaml、groups.yaml → /opt/data/
 └─ 每次：identity.yaml（我是誰 + 其他專家是誰）
```

`identity.yaml` 由 `expert.yml` 產生，所以你在群裡叫它改職責 → 它寫回 `expert.yml` →
下次開機 `identity.yaml` 與所有人的 `peers.yaml` 都會更新。

## 三個踩過的坑（已內建修復）

| 坑 | 症狀 | 修法 |
|---|---|---|
| 官方映像 `.venv` 沒有 pip | build 失敗 `No module named pip` | `python -m ensurepip` 後才 `pip install` |
| 官方映像 `.venv` 沒有 pyyaml | `identity.yaml 產生失敗` | Dockerfile 一併安裝 pyyaml |
| bind-mount 來源檔不存在 | docker 把它建成**目錄**，容器讀不到 | `gen-compose.sh` 先建立空檔 |
| 舊容器同名 + 同 volume | compose「收養」舊容器，跑舊版 seed | volume 用 `hermes-expert-<name>-data` |
