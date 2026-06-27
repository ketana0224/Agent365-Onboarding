# Lab1-4｜AI teammate(true)

> 親: [Lab1 全体まとめ](README.md)
> 統制レベル: **最強**。Blueprint + 専用ユーザー アカウント（agentic user）を持ち、メールボックス / Teams / ディレクトリ / 上長関係まで人間社員と同等のガバナンスが効く（`aiTeammate=true`、Frontier 前提）。
> 一次情報: [Get started](https://learn.microsoft.com/microsoft-agent-365/developer/get-started)

> **本章 = 対象エージェント `contoso-helpdesk-a365` のビルド／検証記録（旧 Phase 1〜6）**。AI teammate 化の実装手順としてここを使う。
> 直下の §0〜§4 は単一エージェント前提で書かれた設計背景。統制レベル別の正しい全体像は [Lab1 全体まとめ](README.md) のマスター表を正とする。

---

## 0. なぜ作り直すのか（前提の訂正）

旧版 README の前提は **誤っていた**ため全面的に作り直す。

**旧前提（誤り）**
> 既存の自作エージェント `contoso-support-agent`（FastAPI `/chat`・ACA）を **作り直さず**、Agent 365 SDK で「薄く包む」だけで ①ID ②Observability ③Work IQ がすべて効く。

**実態（調査で確定）**

| 機能 | 成否 | 根拠 |
|---|---|---|
| ① Entra Agent ID（Blueprint/Instance） | ✓ 成立 | `a365 setup` で発行。**コード非依存** |
| ② Observability の **Activity ビュー export** | ✗ **不成立** | 観測トークンは **agentic ランタイム（TurnContext + AGENTIC 認証）で実行時に交換**するか、**publish + M365 管理センター追加で発行される agentic user** が必須。素の `/chat` にはどちらも無く、静的 FIC の Step3 が `AADSTS50034` で失敗 |
| ③ Work IQ（MCP ツール統制） | ✓ 成立 | `a365 develop` / tooling 拡張で登録可能 |
| ローカル Azure Monitor（App Insights） | ✓ 成立 | agentic ID 不要。常に出る |

**結論**: 「薄く包めば②も自動で効く」は誤り。
**② を Activity ビューに出すには、エージェントが Agent 365 のランタイム/チャネルに正しく載り、`a365 publish` → M365 管理センター追加（= agentic user 発行）まで到達する必要がある。**
旧 README は publish を「最後の可視化のおまけ（Step F）」扱いだったが、実際は **②が動くための前提条件**。

---

## 1. 方針

- 既存 `contoso-support-agent`（FastAPI `/chat`・ACA）は **観測 export 用の改造に向かない土台**のため、**触らない**。
- **新規エージェントを「agentic ランタイム前提」で作る**。これにより、実ターン中の `exchange_token(AGENTIC)` で観測トークンを取得でき、② が成立する。
- 新エージェント名（A365 登録名）: `contoso-helpdesk-a365`

---

## 2. 正しい土台（採用アーキテクチャ）

| 層 | 採用 | 理由 |
|---|---|---|
| エージェント本体 | **Microsoft 365 Agents SDK ホスティング** + Agent Framework(Python) | `@AGENT_APP.activity("message", auth_handlers=["AGENTIC"])` で **TurnContext** を受け取り、Teams/M365 から @mention で呼ばれる＝**実ターンが発生**する |
| 観測 | `microsoft-opentelemetry` Distro + runtime トークン交換 | 実ターン中に `exchange_token(AGENTIC, scopes=observability)` で観測トークン取得 → Activity ビューへ export |
| ID | `a365 setup all`（Blueprint + Instance） | コード非依存で発行 |
| ツール | `a365 develop add-mcp-servers` + tooling 拡張 | 既存 `contoso-policy-mcp` を統制下に登録 |
| 公開 | `a365 publish` → **M365 管理センターで追加** | **agentic user 発行 + チャネル招待の必須段階**（ここまで来て初めて②が動く） |
| ホスティング | ACA | 既存資産流用 |

> 旧版が示した「`AgenticTokenCache.get_observability_token()` を起動時に静的に叩く」リゾルバは、agentic user が無い限り `AADSTS50034` で失敗する（調査で確認済み）。
> 新版では **静的取得をやめ、実ターンの `TurnContext` から `exchange_token` する** 配線に変える。

---

## 3. 全体計画（フェーズ）

| Phase | 内容 | 状態 |
|---|---|---|
| **0** | 設計確定（名前 / 言語・FW / ホスティング先 / Blueprint 再利用可否） | ✅ 完了 |
| 1 | 新エージェントのスキャフォールド（M365 Agents SDK ベースの最小エージェント） | ✅ 完了（検証済み） |
| 2 | `a365 setup all` で Entra Agent ID（Blueprint+Instance）発行 | ✅ 完了 |
| 3 | Observability 配線（runtime トークン交換に変更） | ✅ 完了 |
| 4 | ホスティング & チャネル接続（@mention で呼べる状態へ） | ✅ 完了 |
| 5 | `a365 publish` → 管理センター追加 → **agentic user 発行を確認** | ✅ 完了（検証済み／管理センター承認は手動・要ライセンス） |
| 6 | 実ターンを発生させ **Activity ビューでスパン検証**（②のゴール） | ← **次はここ**（ポータル/ライセンス依存） |
| 7 | Work IQ（MCP）登録（`contoso-policy-mcp`） | 未 |
| 8 | ガバナンス（CA/Purview/Defender）が効くことを確認 | 未 |

各 Phase の詳細手順は、実行して確認できたものから本書に追記していく。

---

## 4. まずやること（Phase 0：設計確定）

**Phase 0 の確定結果（2026-06）**

1. 言語・FW: **Python + Agent Framework + M365 Agents SDK ホスティング**（aiohttp）
2. 新エージェント名: **`contoso-helpdesk-a365`**
3. ホスティング先: **ACA 継続**（Phase 4 でチャネル接続）
4. Blueprint: **新規でクリーンに作り直す**（既存 `contoso-support-a365` は触らない）

環境チェック（破壊的操作なし）:

```powershell
$env:PATH = "$env:USERPROFILE\.dotnet\tools;$env:PATH"
a365 --version
az account show --query "{tenant:tenantId, sub:id, user:user.name}" -o jsonc
```

---

## 5. Phase 1：新エージェントのスキャフォールド + ローカル検証（✅ 完了）

公式サンプル `microsoft/Agent365-Samples` の `python/agent-framework/sample-agent` を土台に、Contoso ヘルプデスク向けへカスタマイズし、ローカルで Entra キーレス認証 → gpt-5.4 応答まで検証した。

### 5.1 配置先

```
lab/Lab1/contoso-helpdesk-a365/
```

### 5.2 手順

**(1) 公式サンプルを取得して配置**

```powershell
# サンプルを一時クローンし sample-agent を contoso-helpdesk-a365 にコピー
git clone --depth 1 https://github.com/microsoft/Agent365-Samples "$env:TEMP\a365-sample"
Copy-Item -Recurse "$env:TEMP\a365-sample\python\agent-framework\sample-agent\*" `
  "C:\GitHub\Agent365-Onboarding\lab\Lab1\contoso-helpdesk-a365\"
```

**(2) 専用 venv を作成して依存を導入**

> ローカルに `python`/`py`/`uv` が無いため、ワークスペース venv の Python で専用 venv を作る。

```powershell
cd C:\GitHub\Agent365-Onboarding\lab\Lab1\contoso-helpdesk-a365
C:\GitHub\Agent365-Onboarding\.venv\Scripts\python.exe -m venv .venv
& ".\.venv\Scripts\python.exe" -m pip install --upgrade pip
& ".\.venv\Scripts\python.exe" -m pip install --pre -e .
```

**(3) コードを Contoso ヘルプデスク向けにカスタマイズ**

| ファイル | 変更点 |
|---|---|
| `agent.py` | クラス名 `AgentFrameworkAgent` → `ContosoHelpdeskAgent`、`AGENT_PROMPT` を Contoso ヘルプデスク ペルソナ（返品/経費/出張/デバイス/パスワード/IT ポリシー）に書き換え。プロンプト インジェクション対策のセキュリティ ルールは温存 |
| `start_with_generic_host.py` | `from agent import ContosoHelpdeskAgent` に変更 |
| `pyproject.toml` | `name`/`description` 更新。`agent-framework-azure-ai`（破損）を `agent-framework>=1.9.0` に置換 |
| `ToolingManifest.json` | 空（`{"mcpServers": []}`）。MCP は Phase 7 で登録 |
| `.env` | 新規作成（gitignore 済み）。Azure OpenAI / 観測 / AGENTIC 設定。Phase 1 はローカル検証用に `USE_AGENTIC_AUTH=false`・`ENABLE_A365_OBSERVABILITY_EXPORTER=false`（console） |

**agent-framework 1.9.0 への API 適応（重要）**

```python
# 旧サンプル(rc系)             # 1.9.0
from agent_framework import ChatAgent          → from agent_framework import Agent
from agent_framework.azure import AzureOpenAIChatClient
                                               → from agent_framework.openai import OpenAIChatClient
self.agent = ChatAgent(chat_client=...)        → self.agent = Agent(self.chat_client, instructions=..., tools=[])
```

- `agent-framework-azure-ai 1.0.0rc6` は core 1.9.0 で `ImportError: BaseContextProvider`（→ `ContextProvider` に改名）で壊れるため**除去**。
- `microsoft-opentelemetry 1.3.4` が `agent-framework>=1.4.0` を要求するため **1.9.0 固定**（rc 系へのダウングレード不可）。

**(4) キーレス（Entra ID）Azure OpenAI 認証**

Foundry アカウント `aif-foundryobs-jyenh` は**キー認証無効（Entra 専用）**。さらに openai 2.43 SDK は `azure_ad_token_provider` 単独だとベース クライアントが `Missing credentials` で失敗する。
解決策は **OpenAI 互換の `/openai/v1` サーフェスに `AsyncOpenAI` で接続し、Entra トークンを async callable な `api_key` として渡す**（agent-framework 内部と同じ経路）:

```python
from openai import AsyncOpenAI
from azure.identity import AzureCliCredential, get_bearer_token_provider

sync_token_provider = get_bearer_token_provider(
    AzureCliCredential(), "https://cognitiveservices.azure.com/.default"
)
async def _azure_token() -> str:
    return sync_token_provider()

azure_client = AsyncOpenAI(
    base_url=f"{endpoint.rstrip('/')}/openai/v1/",
    api_key=_azure_token,
)
self.chat_client = OpenAIChatClient(model=deployment, async_client=azure_client)
```

（API キーを `.env` に入れた場合は `OpenAIChatClient(model, azure_endpoint, api_version, api_key)` の分岐を使用）

### 5.3 検証コマンド

```powershell
cd C:\GitHub\Agent365-Onboarding\lab\Lab1\contoso-helpdesk-a365
& ".\.venv\Scripts\python.exe" -c @"
import warnings, asyncio
warnings.filterwarnings('ignore')
from dotenv import load_dotenv
load_dotenv('.env')
from agent import ContosoHelpdeskAgent

async def main():
    a = ContosoHelpdeskAgent()
    r = await a.agent.run('What is the standard policy for returning a faulty laptop?')
    print('LIVE RUN:', str(r)[:600])

asyncio.run(main())
"@
```

> **注意（ContextVar クラッシュ回避）**: `agent.run()` は **event loop の内側**で呼ぶ（`async def main()` 内で `await`）。`asyncio.run(agent.run(...))` のように loop の外で呼ぶと observability の計装が `Token created in a different Context` で落ちる。実 aiohttp ホストは単一 task 内なので問題ない。

### 5.4 検証結果

| 項目 | 結果 |
|---|---|
| 構築 | ✅ `OpenAIChatClient` + `Agent`（agent-framework 1.9.0） |
| 認証 | ✅ Entra キーレス（`AzureCliCredential`）→ `POST /openai/v1/responses` 200 OK |
| モデル応答 | ✅ gpt-5.4 が Contoso ヘルプデスク ペルソナで応答 |
| セキュリティ | ✅ プロンプト インジェクション対策が機能（出力上書き指示を拒否） |

**未確定/次フェーズ送り**: 完全な `/api/messages` 1ターンは Agents Playground/エミュレータと Phase 2 の接続設定が要るため、本フェーズは「構築 + 単発 `agent.run()`」で完了とする。

---

## 6. Phase 2：`a365 setup all` で Entra Agent ID 発行（✅完了）

### 6.1 コマンド

エージェント フォルダー（`lab/Lab1/contoso-helpdesk-a365`）で実行:

```powershell
a365 setup all --agent-name contoso-helpdesk-a365 --m365 --authmode both --verbose
```

- `--m365`：M365 エージェント扱い（messaging endpoint を MCP Platform 経由で登録、ただしエンドポイント自体は Phase 4 へ deferred）
- `--authmode both`：Delegated（OBO）＋ Application（S2S）両方の権限を付与 → Observability の `Agent365.Observability.OtelWrite` を両系統でカバー

### 6.2 実行上の注意（ハマりどころ）

- `--authmode both` は **S2S アプリ権限付与で `Assign this application permission now? [y/N]:` の対話入力**を求める。stdin が無い自動実行（CI / コーディング エージェント）では EOF で中断し `appsettings`/`.env` が未生成のまま終わる。
- 出力を `| Out-String` でラップすると**プロンプトが画面に出ずハング**して見える。
- 非対話で通すには **stdin に `y` を流し込む**（PowerShell では `Start-Process a365.exe ... -RedirectStandardInput <yを書いたファイル>`）。`a365.exe` は **フルパス**指定（`%USERPROFILE%\.dotnet\tools\a365.exe`）。
- 冪等：途中で失敗しても Blueprint/権限は再利用され、続きから再開できる（`a365.generated.config.json` に状態保存）。

### 6.3 発行された ID

| 項目 | 値 |
|---|---|
| Blueprint（clientId / objectId） | `b3c17234-d3ac-4426-8625-db89edbc8724` |
| Blueprint SP objectId | `d21783f0-f0b6-45d3-8405-11ed2ac3bb85` |
| **Agent identity（インスタンス）agenticAppId** | `a91b7e0b-d16f-4b06-8ba9-abc0d7023052` |
| Agent Registration ID | `T_451216e3-e7ab-0bcb-169f-9d9093c9f6fa` |

> ⚠️ Observability の `AGENT365OBSERVABILITY__AGENTID` は **インスタンス ID（`a91b7e0b…`）**。Blueprint ID を使うとスパン送信が 403（agent-ID 不一致）になる。CLI は自動で正しくスタンプ済み。

### 6.4 結果

- Python プロジェクトを検出し、`appsettings.json` ではなく **`.env` に直接** `CONNECTIONS__*` / `AGENTAPPLICATION__…AGENTIC__*` / `AGENT365OBSERVABILITY__*` / client secret をスタンプ。
- 同意済みリソース：Microsoft Graph（Mail/Chat/Files/ChannelMessage 等）/ Agent 365 Tools（`McpServersMetadata.Read.All`）/ Messaging Bot API（`AgentData.ReadWrite`）/ Observability API（`Agent365.Observability.OtelWrite`）/ Power Platform（`Connectivity.Connections.Read`）。
- messaging endpoint は **deferred**（Phase 4 でデプロイ後に `a365 setup blueprint --endpoint-only --messaging-endpoint <ACA-URL>`）。
- 秘密情報を含む `a365.generated.config.json` / `setup-all.*.log` / `setup-input.txt` は `.gitignore` 追加・一時ファイルは削除済み。

### 6.5 Phase 3 への引き継ぎ

`.env` を本番モードへ：`AUTH_HANDLER_NAME=AGENTIC` / `USE_AGENTIC_AUTH=true` / `ENABLE_A365_OBSERVABILITY_EXPORTER=true`。

---

## 7. Phase 3：Observability 配線（runtime トークン交換）（✅完了）

### 7.1 方式

スパン送信トークンは **実ターンの中で動的に交換**する（設計訂正どおり）。サンプル ホスト [host_agent_server.py](contoso-helpdesk-a365/host_agent_server.py) が次を実装済み：

- `use_microsoft_opentelemetry(enable_a365=True, a365_token_resolver=...)` で distro を初期化。`a365_token_resolver` はトークン キャッシュから読む。
- 実ターン毎に `_setup_observability_token()` が
  `exchange_token(context, scopes=get_observability_authentication_scope(), auth_handler_id="AGENTIC")`
  を実行し、結果を `cache_agentic_token(tenant_id, agent_id, token)` でキャッシュ。
- `agent_id` は **`context.activity.recipient.agentic_app_id`（= インスタンス ID）** を実行時に取得 → 403（agent-ID 不一致）を回避。

### 7.2 `.env` フラグ

| キー | 値 | 効果 |
|---|---|---|
| `AUTH_HANDLER_NAME` | `AGENTIC` | これが空だとトークン交換をスキップ。AGENTIC で本番交換が走る |
| `USE_AGENTIC_AUTH` | `true` | MCP ツールに agentic（OBO）トークンを渡す（[agent.py](contoso-helpdesk-a365/agent.py) `setup_mcp_servers`） |
| `ENABLE_A365_OBSERVABILITY_EXPORTER` | `true` | ドキュメント用フラグ（コード上は `enable_a365=True` 固定で常時 export） |

### 7.3 検証

- フラグ反映後もエージェントはローカルで正常構築（`AGENT CONSTRUCT: OK`）。
- 実スパンの送信検証は**実ターンが必要**なため Phase 6 で確認する（チャネル経由で `/api/messages` を 1 ターン流す）。

---

## 8. Phase 4：ホスティング & チャネル接続（✅完了）

### 8.1 ホスティング（ACA）

- 既存 ACA 環境 `aca-contoso-mcp` / 既存 ACR `cabfd24663bbacr` を再利用し、新規 Container App `contoso-helpdesk-a365` をデプロイ。
- イメージは `pyproject.toml` ベースで `pip install --pre .`（Windows ロックファイルは Linux 非互換の `pywin32` を含むため不使用）。
- システム割り当て MI を付与し、Foundry アカウント `aif-foundryobs-jyenh` に `Cognitive Services OpenAI User` を割り当て（**キーレス／Entra ID 認証**）。

| 項目 | 値 |
|---|---|
| Container App | `contoso-helpdesk-a365`（RG `rg-foundryobs-eastus2`） |
| App URL | `https://contoso-helpdesk-a365.gentleisland-42a91f9a.eastus2.azurecontainerapps.io` |
| Messaging | `…/api/messages` |
| Health | `…/api/health` → `{"status":"ok","agent_initialized":true}` |
| システム MI principalId | `d902d5a4-cef3-484b-87a8-cc3b8195869c` |
| イメージ | `cabfd24663bbacr.azurecr.io/contoso-helpdesk-a365:latest` |

- 起動ログ確認: `Using auth handler: AGENTIC` → `Using DefaultAzureCredential (Entra ID) authentication` → `Azure OpenAI chat client created` → `MCP tool service initialized` → `Running on http://0.0.0.0:3978`。

### 8.2 チャネル接続（メッセージング エンドポイント登録）

```pwsh
a365 setup blueprint --endpoint-only `
  --messaging-endpoint "https://contoso-helpdesk-a365.gentleisland-42a91f9a.eastus2.azurecontainerapps.io/api/messages" `
  --agent-name contoso-helpdesk-a365
```

- Blueprint `b3c17234-d3ac-4426-8625-db89edbc8724` にメッセージング エンドポイントを登録（`Registered successfully`）。`.env` へ設定を同期。

---

## 9. Phase 5：登録 / 権限 / 継承の検証（✅完了）

### 9.1 重要な気づき：本エージェントは blueprint ベース（agentic *user* は発行されない）

- `a365.config.json` は `aiTeammate=false` / `useBlueprint=true`。この種別では **Entra ディレクトリ ユーザーは作られず、Agent Identity SP（`a91b7e0b-d16f-4b06-8ba9-abc0d7023052`）のみ**が発行される（Phase 2 の `a365 setup all` で登録済み）。
- そのため `a365 publish` は **no-op**（`Nothing to publish for blueprint-based agents. Run 'a365 setup all' to register.`）。登録は `setup all` 側で完結している。
- 元の Phase 5 ゴール「agentic user 発行を確認」は本種別には当てはまらず、**確認対象は Agent Identity SP と権限継承**となる。

> ⚠️ 本章のゴールである **AI teammate(true)** にするには、`a365.config.json` を `aiTeammate=true` へ変更し（変更済み）、Frontier 前提で publish → 管理センターで **専用ユーザー アカウント（agentic user）** を発行する。現状の検証記録は blueprint(`false`)時点のもの。AI teammate 化の最終手順は §10 の実ターン検証と合わせて実施する。

### 9.2 検証結果（`a365 query-entra` / Graph）

- Blueprint SP（`d21783f0-…`）の OAuth2 同意済みスコープ:
  - Microsoft Graph: `Mail.ReadWrite Mail.Send Chat.ReadWrite User.Read.All Sites.Read.All Files.ReadWrite.All ChannelMessage.Read.All ChannelMessage.Send`
  - Messaging Bot API: `AgentData.ReadWrite`
  - Agent Tools: `McpServersMetadata.Read.All`
  - Power Platform API: `Connectivity.Connections.Read`
  - **Observability API: `Agent365.Observability.OtelWrite`**
- `query-entra inheritance`: 5/5 リソースで `Effective inheritance: OK`。**Observability API は scopes + app roles 両方が付与**され、インスタンスへの OtelWrite 継承が成立（= Phase 6 のスパン書き込み前提を満たす）。
  - 他リソースの Roles=WARN は委任スコープのみ必要なため benign。

### 9.3 残作業（手動・ライセンス依存）

- M365 管理センター（`https://admin.cloud.microsoft/#/agents/all`）でのエージェント承認/可視化は **ポータル操作**で、テナントの **Agent 365 Frontier プログラム参加 + 対応ライセンス**が前提。CLI からは自動化不可。

---

## 10. Phase 6：実ターン発生 → Activity ビューでスパン検証（手動手順）

> このフェーズは **Agent 365 Frontier ライセンス**前提のため、Teams からの実ターンと管理センターのポータル確認で進める。CLI では自動化できない。
>
> **メモ（実機確認 2026-06-22）**: blueprint ベースのエージェントは CLI 登録（Phase 2 `setup all` + Phase 4d messaging endpoint）だけで管理センター Registry に自動掲載され、**手動承認なしで Status: `Available`** になる（実機スクショで確認）。したがって下記 10.2 の「承認」操作は通常不要で、そのまま 10.3 の実ターンに進める。

### 10.1 前提チェック

- [ ] テナントが **Agent 365 Frontier プログラム**に参加済み（[adoption.microsoft.com/copilot/frontier-program](https://adoption.microsoft.com/copilot/frontier-program/)）
- [ ] 操作アカウント（`admin@M365CPI65139919.onmicrosoft.com`）に **Agent 365 / Copilot 対応ライセンス**が付与済み
- [ ] ACA エージェントが稼働中（`…/api/health` → `{"status":"ok","agent_initialized":true}`）
- [ ] メッセージング エンドポイント登録済み（Phase 4d 完了）
- [ ] Observability の OtelWrite 継承 OK（Phase 5.2 で確認済み）
- [x] 管理センター Registry に `contoso-helpdesk-a365 Agent` が **Status: `Available`** で掲載（実機確認済み）

### 10.2 管理センターでの状態確認（承認は通常不要）

1. M365 管理センター `https://admin.cloud.microsoft/#/agents/all` を開く
2. 一覧から **`contoso-helpdesk-a365 Agent`** を確認（Registration `T_451216e3-e7ab-0bcb-169f-9d9093c9f6fa` に対応）
3. **Status が `Available`** であることを確認（CLI 登録で自動的に Available。手動承認は不要）
4. 万一 `Available` でない場合のみ、ここで承認 / 公開先割り当てを実施

### 10.3 Teams 開発者ポータルで blueprint を構成（**必須・抜けやすい**）

> ⚠️ 管理センターで `Available` でも、この構成をしないと **Teams のアプリ検索に出てこない**（公式トラブルシュート：根本原因＝Developer Portal 未構成）。

1. ブラウザで開く（blueprint ID 入り）:
   `https://dev.teams.microsoft.com/tools/agent-blueprint/b3c17234-d3ac-4426-8625-db89edbc8724/configuration`
2. **Agent Type** = **API Based**
3. **Notification URL** = `https://contoso-helpdesk-a365.gentleisland-42a91f9a.eastus2.azurecontainerapps.io/api/messages`
4. **Save**（`Saved successfully` を確認）→ **5〜10 分**反映待ち

### 10.4 Teams でエージェントを追加 → インスタンス作成

1. Teams 左レール → **Apps（アプリ）**
2. 検索ボックスで **`contoso-helpdesk-a365`** を検索（5〜10 分で出現）
3. ヒットしたエージェントを選び **Add（追加）** → **Request Instance / Create Instance**
   - ボタンが効かない場合の根本原因＝**テナントで Agent 365 Frontier が未有効**。管理者に有効化を依頼

### 10.5 実ターンを 1 回流す

1. 追加したエージェントとのチャットで質問を送る
   - 例: `What is the standard policy for returning a faulty laptop?`
2. エージェントが応答することを確認（応答が来れば `/api/messages` 1 ターンが成立）
   - 失敗時の切り分け: ACA ログ `az containerapp logs show -n contoso-helpdesk-a365 -g rg-foundryobs-eastus2 --tail 60 --type console`

### 10.6 Activity ビューでスパンを検証

1. 管理センター `https://admin.cloud.microsoft/#/agents/all` → **`contoso-helpdesk-a365`** → **Activity** タブを開く
2. 直近のターンに対応する **トレース / スパン**が表示されることを確認
   - 期待: エージェント実行スパン + Azure OpenAI 呼び出し + （MCP 連携時は）ツール呼び出しスパン
3. スパンの `AGENTID` が **インスタンス ID `a91b7e0b-d16f-4b06-8ba9-abc0d7023052`** と一致することを確認（Blueprint ID ではない）

### 10.7 スパンが出ない場合の切り分け

- ACA ログに `_setup_observability_token` 由来の `exchange_token` / `cache_agentic_token` が出ているか
- ログに OtelWrite トークン交換の 403 が出ていないか（出る場合は Phase 5.2 の継承を再確認）
- `.env` の `AUTH_HANDLER_NAME=AGENTIC` がコンテナに渡っているか（空だと token 交換がスキップされ export されない）
- `AGENT365OBSERVABILITY__AGENTID` がインスタンス ID（`a91b7e0b…`）になっているか
