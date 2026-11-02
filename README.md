# hermes_experts — 飛書專家系統

一組各自獨立的 AI 專家，住在飛書群裡。**你 @ 哪一位，只有那一位回應。**

- 沒有主持人、沒有轉派、沒有 bot 互相對話
- 每位專家有自己的飛書 App、記憶、技能、性格、憑證
- 群裡所有專家知道彼此的職責與長處，但**互不呼叫**

## 這個 repo 只放「機器」

| 進 git | 不進 git（`private/`） |
|---|---|
| `docker-compose.base.yml`（共用設定） | `private/experts/<name>/expert.yml`（名稱、簡介、長處、能力） |
| `Dockerfile` | `private/experts/<name>/SOUL.md`（性格） |
| `knowledge/`（群組禮儀、自我更新） | `private/experts/<name>/skills/`（專屬技能） |
| `schemas/`、`templates/`（格式） | `private/experts/<name>/.env`（App ID/Secret） |
| `scripts/`、`hh`（工具） | `private/compose.experts.yml`、`peers.yaml`、`groups.yaml`（生成物） |

`git clone` 之後是**空機**：沒有任何專家。專家要一個一個用 `./hh new` 建。

## 快速開始

```bash
cp .env.example .env          # 填 DEEPSEEK_API_KEY
chmod 600 .env
./hh                          # 互動選單
```

第一次先 `./hh new` 建一位專家，之後日常都從 `./hh` 進去。

## 三個不變的規則

1. **只被 @ 才回應** —— 專家不會自己跳出來講話
2. **專家不 @ 任何人** —— 沒有 bot 對 bot 的迴圈
3. **密碼不經過對話** —— 用 `./hh secret <專家> <變數名>`

## 文件

- `docs/00-architecture.md` —— 為什麼這樣設計（含實測數據）
- `docs/01-手冊.md` —— 日常操作：建專家、建群、拉進群、教它做事
