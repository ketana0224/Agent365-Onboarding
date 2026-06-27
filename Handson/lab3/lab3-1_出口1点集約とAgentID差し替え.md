# Lab3-1｜出口トークンを 1 点に集約し、Agent ID へ差し替える

> 親: [Handson README](../README.md) ／ 前: [lab2-3｜Agent ID 作成と統制検証](../lab2/lab2-3_AgentID作成.md)

## このステップの狙い

Lab2 の時点で、エージェントの外向き通信（LLM / MCP、いずれも APIM 経由）は **ACA のシステム割り当て MI（SAMI）** が出口だった。本ステップでは、出口トークンの取得を **コード上の 1 点（`_egress_token()`）に集約**したうえで、環境変数フラグ `USE_AGENT_ID_EGRESS=true` を立てて、出口を [lab2-3](../lab2/lab2-3_AgentID作成.md) で発行した **Agent ID（fmi_path 2 ステップ交換）に実際に差し替える**。

> **このステップで出口は SAMI → Agent ID に切り替わる**（`_egress_token()` を 1 点に集約しておくことで、フラグ 1 つの切替で済む）。Agent ID を止めて LLM/MCP を遮断するキルスイッチの検証は **後続ステップ（Lab4）** で行う。

| 項目 | Lab2 | lab3-1 |
|---|---|---|
| 出口 ID | SAMI（`DefaultAzureCredential`） | **Agent ID（fmi_path 2 ステップ交換）** |
| 出口トークンの取得箇所 | LLM / MCP で個別に取得 | **`_egress_token()` の 1 点に集約** |
| Agent ID への差し替え | 不可 | **`USE_AGENT_ID_EGRESS=true` で実施済み** |

---

## 差し替えの単一点（コードの実体）

本ラボの実行体は egress 版（[`agent-custom-MAF-ACA-A365-egress`](agent-custom-MAF-ACA-A365-egress/)）。Lab2 のエージェントと **同一指示・同一 MCP ツール・同一モデル・APIM 経由**で、差分は **出口トークンの取得を `_egress_token()` に集約した点だけ**。

```python
# app/config.py
def use_agent_id_egress() -> bool:
    return os.environ.get("USE_AGENT_ID_EGRESS", "false").lower() in ("1", "true", "yes")

# app/agent.py — 出口トークンの取得はここ 1 点だけ
async def _egress_token(scope: str) -> str:
    if config.use_agent_id_egress():
        return await _get_agent_id_provider().get_autonomous_token(scope)  # Agent ID (fmi_path)
    return await _msi_token(scope)                                          # SAMI (DefaultAzureCredential)
```

- **LLM**: フラグが立つと `OpenAIChatCompletionClient(credential=...)` に渡す資格情報を `DefaultAzureCredential` から `AgentIdCredential`（`get_token` で Agent ID リソーストークンを返す async 資格情報）に切り替える。
- **MCP**: `_mcp_headers()` の Bearer を `_egress_token(config.mcp_scope())` から取る。

```mermaid
flowchart LR
    a[agent.py] -->|"_egress_token(scope)"| sw{USE_AGENT_ID_EGRESS}
    sw -->|"false（既定）"| sami["SAMI<br/>DefaultAzureCredential"]
    sw -->|true| aid["Agent ID<br/>fmi_path 2 ステップ"]
    sami -->|"Bearer aud=cognitiveservices"| apim["APIM: apim-aigateway-eastus2"]
    aid  -->|"Bearer aud=cognitiveservices"| apim
    apim --> down["Foundry（LLM） / Contoso MCP"]
```

> APIM の `validate-azure-ad-token` は **audience と発行元のみ**検証し appid を見ないため、SAMI でも Agent ID でも `aud=https://cognitiveservices.azure.com` のトークンなら同じ API を通過する。**出口を差し替えても APIM 側の設定変更は不要**。

---

## 前提

| 項目 | 内容 |
|---|---|
| Lab2 完了 | egress 版が叩く APIM エンドポイント（LLM / MCP）は [lab2-2](../lab2/lab2-2_ACAカスタムエージェントデプロイ.md) と同じ。`.env` の `APIM_*` / `CONTOSO_MCP_URL` はそこから流用 |
| Agent ID 発行済み | [lab2-3](../lab2/lab2-3_AgentID作成.md) の `a365 setup all` で Blueprint / Agent Identity を発行済みであること。**本ラボでは再発行しない**（重複登録の事故になる） |
| Blueprint app ID | `BLUEPRINT_APP_ID`（lab2-3 の `a365.generated.config.json` の Blueprint appId） |
| Agent Identity app ID | `AGENT_IDENTITY_APP_ID`（同 Agent Identity appId）→ fmi_path に使う |
| Blueprint シークレット | `BLUEPRINT_CLIENT_SECRET`（lab2-3 の `agentBlueprintClientSecret` を DPAPI 復号した値）。ACA シークレット経由で注入 |

---

## 手順

### 1. `.env` を用意する

`prepare-env.ps1` が `.env.example` をベースに、lab2-3 の `a365.generated.config.json` から **Agent ID 値（`BLUEPRINT_APP_ID` / `AGENT_IDENTITY_APP_ID` / DPAPI 復号した `BLUEPRINT_CLIENT_SECRET`）** と、`az` から **テナント / サブスクリプション** を自動補完して `.env` を生成する（`USE_AGENT_ID_EGRESS=true` 固定＝出口を Agent ID に切り替える）。

> **受講者は 12 人（user01～user12）。Azure リソースは受講者ごとに分離する**ため、`-Me userNN` で自分の識別子を渡す。`prepare-env.ps1` が ACA 名を `-userNN` 化した `.env` を生成する（`ACA_RESOURCE_GROUP=rg-userNN` / `ACA_APP_NAME=custom-maf-agent-a365-egress-userNN` / `ACA_ENV_NAME=aca-contoso-agent-userNN`）。`rg-userNN` ・ `aca-contoso-agent-userNN` は Lab2 と同じものを再利用し、egress 版は app 名で区別されるので受講者間で衝突しない。

```powershell
cd C:\GitHub\Agent365-Onboarding\Handson\lab3\agent-custom-MAF-ACA-A365-egress
pwsh .\prepare-env.ps1 -Me userNN   # userNN は自分の番号に置き換える（例 user01）
# 既存 .env を上書きする場合は -Force
```

> Blueprint シークレットの復号は **lab2-3 で `a365 setup all` を実行したのと同一 Windows ユーザー**でのみ成功する。別ユーザー/別マシンでは `BLUEPRINT_CLIENT_SECRET` が空になるので、その値だけ手で補う。

> LLM / MCP は APIM 経由（`APIM_AOAI_ENDPOINT` / `CONTOSO_MCP_URL`、`.env.example` の既定値）で呼ぶため、`PROJECT_ENDPOINT` / `MODEL_DEPLOYMENT_NAME` は空のままで構わない（切り戻し用に残しているだけで lab3 の実行時には未使用）。

```ini
# prepare-env.ps1 が自動で入れる値（確認用）
AZURE_TENANT_ID=<az から>
AZURE_SUBSCRIPTION_ID=<az から>

# LLM / MCP は Lab2 と同じ APIM エンドポイント（.env.example の既定）
APIM_AOAI_ENDPOINT=https://apim-aigateway-eastus2.azure-api.net/openai
APIM_AOAI_DEPLOYMENT=gpt-5.4
CONTOSO_MCP_URL=https://apim-aigateway-eastus2.azure-api.net/contoso-policy/mcp

# --- 差し替えの単一点：出口を Agent ID に切り替える（true） ---
USE_AGENT_ID_EGRESS=true
BLUEPRINT_APP_ID=<lab2-3 の Blueprint appId>
AGENT_IDENTITY_APP_ID=<lab2-3 の Agent Identity appId>
BLUEPRINT_CLIENT_SECRET=<DPAPI 復号した Blueprint シークレット>
```

> 手で作る場合は `.env.example` をコピーして上記の値を埋めてもよい。
>
> Blueprint シークレットを単体で復号するワンライナー（同一 Windows ユーザー）:
>
> ```powershell
> $s = (Get-Content ..\..\lab2\a365.generated.config.json | ConvertFrom-Json).agentBlueprintClientSecret
> [Text.Encoding]::UTF8.GetString([Security.Cryptography.ProtectedData]::Unprotect([Convert]::FromBase64String($s), $null, 'CurrentUser'))
> ```

> `USE_AGENT_ID_EGRESS=true` で出口が Agent ID に切り替わる。Agent ID 用の 3 値（`BLUEPRINT_APP_ID` / `AGENT_IDENTITY_APP_ID` / `BLUEPRINT_CLIENT_SECRET`）は **fmi_path 2 ステップ交換に必須**なので、未設定だとデプロイ時にエラーになる。別ユーザー/別マシンで `BLUEPRINT_CLIENT_SECRET` が空のときは手で復号して補う。

### 2. egress 版エージェントをデプロイする（Agent ID 出口）

```powershell
pwsh .\deploy-aca.ps1
```

`deploy-aca.ps1` は次を行う:

1. `az acr build` で Dockerfile からイメージをビルド（ローカル Docker 不要）
2. 既存の ACA 環境（`aca-contoso-agent`、Lab2 と共用）に Container App `custom-maf-agent-a365-egress` を作成（外部 HTTPS, port 8000）
3. **システム割り当て MI（SAMI）を有効化**（ACA のホスト ID）。ただし**出口トークンは Agent ID（fmi_path）**が取得するため、SAMI は Foundry への直接アクセスには使わない（APIM 経由。`-FoundryResourceGroup` 指定時のみ防御的に `Azure AI Developer` を付与）
4. Blueprint シークレットを ACA シークレット（`blueprint-secret`）として登録し、`BLUEPRINT_CLIENT_SECRET=secretref:blueprint-secret` で注入

> UAMI の作成・割り当て・Graph 同意は **不要**。出口は Agent ID（fmi_path / Blueprint シークレット）が担い、ACA のホスト ID（SAMI）は Lab2 と同じまま。

### 3. Agent ID 出口で動くことを確認する

```powershell
python smoke_test.py https://<your-app-fqdn>
```

- `POST /chat` … `{"message":"返品ポリシーを教えて"}` → MCP ツールを呼んでポリシーに沿った回答が返る
- `GET /debug/auth` … `use_agent_id_egress=true`、Agent ID 出口で動作（`step2a_autonomous_token`＝fmi_path 2 ステップ目の交換が記録される）

---

## 確認

| チェック | 期待 |
|---|---|
| ACA の identity | system-assigned が有効、UAMI は割り当てなし |
| `USE_AGENT_ID_EGRESS` | `true`（出口は Agent ID） |
| Agent ID 用 env | `BLUEPRINT_APP_ID` / `AGENT_IDENTITY_APP_ID` / `BLUEPRINT_CLIENT_SECRET`（secretref）が投入済み |
| `/chat` | Agent ID 出口で APIM 経由の LLM / MCP が動く |

---

## トラブルシュート

| 症状 | 原因 | 対処 |
|---|---|---|
| LLM が 404（Resource not found） | コードが Responses API を叩いている | `OpenAIChatCompletionClient`（Chat Completions）を使う。汎用 `OpenAIChatClient` は不可（[lab2-2](../lab2/lab2-2_ACAカスタムエージェントデプロイ.md) 参照） |
| デプロイ時に Agent ID 値の不足エラー | `USE_AGENT_ID_EGRESS=true` なのに 3 値が未設定 | `BLUEPRINT_APP_ID` / `AGENT_IDENTITY_APP_ID` / `BLUEPRINT_CLIENT_SECRET` を `.env` に入れる。別ユーザー/別マシンは `BLUEPRINT_CLIENT_SECRET` を手で復号して補う |
| `/chat` が 401 / 403 | SAMI に Foundry ロール未付与 | `deploy-aca.ps1` の RBAC ステップ（`Azure AI Developer`）が成功したか確認 |

---

完了したら、Agent ID を止めて LLM / MCP を遮断するキルスイッチの検証（後続ステップ）に進む。
