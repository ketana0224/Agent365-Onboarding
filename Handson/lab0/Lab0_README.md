# Lab0｜オリエン & 環境確認（素体エージェントの疎通）

> ハンズオン情報: https://purple-rock-08f9ce800.7.azurestaticapps.net/

> 最終更新: 2026-07-01
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

## 3. Step ↔ Lab 対応表

| Step（提示フロー） | サブ項目 | 対応するLab |
|---|---|---|
| **Step1: APIM登録（連携）** | 出口集約・レート/認証/コンテンツ安全性 | 前提 |
| **Step2: 3Pエージェント作成（SDK）** | Azureで簡易Agent作成 | Lab0 / Lab2 |
| | Foundryで簡易Agent作成 | (本日未実施) Lab9 / Lab8 |
| | APIMとの接続・認証 | Lab3 |
| **Step3: Agent365登録（Entra Agent ID）** | Agent Identity発行／紐付け | Lab2 |
| | Blueprint→Instance関係理解（冒頭で説明） | Lab0 / Lab2 |
| | 作ってA365管理下でBlock制御まで確認 | Lab2 / Lab4 |
| **Step4: 認証パターン体験（超重要）** | A. ユーザー委任型（OBO） | Lab5 |
| | B. 自律型（Agent Identity） | Lab4 / Lab3 |
| **Step5: Agent365への公開（Registry登録）** | Agent Card / Manifest登録 | 別Handson |
| | 一覧に表示 | Lab1 |
| **Step6: 管理・ガバナンス（運用）** | ポリシー設定 | 別Handson |
| | アクセス制御（CA） | Lab2 / Lab4 |
| | ライフサイクル（停止/削除） | Lab4 |
| **Step7: 観測（Observability）** | ログ確認／実行トレース／ツール呼び出し確認 | Lab6 |

---

## 4. 用語マップ

| 用語 | 一言 | 出てくる章 |
|---|---|---|
| **Entra Agent ID** | エージェントの「身分証」（Service Principal）。CA/Purview/Defender の統制対象 | Lab2 以降 |
| **Blueprint → Instance** | `a365 setup all` が作る親（manager）と子（managed=Agent ID）の関係 | Lab2 |
| **Registry sync** | 外部 AI 基盤上のエージェントを在庫へ可視化（ID は付かない） | Lab1 |
| **AI Gateway（APIM）** | LLM/MCP 出口を 1 点集約し認証・レート制御・監査 | Lab3 以降 |
| **素体エージェント** | MAF + FastAPI（`POST /chat`）の ACA アプリ。本章で疎通 | Lab0 |

---

## 5. 前提リソース（疎通対象）

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

## 6. local-chat-app（素体を叩く UI）

`agent-custom-MAF-ACA-A365`（`POST /chat`）を、ローカルの HTML+JS チャット UI から叩くための **依存ゼロ**（Python 標準ライブラリのみ）アプリ。

| ファイル | 役割 |
|---|---|
| `index.html` | チャット画面 |
| `styles.css` | ダークテーマのスタイル |
| `app.js` | 送信・疎通確認・表示 |
| `serve.py` | 静的配信 + CORS 回避プロキシ |

> **なぜプロキシが必要か**: 素体エージェントには CORS 設定が無いため、ブラウザから直接 ACA の `/chat` を叩くと CORS でブロックされる。`serve.py` が同一オリジンで UI を配信し `POST /api/chat` を `{backend}/chat` にサーバー間中継するので、**エージェント側コードは無改変**で動く。接続先（ACAの URL）は `serve.py` 内に固定され、**ブラウザ・app.js には一切露出しない**。

---

## 7. 前提ツール（Python / pip）

`serve.py` は **Python 標準ライブラリのみ**で動く（UI 起動に追加パッケージは不要）が、ハンズオン全体（Lab2 以降のエージェントビルド・`a365` CLI など）で Python / pip を使う。仮想環境 `.venv` は **リポジトリ ルート**（`C:\Agent365-Onboarding\.venv`）に作る。

| ツール | 要件 |
|---|---|
| **Python** | 3.10 以上 |
| **pip** | Python に同梱（`python -m pip`） |

```powershell
# リポジトリ ルートで実行
cd C:\Agent365-Onboarding
python --version        # 3.10 以上であること
python -m pip --version # pip が使えること

# 仮想環境をルートに作成・有効化
python -m venv .venv
.\.venv\Scripts\Activate.ps1
python -m pip install --upgrade pip
```

> ルートの `.venv` を一つだけ作り、各 Lab はこの同じ仮想環境を使い回す（Lab ごとに `.venv` を作らない）。

---

## 8. 疎通手順

### 8.1 プロキシ（UI）を起動

```powershell
# ルートの .venv を有効化済みなら python で OK
cd Handson\lab0\local-chat-app
python serve.py            # 接続先は serve.py 内に固定、起動時にブラウザが自動で開く
python serve.py --port 9000 # ポート変更
python serve.py --no-open   # ブラウザを自動で開かない
```

- **接続先は `serve.py` 内に固定**されており、UI（ブラウザ）からは見えない・変更できない。ローカルでエージェントを起動する必要はない。
- 別デプロイ環境に向ける場合のみ、`--backend`（または環境変数 `LOCAL_CHAT_BACKEND`）で上書きできる。

<details>
<summary>クリックして開く：FQDN を自分で取得する場合（別デプロイ環境向け）</summary>

```powershell
az containerapp show -g <rg> -n custom-maf-agent-a365 --query properties.configuration.ingress.fqdn -o tsv
```

取得した FQDN（`https://<app>.azurecontainerapps.io`）を `serve.py --backend` に渡す。

</details>

### 8.2 ブラウザで開く

`serve.py` 起動時に **自動でブラウザが開く**（開かない場合は手動で）。

```
http://localhost:8080
```

右上 ⚙️ の「疎通確認」で接続を確認（緑=OK / 赤=エラー）。送信は `Enter`、改行は `Shift+Enter`。接続先 URL は表示されない（サーバー側固定）。

> **注意**: `index.html` を `file://` で直接開いても動かない（プロキシが無く相対パス `/api/*` が解決できない）。必ず `serve.py` 経由で `http://localhost:8080` を開く。

---

## 9. 成果物 / 検証

- 「**返品ポリシーを教えて**」と送ると、エージェントが MCP（`contoso-policy-mcp`）を呼んで回答する。
- 応答 `{"agent","reply"}` の `reply` が表示され、`agent` 名がメタ表示される。
- 出口（LLM/MCP）はすべて APIM 経由＝Foundry/MCP に直結しない。

## 10. ⚠️ ハマりどころ

| 症状 | 原因 | 対処 |
|---|---|---|
| `python` が見つからない | Python 未インストール / PATH 未通し | Python 3.10 以上をインストールし、`python --version` が通ることを確認 |
| `file://` で開いて動かない | プロキシが無く相対パス `/api/*` が解決できない | `serve.py` を起動し `http://localhost:8080` で開く |
| 疎通確認が赤・接続できない | プロキシ未起動 / ACA 停止 | `serve.py` が起動しているか、ACA が稼働中か確認 |
| ブラウザから直叩きで CORS エラー | エージェントに CORS 無し | `serve.py` の `/api/chat` プロキシ経由で叩く（ACA を直叩きしない） |
| 502 backend 接続不可 | 固定バックエンドが未応答 | ACA が稼働中か確認（URL は `serve.py` 内に固定） |

---

## 付録: 参照（一次情報）

| 内容 | URL |
|---|---|
| Agent 365 SDK 概要 | `https://learn.microsoft.com/microsoft-agent-365/developer/agent-365-sdk` |
| Get started | `https://learn.microsoft.com/microsoft-agent-365/developer/get-started` |
| local-chat-app 詳細 | [local-chat-app/README.md](local-chat-app/README.md) |
| 素体エージェント（Lab2 でデプロイ） | [../lab2/agent-custom-MAF-ACA-A365](../lab2/agent-custom-MAF-ACA-A365/) |
| Handson 全体まとめ | [../README.md](../README.md) |
