# extLab2-1: ワークロード ID を UAMI 1 本に集約する

> 親: [extLab2 README](README.md) ／ 次: [extLab2-2 APIM AI Gateway化](extLab2-2_APIM_AI_Gateway化.md)

## このステップの狙い

エージェントの **外向き通信の出口を 1 本のユーザー割り当てマネージド ID（UAMI）に集約**する。Bot 認証・LLM 呼び出し・MCP 呼び出し・Graph 呼び出しのすべてを、同じ UAMI から `DefaultAzureCredential` でトークン取得する形にする。

> **この時点（土台）で使うもの**: UAMI 1 本（`DefaultAzureCredential`）。シークレットレスで ACA（Linux コンテナ）でそのまま動く。**OBO は最後まで不採用**（ユーザー文脈は Teams の `aad_object_id` + Graph アプリ権限で代替）。**Blueprint シークレット / fmi_path（Agent ID 親子トークン交換）は extLab2-1〜3 では使わないが、[extLab2-4](extLab2-4_AgentID出口化_配線と検証.md) でコード配線し、[extLab2-5](extLab2-5_統合ガバナンス検証.md) で出口を Agent ID に切り替える**（Agent ID を止めると LLM / MCP が遮断されるキルスイッチ）。

| 項目 | Before（Lab1） | After（extLab2-1） |
|---|---|---|
| ワークロード ID | ACA システム割り当て MI | **UAMI（ユーザー割り当て）1 本** |
| Bot 認証 | なし（独自 `/chat`） | UAMI（`UserAssignedMSI`）※ Teams 接続は extLab2-3 |
| LLM / MCP / Graph トークン | 個別の方式 | **`DefaultAzureCredential` で UAMI に統一** |

---

## トークンの取り方（コードの実体）

`agent-extended/app/agent.py` は `azure.identity.aio.DefaultAzureCredential` を 1 つ生成し、用途ごとに `get_token(scope)` するだけ。

```python
# build_agent() 内（抜粋・実装イメージ）
from azure.identity.aio import DefaultAzureCredential

credential = DefaultAzureCredential()      # ACA 上では UAMI を解決
set_credential(credential)                  # モジュール内で共有
```

| 用途 | scope | 取得方法 |
|---|---|---|
| LLM（APIM 経由 Foundry） | `https://cognitiveservices.azure.com/.default` | `AzureOpenAIChatClient(credential=...)` が内部で取得 |
| MCP（APIM 経由） | `https://cognitiveservices.azure.com/.default`（APIM の `apim_scope()`） | `_msi_token(scope)` で取得し `Authorization: Bearer` |
| Graph（`get_my_profile`） | `https://graph.microsoft.com/.default` | `_msi_token(GRAPH_SCOPE_DEFAULT)` で取得 |

> `DefaultAzureCredential` は、ローカル開発では `az login` の資格情報、ACA 上では割り当てられた UAMI を自動解決する。コードを変えずに開発／本番を切り替えられる。

---

## 手順

### 1. UAMI を作成する

```powershell
$RG   = 'rg-foundryobs-eastus2'      # ACA / UAMI を置く RG（既存 ACA 環境 aca-contoso-agent と同じ RG）
$LOC  = 'eastus2'
$UAMI = 'uami-contoso-agent-ext'

az identity create -g $RG -n $UAMI -l $LOC
$uamiId       = az identity show -g $RG -n $UAMI --query id -o tsv
$uamiClientId = az identity show -g $RG -n $UAMI --query clientId -o tsv
$uamiPrincipal= az identity show -g $RG -n $UAMI --query principalId -o tsv
"UAMI resourceId  : $uamiId"
"UAMI clientId    : $uamiClientId"
"UAMI principalId : $uamiPrincipal"
```

### 2. UAMI に必要な RBAC / Graph 権限を付与する

| 付与先 | ロール / 権限 | 用途 |
|---|---|---|
| Foundry（`aif-ketana-prod-eastus2`） | `Cognitive Services OpenAI User`（`5e0bd9bd-7b93-4f28-af87-19fc36ad61bd`） | LLM を APIM 経由で呼ぶ際のトークン audience 整合（APIM 側 MI でも別途付与する。extLab2-2 参照） |
| Microsoft Graph | アプリ権限 `User.Read.All`（管理者同意） | `get_my_profile` が本人と上司を取得 |

> LLM / MCP のバックエンド認証は **APIM の MI** が担う（[extLab2-2](extLab2-2_APIM_AI_Gateway化.md)）。UAMI 側は「APIM に Bearer を投げる」ためのトークン（`aud=https://cognitiveservices.azure.com`）を取得できれば十分。Graph だけは UAMI が直接アプリ権限で叩くので、Graph アプリ権限の管理者同意が必要。

Graph アプリ権限（`User.Read.All`）を UAMI（= マネージド ID のサービス プリンシパル）に付与する例:

```powershell
# Graph の appRoleId（User.Read.All / Application）
$graphSp   = az ad sp show --id 00000003-0000-0000-c000-000000000000 --query id -o tsv
$appRoleId = az ad sp show --id 00000003-0000-0000-c000-000000000000 `
    --query "appRoles[?value=='User.Read.All' && contains(allowedMemberTypes,'Application')].id | [0]" -o tsv

# UAMI の SP（principalId）に appRole を付与
# ※ az rest の --body はインライン JSON だと PowerShell の引用符処理で壊れて
#   「Unable to read JSON request payload」になるため、BOM なしの一時ファイル渡しにする。
$body = @{ principalId = $uamiPrincipal; resourceId = $graphSp; appRoleId = $appRoleId } | ConvertTo-Json -Compress
$tmp  = New-TemporaryFile
[System.IO.File]::WriteAllText($tmp.FullName, $body, (New-Object System.Text.UTF8Encoding($false)))
az rest --method post `
  --uri "https://graph.microsoft.com/v1.0/servicePrincipals/$uamiPrincipal/appRoleAssignments" `
  --headers "Content-Type=application/json" `
  --body "@$($tmp.FullName)"
Remove-Item $tmp -ErrorAction SilentlyContinue
```

### 3. 拡張版エージェントを ACA にデプロイする

extLab2 の拡張版は **Lab1 とは別アプリ**（`custom-maf-agent-a365-ext`）として、既存の ACA 環境 `aca-contoso-agent` に作る。`agent-extended/` のソースから ACR クラウドビルドでデプロイする。

```powershell
$RG  = 'rg-foundryobs-eastus2'         # 手順 1 で設定済みなら省略可
$ENV = 'aca-contoso-agent'             # 既存 ACA 環境（Lab1 と共用）
$APP = 'custom-maf-agent-a365-ext'
$ACR = 'acaagent4y3b81'                # Lab1 と同じ ACR を再利用
$IMG = "$ACR.azurecr.io/custom-maf-agent-a365-ext:latest"

cd C:\GitHub\Agent365-Onboarding\lab\extLab2\agent-extended

# 1) Dockerfile でイメージをビルド（agent-framework-core はプレリリースなので Dockerfile の --pre が必須）
az acr build -r $ACR -t $IMG .

# 2) ACA を作成（既存環境に新規アプリとして）
az containerapp create `
  -g $RG -n $APP `
  --environment $ENV `
  --image $IMG `
  --registry-server "$ACR.azurecr.io" `
  --ingress external --target-port 8000
```

> **`az containerapp up --source .` は使わない**。`up` は Dockerfile を無視して Oryx 自動ビルドに回ることがあり、その場合 `pip install` に `--pre` が付かず `agent-framework-core`（プレリリース）の解決に失敗する（`No matching distribution found for agent-framework-core`）。`az acr build` は本ディレクトリの `Dockerfile`（`python:3.11-slim` + `pip install --pre`）をそのまま使うので確実。
>
> 2 回目以降（イメージ更新）は `az acr build ...` の後に `az containerapp update -g $RG -n $APP --image $IMG` を実行する。

> 環境変数（LLM/MCP の APIM エンドポイント等）は [extLab2-2](extLab2-2_APIM_AI_Gateway化.md) 以降で設定する。ここではまずアプリ本体を起動できる状態にする。

### 4. ACA に UAMI を割り当てる

```powershell
az containerapp identity assign -g $RG -n $APP --user-assigned $uamiId
```

ACA 上で `DefaultAzureCredential` が UAMI を解決できるよう、環境変数で clientId を指定しておく（UAMI が複数割り当たる場合の曖昧さ回避）。

```powershell
az containerapp update -g $RG -n $APP `
  --set-env-vars "AZURE_CLIENT_ID=$uamiClientId"
```

### 5. `.env` を埋める

`agent-extended/.env.example` をベースに `.env` を作る。

```ini
# --- UAMI 出口 ---
AZURE_TENANT_ID=655bd66a-5001-4cb3-9aad-ce54a27d5d95
AZURE_CLIENT_ID=<uami の clientId>

# --- Bot（M365 Agents SDK / UserAssignedMSI）※ extLab2-3 で使用 ---
CONNECTIONS__SERVICE_CONNECTION__SETTINGS__AUTHTYPE=UserAssignedMSI
CONNECTIONS__SERVICE_CONNECTION__SETTINGS__CLIENTID=<bot app id>
CONNECTIONS__SERVICE_CONNECTION__SETTINGS__TENANTID=655bd66a-5001-4cb3-9aad-ce54a27d5d95

# --- LLM / MCP は extLab2-2 で APIM のエンドポイントを設定 ---
```

---

## 確認

```powershell
# ACA に UAMI が割り当たっているか
az containerapp show -g $RG -n $APP --query "identity.userAssignedIdentities" -o json

# UAMI が Graph アプリ権限を持つか
az rest --method get `
  --uri "https://graph.microsoft.com/v1.0/servicePrincipals/$uamiPrincipal/appRoleAssignments" `
  --query "value[].appRoleId"
```

| チェック | 期待 |
|---|---|
| ACA の identity | `userAssignedIdentities` に UAMI が 1 件 |
| `AZURE_CLIENT_ID` | UAMI の clientId と一致 |
| Graph appRoleAssignments | `User.Read.All` の appRoleId が含まれる |

---

## トラブルシュート

| 症状 | 原因 | 対処 |
|---|---|---|
| `DefaultAzureCredential` が SystemAssigned を拾う | `AZURE_CLIENT_ID` 未設定で複数 ID が曖昧 | `AZURE_CLIENT_ID=<uami clientId>` を必ず設定 |
| `get_my_profile` が 403 | Graph アプリ権限の管理者同意漏れ | `User.Read.All`（Application）の同意を確認 |
| ローカルで 401 | `az login` のユーザーに Graph / Foundry 権限がない | ローカルは委任権限ユーザーで `az login`、本番は UAMI |

---

完了したら **[extLab2-2: LLM と MCP を APIM AI Gateway に集約する](extLab2-2_APIM_AI_Gateway化.md)** に進む。
