# agent-custom-MAF-ACA-A365-egress（C: Agent ID 出口化）

extLab2 のカスタム MAF エージェント系列で、**B と D の中間段**にあたるアプリです。

| | アプリ | 役割 |
|---|---|---|
| A | `agent-custom-MAF-ACA` | カスタム MAF を ACA に置いた素の状態（UAMI 出口） |
| **B** | `agent-custom-MAF-ACA-A365` | A に **Agent 365 登録**（Agent ID 発行）を足した状態。コードは A と同一で、出口は **UAMI のまま** |
| **C（本アプリ）** | `agent-custom-MAF-ACA-A365-egress` | **B と同一のホスト**（同一指示・同一 MCP ツール・同一モデル・APIM 経由）に、**Agent ID 出口化**（fmi_path 2 ステップ交換）だけを足した状態 |
| D | `agent-extended` | C に加えて Teams 連携（M365 Agents SDK）・Graph ツール・OBO（ユーザー委任）まで足したフル版 |

つまり C は「**B の Agent ID を“発行しただけ”の状態から、実トラフィックの出口を Agent ID に切り替える**」ことだけにフォーカスした検証用アプリです。Teams / Agents SDK / Graph `get_my_profile` / OBO は含みません（出口は常に **自律型**）。

---

## B との差分

- 追加モジュール:
  - `app/agent_id_token.py` … fmi_path 2 ステップ交換（Step1: Blueprint+secret+fmi_path → 親トークン / Step2a: Agent Identity を client_id にした jwt-bearer → リソーストークン）。
  - `app/auth_meta.py` … トークン交換の introspection（非機微クレームのみ保持。`/debug/auth` で参照）。
- `app/agent.py`:
  - 出口トークン取得を `_egress_token(scope)` に集約。`USE_AGENT_ID_EGRESS=true` なら Agent ID（自律型）、それ以外は UAMI。
  - LLM 側は `AgentIdCredential`（`get_token` で Agent ID リソーストークンを返す async 資格情報）を `OpenAIChatCompletionClient(credential=...)` に渡す。
  - MCP 側は `_mcp_headers()` の Bearer を `_egress_token` 経由にする。
- `app/main.py`: `GET /debug/auth` を追加（出口トークン種別・クレーム確認用。本番は無効化推奨）。
- `requirements.txt`: `httpx` を追加（トークン交換に使用）。
- `deploy-aca.ps1`: `USE_AGENT_ID_EGRESS` / `AZURE_TENANT_ID` / `BLUEPRINT_APP_ID` / `AGENT_IDENTITY_APP_ID` を環境変数に、`BLUEPRINT_CLIENT_SECRET` を **ACA シークレット（secretref:blueprint-secret）** として注入。

B から **削除**したもの（D にあるが C には不要）: Teams / M365 Agents SDK、Graph `get_my_profile` ツール、`SENDER_*` の contextvars、OBO のホスト利用。

---

## 前提（Agent ID は B のものを再利用）

C は **新しい Agent ID を発行しません**。B（`agent-custom-MAF-ACA-A365`）で `a365 setup all` 済みの Blueprint / Agent Identity をそのまま使います。

1. B 側で発行済みの値を取得し、本アプリの `.env` に設定します。
   - `BLUEPRINT_APP_ID`（B の `a365.generated.config.json` の Blueprint appId）
   - `AGENT_IDENTITY_APP_ID`（同 Agent Identity appId）
   - `BLUEPRINT_CLIENT_SECRET`（B の `agentBlueprintClientSecret` を復号した値）
     - DPAPI で暗号化されているため、同一 Windows ユーザーで復号:
       ```powershell
       $s = (Get-Content .\..\agent-custom-MAF-ACA-A365\a365.generated.config.json | ConvertFrom-Json).agentBlueprintClientSecret
       [Text.Encoding]::UTF8.GetString([Security.Cryptography.ProtectedData]::Unprotect([Convert]::FromBase64String($s), $null, 'CurrentUser'))
       ```
2. `a365.config.json` は B と同一（同じ表示名 → 同じ Agent ID に解決）にしてありますが、**C で `a365 setup all` を再実行する必要はありません**（実行すると重複登録の事故につながります）。

---

## セットアップ・デプロイ

```powershell
cd lab\extLab2\agent-custom-MAF-ACA-A365-egress
Copy-Item .env.example .env
# .env を編集（PROJECT_ENDPOINT / APIM_* / CONTOSO_MCP_URL / APPLICATIONINSIGHTS_CONNECTION_STRING /
#            USE_AGENT_ID_EGRESS=true / BLUEPRINT_APP_ID / AGENT_IDENTITY_APP_ID / BLUEPRINT_CLIENT_SECRET）

pwsh .\deploy-aca.ps1
```

`deploy-aca.ps1` は `az acr build` でイメージを作成し、ACR + Container Apps 環境 + Container App（外部 HTTPS Ingress, port 8000）を構成、システム割り当て MI を有効化し Foundry へ「Azure AI Developer」を付与します（出口を Agent ID にしても、切り戻し・MCP legacy のため UAMI は確保）。

### ローカル実行

```powershell
python -m venv .venv; .\.venv\Scripts\Activate.ps1
pip install --pre -r requirements.txt
uvicorn app.main:app --host 0.0.0.0 --port 8000
```

---

## 動作確認

```powershell
python smoke_test.py https://<your-app-fqdn>
```

- `POST /chat` … `{"message": "..."}` → `{"agent": "...", "reply": "..."}`
- `GET /debug/auth` … 直近のトークン交換イベント（`use_agent_id_egress` と各フェーズの aud/appid/exp）を確認。Agent ID 出口化が効いていれば `step2a_autonomous_token` が記録されます。

### 出口の切替（UAMI ⇄ Agent ID）

`USE_AGENT_ID_EGRESS` は**起動時に評価**されます。切り替えたら ACA リビジョンを再起動してください。

```powershell
az containerapp update -n custom-maf-agent-a365-egress -g rg-foundryobs-eastus2 `
  --set-env-vars USE_AGENT_ID_EGRESS=true
az containerapp revision restart -n custom-maf-agent-a365-egress -g rg-foundryobs-eastus2 `
  --revision $(az containerapp revision list -n custom-maf-agent-a365-egress -g rg-foundryobs-eastus2 --query "[-1].name" -o tsv)
```

### 統制の検証（Agent ID が実トラフィックに効く）

Agent ID 出口化が有効なとき、Entra Agent ID の統制が **LLM/MCP の実呼び出し**に効きます。

- **M365 admin center > Agents > Registry > 対象 > Block**、または **Entra 管理センター > Agents > Agent identities > 対象 > Disable**（= SP `accountEnabled=false`）にすると、Step2a が `AADSTS7000112: Application is disabled` で失敗し、`/chat` の LLM/MCP 出口が止まります。
- ただし **新規トークン発行のみ**止まり、発行済みリソーストークン（TTL≈3599s）はプロセス内キャッシュで残るため、**即時遮断には ACA リビジョン再起動**が必要です。
- CA ポリシー「Block agent identity authentication」でも止まります（Workload Identities Premium 必要）。

---

## ファイル

| パス | 説明 |
|---|---|
| `app/config.py` | 設定読み込み（B の全項目 + Agent ID 出口化項目） |
| `app/agent.py` | MAF エージェント本体（B 同等 + Agent ID 出口化） |
| `app/agent_id_token.py` | fmi_path 2 ステップ交換のトークンプロバイダ |
| `app/auth_meta.py` | トークン交換 introspection（非機微クレーム） |
| `app/main.py` | FastAPI ホスト（`/chat` ほか + `/debug/auth`） |
| `Dockerfile` | コンテナ定義（uvicorn, port 8000） |
| `requirements.txt` | 依存（B + `httpx`） |
| `deploy-aca.ps1` | ACA デプロイ（Agent ID 出口化対応） |
| `smoke_test.py` | 疎通テスト |
| `.env.example` | 設定例 |
| `a365.config.json` | B と同一（同じ Agent ID に解決） |
