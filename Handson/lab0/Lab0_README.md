# Lab0｜オリエン & 環境確認（素体エージェントの疎通）

> ハンズオン情報: https://purple-rock-08f9ce800.7.azurestaticapps.net/

> 最終更新: 2026-06-29
> 目的: ハンズオン全体の **用語・全体像** を共有し、**前提リソースが動く**ことを確認する。Agent 365 で統制する前の「素体エージェント」を **ローカル UI から 1 往復** させ、MCP を呼んで回答することを見届ける。
> 親: [Handson 全体まとめ](../README.md)
> 統制レベル: **なし（統制前）**。Agent ID も登録も無い「ただの ACA アプリ」を動かすだけの段。ここに ID／出口集約／キルスイッチ／可観測化を Lab1 以降で 1 段ずつ積む。
> 一次情報: [Get started](https://learn.microsoft.com/microsoft-agent-365/developer/get-started) / [Agent 365 SDK 概要](https://learn.microsoft.com/microsoft-agent-365/developer/agent-365-sdk)

---

## 1. ゴール

- ハンズオンの設計方針「**ID の強さで効くガバナンスが段階的に変わる**」を把握する。
- 用語マップ（Entra Agent ID / Blueprint→Instance / Registry / AI Gateway）を共有する。
- 既存リソース（**素体エージェント・MCP・Foundry・APIM**）が動くことを疎通確認する。
- [local-chat-app](local-chat-app/) から素体エージェントに **1 往復** し、MCP を呼んで回答することを確認する（例: 「返品ポリシーを教えて」）。

> 本章は **ゼロからエージェントを作らない**。Lab2 でデプロイ／使用する素体エージェント [agent-custom-MAF-ACA-A365](../lab2/agent-custom-MAF-ACA-A365/) を、Agent ID も登録も付けない素のまま叩いて「LLM で回答し MCP を呼ぶ」だけを確認する。統制の話は Lab1 以降。

## 2. 統制レベル（このハンズオンの段階・先出し）

| 章 | 統制レベル | 一言 | 効くガバナンス |
|---|---|---|---|
| **Lab0（本章）** | なし | 素体を動かすだけ | 何も効かない（ただの ACA アプリ） |
| **Lab1** | レジストリ同期のみ | 見えるだけ | 在庫可視化のみ（CA/Purview/Defender は不可） |
| **Lab2** | Agent ID 付き | 主体として統制・ブロック可 | CA / Purview / Defender / Entra governance |
| **Lab3→Lab4** | 出口集約→Agent ID 出口化 | 止めると遮断（キルスイッチ） | 出口トークンを Agent ID 化 |
| **Lab5** | OBO 二重統制 | ユーザー本人の権限で Graph | Agent ID + ユーザー側統制 |
| **Lab6** | Observability | 行動を可観測化 | Defender/Purview/管理センターへ per-span |

> 全段の詳細は [Handson 目次](../README.md) を参照。本章は **その手前** の素体確認。

## 3. 用語マップ

| 用語 | 一言 | 出てくる章 |
|---|---|---|
| **Entra Agent ID** | エージェントの「身分証」（Service Principal）。CA/Purview/Defender の統制対象 | Lab2 以降 |
| **Blueprint → Instance** | `a365 setup all` が作る親（manager）と子（managed=Agent ID）の関係 | Lab2 |
| **Registry sync** | 外部 AI 基盤上のエージェントを在庫へ可視化（ID は付かない） | Lab1 |
| **AI Gateway（APIM）** | LLM/MCP 出口を 1 点集約し認証・レート制御・監査 | Lab3 以降 |
| **素体エージェント** | MAF + FastAPI（`POST /chat`）の ACA アプリ。本章で疎通 | Lab0 |

---

## 4. 前提リソース（疎通対象）

| 区分 | 既存資産 | 出口 |
|---|---|---|
| 素体エージェント | `custom-maf-agent-a365`（MAF + ACA） | `POST /chat` |
| 推論モデル | `gpt-5.4`（Foundry `proj-foundryobs-jyenh`） | **APIM 経由必須** |
| MCP（社内 API 見立て） | `contoso-policy-mcp`（ACA） | **APIM 経由必須** |
| AI Gateway | APIM `apim-aigateway-eastus2` | — |

| 項目 | 値 |
|---|---|
| テナント ID | `<TENANT_ID>`（`<tenant>.onmicrosoft.com`） |
| サブスクリプション ID | `<SUBSCRIPTION_ID>` |
| リージョン | `eastus2` |
| リソース グループ | `rg-foundryobs-eastus2`（共有基盤） |

---

## 5. local-chat-app（素体を叩く UI）

`agent-custom-MAF-ACA-A365`（`POST /chat`）を、ローカルの HTML+JS チャット UI から叩くための **依存ゼロ**（Python 標準ライブラリのみ）アプリ。

| ファイル | 役割 |
|---|---|
| `index.html` | チャット画面 |
| `styles.css` | ダークテーマのスタイル |
| `app.js` | 送信・疎通確認・表示 |
| `serve.py` | 静的配信 + CORS 回避プロキシ |

> **なぜプロキシが必要か**: 素体エージェントには CORS 設定が無いため、ブラウザから直接 `:8000/chat` を叩くと CORS でブロックされる。`serve.py` が同一オリジンで UI を配信し `POST /api/chat` を `{backend}/chat` にサーバー間中継するので、**エージェント側コードは無改変**で動く。

---

## 6. 疎通手順

### 6.1 エージェントを起動（A: ローカル / B: ACA）

**A) ローカル起動**

```powershell
cd ..\lab2\agent-custom-MAF-ACA-A365
uvicorn app.main:app --host 0.0.0.0 --port 8000
```

**B) ACA デプロイ済みを使う** … 公開 FQDN（`https://<app>.azurecontainerapps.io`）を 6.3 の ⚙️ で指定。

### 6.2 プロキシ（UI）を起動

```powershell
cd local-chat-app
python serve.py                                   # http://localhost:8080
python serve.py --port 9000                       # ポート変更
python serve.py --backend https://<app>.azurecontainerapps.io  # 既定バックエンド
```

- 既定: `http://localhost:8080` で配信、バックエンドは `http://localhost:8000`
- 環境変数 `LOCAL_CHAT_BACKEND` でも既定バックエンドを指定可

### 6.3 ブラウザで開く

```
http://localhost:8080
```

右上 ⚙️ でバックエンド URL を変更し「疎通確認」で接続を確認（緑=OK / 赤=エラー）。設定は localStorage に保存。送信は `Enter`、改行は `Shift+Enter`。

---

## 7. 成果物 / 検証

- 「**返品ポリシーを教えて**」と送ると、エージェントが MCP（`contoso-policy-mcp`）を呼んで回答する。
- 応答 `{"agent","reply"}` の `reply` が表示され、`agent` 名がメタ表示される。
- 出口（LLM/MCP）はすべて APIM 経由＝Foundry/MCP に直結しない。

## 8. ⚠️ ハマりどころ

| 症状 | 原因 | 対処 |
|---|---|---|
| 疎通確認が赤・接続できない | エージェント未起動 / バックエンド URL 誤り | A) `uvicorn` 起動を確認、B) FQDN を ⚙️ に設定 |
| ブラウザから直叩きで CORS エラー | エージェントに CORS 無し | `serve.py` の `/api/chat` プロキシ経由で叩く（直 `:8000` は不可） |
| 502 backend 接続不可 | ローカル未起動 / ポート不一致 | ポート 8000 とバックエンド URL を一致させる |

---

## 付録: 参照（一次情報）

| 内容 | URL |
|---|---|
| Agent 365 SDK 概要 | `https://learn.microsoft.com/microsoft-agent-365/developer/agent-365-sdk` |
| Get started | `https://learn.microsoft.com/microsoft-agent-365/developer/get-started` |
| local-chat-app 詳細 | [local-chat-app/README.md](local-chat-app/README.md) |
| 素体エージェント（Lab2 でデプロイ） | [../lab2/agent-custom-MAF-ACA-A365](../lab2/agent-custom-MAF-ACA-A365/) |
| Handson 全体まとめ | [../README.md](../README.md) |
