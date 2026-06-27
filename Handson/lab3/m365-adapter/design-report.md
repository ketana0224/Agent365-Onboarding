# 既存 ACA エージェントを Agent 365 の M365 エージェント化する — 外側ラッパー設計レポート

- **作成日時**: 2026-06-25 09:44
- **対象エージェント**: `C:\GitHub\Agent365-Onboarding\lab\extLab2\agent-custom-MAF-ACA-A365`（MAF + FastAPI、ACA ホスト、`/chat` API）
- **目的**: **元コードを無改変**のまま、`a365 setup ... --m365` で登録できる「M365 エージェント」として成立させる
- **方針**: 受信スキーマ（Bot Framework Activity）と着信認証は **Microsoft 365 Agents SDK に委譲**し、アダプタは `/chat` への橋渡しのみを担う
- **機密度**: 公開可（公式ドキュメント + 稼働実装 `agent-extended` の構成に基づく）

> ⚠️ 製品の同定：本レポートは Microsoft の **「Agent 365」（AI エージェントの管理・ガバナンス基盤）** 向け CLI `a365` を対象とします。Microsoft 365 / Office 365 / Dynamics 365 とは別製品です。

---

## 🎯 結論

- 既存エージェントは **HTTPS 公開という前提は満たす**が、**そのままでは M365 エージェントとして機能しない**。受信パス（`/api/messages`）・メッセージスキーマ・着信認証・Blueprint(Entra ID アプリ登録) が不足するため。
- 解決策は **外側に独立したアダプタ層を1枚かぶせる**こと。元プロジェクトには一切触れない。
- **受信スキーマは未知ではない**。messaging endpoint（`/api/messages`）が受け取るのは **Bot Framework Activity スキーマ**（公開・バージョン管理された安定プロトコル）で、これを実装・保守しているのが **Microsoft 365 Agents SDK（Microsoft 公式）**。`a365 ... --messaging-endpoint .../api/messages` の規約自体が Bot Framework 由来。
- **推奨方式は「別コンテナのアダプタ（案B）を Microsoft 365 Agents SDK 上に実装する」**こと。スキーマ解釈と着信 JWT 検証は SDK に委譲し、アダプタは「SDK が取り出したユーザー発話テキスト → 既存 `/chat` 呼び出し」の橋渡しだけを書く。
- **生ペイロードを採取して自前変換する方式は採らない**。リバースエンジニアした構造体に手で合わせるアプローチは、Agent 365 / SDK の内部更新で割れる脆い設計のため不採用。
- **既存の参照実装あり**：同じエージェントを M365 Agents SDK で実装した [`agent-extended`](../agent-extended/) が稼働済み。アダプタの `/api/messages` 層はこの実装からそのまま流用できる。

---

## 1. なぜ「そのまま」では不可か（互換性ギャップ）

### ✅ 満たしている要件（事実）
- **HTTPS 公開**：ACA 外部 HTTPS Ingress（port 8000）→ `https://<app>.azurecontainerapps.io`。messaging endpoint 必須要件「HTTPS URL」を満たす。
- **post-deploy で URL 確定**：`--m365` が想定する「endpoint は post-deploy 成果物 → 後から登録」フローと一致。
- 登録自体は可能：`a365 setup blueprint --endpoint-only --messaging-endpoint <url>`。

### ❌ 不足要件（ギャップ）
| 観点 | Agent 365 が要求 | 既存エージェント | 差分 |
|---|---|---|---|
| 受信パス | 慣例 `/api/messages` | `/chat`・`/healthz` のみ | パス不一致 |
| メッセージ形式 | **Bot Framework Activity スキーマ**（M365 Agents SDK が実装する公開プロトコル） | 独自 JSON `{"message":"..."}` | スキーマ不一致（SDK 採用で解消） |
| Identity / Blueprint | `a365 setup blueprint` で作る **Entra ID アプリ登録(Blueprint)** | Foundry 推論用 MI + Azure AI User のみ | Blueprint 未作成 |
| 着信認証 | Agent 365 / Bot チャネルが付与するトークンの検証（M365 Agents SDK の `jwt_authorization_middleware` が実施） | `/chat` は認証なしの公開 API | 受信認証なし（SDK 採用で解消） |

> **核心**：`--m365` の役割は「**URL をプラットフォームに登録する**」ことだけ。エージェント側が Agent 365 の messaging ペイロードを**受理して応答する実装**を持たなければ、登録しても対話は成立しない。

---

## 2. 解決アーキテクチャ（外側ラッパー）

```
Agent 365 Platform
   │  messaging endpoint コントラクト（スキーマ＋認証）
   ▼
[ アダプタ層（Microsoft 365 Agents SDK ホスト） ]  ← --m365 の messaging-endpoint として登録
   │  ・/api/messages を SDK で終端（Activity 解釈・着信 JWT 検証は SDK 任せ）
   │  ・SDK が取り出したユーザー発話テキスト → {"message": "..."} へ詰め替え
   │  ・既存 /chat を内部 HTTP 呼び出し
   │  ・/chat 応答 → turn_context.send_activity() で返信
   ▼
既存 ACA エージェント /chat（無改変）
```

---

## 3. 方式比較

| | 案A: APIM 中継 | 案B: 別コンテナ アダプタ（推奨） |
|---|---|---|
| 実装 | ポリシーのみ（`rewrite-uri` / `set-body`(Liquid) / `validate-jwt`） | 小さな FastAPI を別 ACA にデプロイ |
| 元コード | 無改変 ✅ | 無改変 ✅ |
| 着信認証 | 標準で強い（`validate-jwt`） | 自前実装が必要 |
| 同期 JSON↔JSON 変換 | 得意（定形なら容易） | 得意 |
| 動的変換・**非同期返信** | 弱い | 強い（コードで自由） |
| Activity スキーマ／着信認証の扱い | `validate-jwt` は可だが Activity 解釈は手書き | **M365 Agents SDK に委譲（手書き不要）** |
| レート制限・課金保護 | 同梱 | 別途 |
| 運用コスト | APIM 課金/管理 | コンテナ1個増 |

### 推奨：案B（別コンテナ アダプタ／Microsoft 365 Agents SDK 上に実装）
- アダプタは **aiohttp + Microsoft 365 Agents SDK** で `/api/messages` を終端する（[`agent-extended/app/main.py`](../agent-extended/app/main.py) が同型の稼働実装）。Activity スキーマの解釈と着信 JWT 検証は SDK が担うため、**自前のペイロード変換・トークン検証は書かない**。
- アダプタ本体は「SDK の `@agent_app.activity("message")` ハンドラ内で発話テキストを取り出し、既存 `/chat` を内部 HTTP 呼び出しして応答を `send_activity()` で返す」だけの薄い層。
- 元プロジェクトとは**別ディレクトリ**で完全分離（元コード無改変）。
- APIM（案A）は、認証/レート制限/一元管理を足したい “第2段階” の選択肢。ただし Activity 解釈は APIM では完結しないため、SDK 終端の前段に置く構成になる。

---

## 4. 案B アダプタの構成（新規・独立ディレクトリ）

```
agent-a365-adapter/              # 既存プロジェクトとは別。元コード無改変
├── app/
│   └── main.py                  # aiohttp + Microsoft 365 Agents SDK で /api/messages を公開
│         ├ 着信 JWT 検証・Activity 解釈は SDK（jwt_authorization_middleware / CloudAdapter）に委譲
│         ├ @agent_app.activity("message") で発話テキストを取得
│         ├ 既存 ACA の /chat を内部 HTTP 呼び出し（CHAT_BACKEND_URL）
│         └ 応答を turn_context.send_activity() で返信
├── Dockerfile
├── deploy-aca.ps1
└── .env.example                 # CHAT_BACKEND_URL=https://<既存app>.azurecontainerapps.io
```

登録コマンド:
```powershell
a365 setup blueprint --endpoint-only `
  --messaging-endpoint https://<adapter>.azurecontainerapps.io/api/messages
```

### アダプタの責務（最小要件）
1. Microsoft 365 Agents SDK で `/api/messages` を終端（Agent 365 の受信口）
2. 着信認証の検証と Activity 解釈は **SDK に委譲**（自前実装しない）
3. SDK ハンドラから発話テキストを取り出す
4. 既存 `/chat` を内部呼び出し（`CHAT_BACKEND_URL`）
5. 応答を `send_activity()` で返信（プロアクティブ通知が要る場合は SDK の proactive 送信に拡張）

---

## 5. 推奨ロードマップ（SDK 終端を最短で立てる）

| フェーズ | 内容 | 成果 |
|---|---|---|
| **P1: SDK アダプタ実装** | `agent-extended/app/main.py` を雛形に、`/api/messages` を M365 Agents SDK で終端するアダプタを作成。発話テキスト → `/chat` 呼び出し → `send_activity()` 返信 | 同期対話の成立 |
| **P2: 登録・疎通** | ACA へデプロイ → `a365 setup blueprint --endpoint-only --messaging-endpoint .../api/messages` で登録 → Teams/Copilot から往復確認 | M365 エージェントとして成立 |
| **P3: 非同期対応**（必要時） | プロアクティブ送信が要るなら SDK の proactive 送信経路を追加 | 通知型メッセージ対応 |
| **P4: APIM 寄せ**（任意） | 認証/レート制限/一元管理を足すなら APIM を SDK 終端の前段に追加 | 運用堅牢化 |

---

## ⚠️ 補足（SDK に委譲することで解消する論点）

- **受信ペイロード／応答スキーマ**：**Bot Framework Activity スキーマ**で確定。Microsoft 365 Agents SDK が解釈するため、生スキーマを自前で扱う必要はない。SDK のメジャー更新で破壊的変更が来る可能性はあるが、`requirements.txt` でバージョン固定すれば境界化でき、これは過去の Teams ボット運用と同じリスクプロファイル。
- **着信認証**：SDK の `jwt_authorization_middleware` が channel トークンを検証する。検証パラメータ（issuer/audience）は `CONNECTIONS__SERVICE_CONNECTION__SETTINGS__*`（CLIENTID/TENANTID）から SDK が解決するため、自前で issuer/audience を採取・実装しない。
- **同期 / 非同期モデル**：基本は同期 request/response で成立。"agentic notification messages" のようなプロアクティブ送信が要る場合は SDK の proactive 送信 API を使う（APIM 単体では橋渡し不可なので案B が有利、という結論は変わらない）。

---

## ❓ 残る確認事項（実機で確定）

- プロアクティブ（非同期）通知が業務要件に含まれるか。含むなら SDK の proactive 送信経路を P3 で実装。
- Teams/Copilot 双方からの到達性（Apps カタログ掲載・承認フロー）が想定どおりか。

---

## 📚 参照元（一次情報）

- [Agent 365 CLI `setup` command reference (Microsoft Learn)](https://learn.microsoft.com/en-us/microsoft-agent-365/developer/reference/cli/setup) — `--m365` / `--messaging-endpoint` / `--endpoint-only`
- [Agent messaging endpoint (Microsoft Learn)](https://learn.microsoft.com/en-us/microsoft-agent-365/developer/agent-messaging-endpoint) — `a365.config.json` の `messagingEndpoint`、登録/更新/削除コマンド
- [Get started with Agent 365 development (Microsoft Learn)](https://learn.microsoft.com/en-us/microsoft-agent-365/developer/get-started)
- 対象エージェント仕様: `agent-custom-MAF-ACA-A365/README.md`（ローカル）

> 注：messaging スキーマは Bot Framework Activity、着信認証は Microsoft 365 Agents SDK が担う。自前のスキーマ採取・トークン検証実装は不要。アダプタは SDK 終端の上に薄く載せる方針とする。
