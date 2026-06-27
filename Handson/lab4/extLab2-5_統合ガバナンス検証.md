# extLab2-5: 出口を Agent ID に切替え、Agent ID 停止で MCP/LLM を遮断する

> 親: [extLab2 README](README.md) ／ 前: [extLab2-4 Agent ID 出口化（配線と検証）](extLab2-4_AgentID出口化_配線と検証.md)

## このステップの狙い

extLab2-4 でコードは Agent ID 出口に結線済み。本ステップでは **冒頭で出口を Agent ID に切り替え**（`USE_AGENT_ID_EGRESS=true`）、その状態でガバナンス（停止・統制・監査）が **3 層**で効くことを確認する。中核は **(a) Agent ID を止めると LLM / MCP が実際に止まる**キルスイッチ。

| 層 | 効かせる場所 | 効く対象 |
|---|---|---|
| (a) Agent ID（出口主体） | Agent Identity の無効化 / 条件付きアクセス（CA）/ 削除 | **Agent ID が出口の LLM / MCP**（止めると弾かれる） |
| (b) AI Gateway | APIM のポリシー（token limit / content safety / audience 検証） | LLM / MCP の APIM 通過分 |
| (c) A365 ネイティブ観測性 | Agent 365 SDK 計装 + `OtelWrite` ロール | per-span トレースの Defender / 管理センター / Purview への export |

> (b) は Azure 汎用の統制。**(a) は Agent 365 が握る Agent ID を主体にしたキルスイッチ**で、Agent ID を止めれば実トラフィック（LLM / MCP）が確実に止まる。**(c) が「Agent 365 だからこそできる」観測性検証**。

> ⚠️ UAMI は Bot 認証・Key Vault 取得・Graph 用に残る（土台）。**LLM / MCP の出口は 2-5 で Agent ID に切り替わる**ため、LLM / MCP を止めたいときは UAMI ではなく **Agent ID を止める**。

---

## 0. 出口を Agent ID に切り替える

extLab2-4 で結線したコードを、`USE_AGENT_ID_EGRESS=true` で有効化する。Blueprint シークレットは ACA シークレット（Key Vault 参照）で供給する。

```powershell
$RG  = 'rg-foundryobs-eastus2'
$APP = 'custom-maf-agent-a365-ext'

# Blueprint シークレットを ACA シークレット (Key Vault 参照) として登録
az containerapp secret set -g $RG -n $APP `
  --secrets "blueprint-secret=keyvaultref:https://<kv-name>.vault.azure.net/secrets/blueprint-client-secret,identityref:<UAMI-resource-id>"

# 出口を Agent ID に切替（フラグ + Agent ID 設定 + シークレット参照）
az containerapp update -g $RG -n $APP --set-env-vars `
  "USE_AGENT_ID_EGRESS=true" `
  "AZURE_TENANT_ID=655bd66a-5001-4cb3-9aad-ce54a27d5d95" `
  "BLUEPRINT_APP_ID=<blueprint-app-id>" `
  "AGENT_IDENTITY_APP_ID=<agentic-app-id>" `
  "BLUEPRINT_CLIENT_SECRET=secretref:blueprint-secret"
```

> 出口化に必要なのは **Blueprint + Agent Identity（SP）の 2 つだけ**（fmi_path の Step1/Step2a は SP で成立し、agentic user は不要）。既存の Agent ID がある場合は **[extLab2-0](extLab2-0_AgentID発行.md) で発行済みの Agent ID をそのまま流用**してよい（`BLUEPRINT_APP_ID` / `AGENT_IDENTITY_APP_ID` に extLab2-0 の値を指定）。未発行なら **[extLab2-0 §4](extLab2-0_AgentID発行.md)（`a365 setup all`）** で Blueprint + Agent Identity を発行すれば足りる（= モード(1)「素の setup all」）。専用ユーザー(agentic user)・メールボックス・Purview DLP まで含むフル aiTeammate 統制まで欲しい場合のみ [Lab1-5](../Lab1/Lab1-5_extLab2をA365フル機能化.md)（`--aiteammate`）を任意で適用する。配線コードの詳細は [extLab2-4](extLab2-4_AgentID出口化_配線と検証.md)。

### 0-1. 切替の確認（正常系）

```powershell
# 起動ログで出口トークンが Agent ID になったか
az containerapp logs show -g $RG -n $APP `
  --revision (az containerapp show -g $RG -n $APP --query properties.latestRevisionName -o tsv) `
  --tail 40 | Select-String -Pattern "出口トークン"

# Teams で 1 ターン流したあと、トークンの主体を確認
$fqdn = az containerapp show -g $RG -n $APP --query properties.configuration.ingress.fqdn -o tsv
curl -s "https://$fqdn/debug/auth" | ConvertFrom-Json | Select-Object -Last 4 | Format-List
```

| 確認 | 期待 |
|---|---|
| 起動ログ | `[ok] 出口トークン: Agent ID (fmi_path 2 ステップ交換)` |
| `step1_parent_token` | `grant_type: client_credentials + fmi_path`、aud = `api://AzureADTokenExchange` |
| `step2a_autonomous_token` | `appid / azp` が **Agent ID**（UAMI clientId `c7824504-...` ではない）、aud = `https://cognitiveservices.azure.com` |
| Teams で通常会話 / 「返品ポリシーは？」 | LLM 応答・MCP `get_return_policy` とも 200（Agent ID トークンが APIM audience 検証を通過） |

> `/debug/auth` は検証専用。本番では `auth_meta` ともども削除する。

---

## A. APIM（AI Gateway）で統制する

### A-1. audience 検証（既定で有効）

APIM に投入済みのポリシー（Lab2 の APIM 経由構成）には `validate-azure-ad-token`（`aud=https://cognitiveservices.azure.com`）が入っている。**不正な audience / トークン無しは APIM が 401 で弾く**。

```powershell
# トークン無し → 401
curl -s -o /dev/null -w "%{http_code}`n" -X POST `
  "https://apim-aigateway-eastus2.azure-api.net/openai/deployments/gpt-5.4/chat/completions?api-version=2024-10-21" `
  -H "Content-Type: application/json" -d '{"messages":[{"role":"user","content":"x"}]}'

# 別 audience（graph）のトークン → 401
$bad = az account get-access-token --resource https://graph.microsoft.com --query accessToken -o tsv
curl -s -o /dev/null -w "%{http_code}`n" -X POST `
  "https://apim-aigateway-eastus2.azure-api.net/openai/deployments/gpt-5.4/chat/completions?api-version=2024-10-21" `
  -H "Authorization: Bearer $bad" -H "Content-Type: application/json" -d '{"messages":[{"role":"user","content":"x"}]}'
```

| 入力 | 期待 |
|---|---|
| トークン無し | 401 |
| `aud=graph` のトークン | 401 |
| `aud=cognitiveservices` のトークン | 200 |

### A-2. トークン レート制限（任意で追加）

`azure-openai` API のインバウンド ポリシーに `azure-openai-token-limit` を追加すると、トークン消費に上限をかけられる。

```xml
<azure-openai-token-limit counter-key="@(context.Request.Headers.GetValueOrDefault('Authorization','anon'))"
                          tokens-per-minute="1000"
                          estimate-prompt-tokens="true"
                          remaining-tokens-header-name="x-ratelimit-remaining-tokens" />
```

> 上限超過で APIM が 429 を返し、エージェントの LLM 呼び出しが止まる。`remaining-tokens-header-name` で残量を監視できる。

### A-3. コンテンツ安全性（任意で追加）

`llm-content-safety` ポリシー（Azure AI Content Safety 連携）で、プロンプト/応答の有害コンテンツを APIM 層でブロックできる。

```xml
<llm-content-safety backend-id="content-safety-backend" shield-prompt="true">
  <categories output-type="EightSeverityLevels">
    <category name="Hate" threshold="4" />
    <category name="Violence" threshold="4" />
  </categories>
</llm-content-safety>
```

### A-4. MCP 側の停止

`contoso-policy-mcp` の named value `contoso-mcp-key` を失効・差し替えると、APIM → MCP バックエンドが認証エラーになり MCP ツールが止まる（エージェント側はキーを持たないので、ここを締めれば確実に止まる）。

---

## B. Agent ID を止める（キルスイッチ・最重要）

出口を Agent ID に切り替えた（Step 0）ので、**Agent ID を止めると、エージェント（ACA コンテナ）は起動したまま LLM / MCP が閑で弾かれる**。これが Agent 365 主体のキルスイッチ。

### B-1. Agent Identity を無効化する

> **ポータルでこの autonomous 出口（fmi_path）を止めるには、次のどちらでもよい（この環境では実機で確認済み・両方とも SP `accountEnabled=false` に帰着する）:**
> 1. **M365 管理センター（admin.microsoft.com）> Agents > Registry > 対象エージェント > Block**
> 2. **Entra 管理センター > Entra ID > Agents > Agent identities > 対象 > Disable**
>
> **【実機検証 2026-06-24】M365 管理センターの「Block」は、Entra agent identity を持つエージェントに対して、その Agent Identity SP の `accountEnabled=false` へカスケードする。** Block 直後に監査ログへ `Core Directory > Update service principal / accountEnabled: true → false`（initiator = 操作した管理者）が記録され、fmi_path Step2a が **`AADSTS7000112: Application '<agent-id>' is disabled`** で失敗 → Teams に `Step2a (autonomous) failed: HTTP 400` / `AgentIdTokenError` が返る。M365 管理センターの該当エージェントは `Blocked` 表示・"You've blocked this agent. It has been removed from all users in your organization." となり、`Unblock` で復旧（→ `accountEnabled: false → true`）。下記 `accountEnabled` の Graph PATCH は、この Block/Unblock を CLI で行う等価操作。
>
> | 統制 | 一次ソースの定義 | この出口（ACA→Entra→APIM、M365 ホスト非経由）を止めるか |
> |---|---|---|
> | **M365 Block**（admin.microsoft.com） | "by using **the same controls that work for any other app**" / "Agent remains in registry but becomes inactive. **Users can't invoke or interact with the agent**"（[agent-actions](https://learn.microsoft.com/microsoft-365/admin/manage/agent-actions?view=o365-worldwide#block-or-unblock-agents)・[agent-registry](https://learn.microsoft.com/microsoft-agent-365/builder/agent-registry)） | ✅ **止まる（実機確認）**。ドキュメントは「M365 ホスト面のユーザー利用統制」としか書かないが、**Entra agent identity を持つエージェントでは Block が SP `accountEnabled=false` にカスケードし、autonomous トークン発行（Step2a）も `AADSTS7000112` で止まる**。＝下記 Graph PATCH の GUI 版 |
> | **Entra Disable**（=B-1 Graph PATCH） | "Disable a specific agent identity to **block its access and token issuance**"（[manage-agent-identities-admin](https://learn.microsoft.com/entra/agent-id/manage-agent-identities-admin#disable-or-restrict-agent-identities)・[disable-agent-identities](https://learn.microsoft.com/entra/agent-id/disable-agent-identities)） | ✅ **止まる**（実機で Step2a が `AADSTS7000112` で失敗）。M365 Block と同一の `accountEnabled=false` 状態 |
> | **CA Policy 1**（=B-2） | "Block agent identity authentication"＝autonomous トークン発行を tenant 横断でブロック | ✅（Workload Identities Premium / P1 必要） |
>
> ※ 当初 doc は「M365 Block は token issuance を止めるとは文書化されていない（=根拠なし）」と記述していたが、**実機検証の結果これは誤りで、M365 Block は agent identity を持つエージェントでは accountEnabled へカスケードして autonomous 出口を止める**ため訂正した。なお [agent-actions](https://learn.microsoft.com/microsoft-365/admin/manage/agent-actions?view=o365-worldwide#block-or-unblock-agents) には「同じ統制が他アプリ同様に効く」とあり、SP 無効化（accountEnabled）はその「他アプリ同様の統制」の実体と整合する。CA Policy 3 の "leaving agent-to-agent and **autonomous flows unaffected**" は CA の条件付き制御の話で、SP 無効化（Block/Disable）とは別軸。

> Windows では `az rest` が `az.cmd`（cmd.exe ラッパー）経由のため、URI 内の `( ) ? $ =` 等の特殊文字が cmd に食われてクォートが外れ、`--uri/--headers/--body の使い方が誤っています` と誤報告される。回避策は **az.cmd を経由しない PowerShell ネイティブの `Invoke-RestMethod`**（トークンのみ az で取得し、Graph 呼び出しは PowerShell で行う）。

```powershell
$token = az account get-access-token --resource https://graph.microsoft.com --query accessToken -o tsv
$agentId = '9ff24e53-7789-41f2-9039-c19257f8f852'   # AGENT_IDENTITY_APP_ID（Lab1-2 発行・custom-maf-agent-a365 Identity）
$headers = @{ Authorization = "Bearer $token"; 'Content-Type' = 'application/json' }
Invoke-RestMethod -Method Patch `
  -Uri "https://graph.microsoft.com/v1.0/servicePrincipals(appId='$agentId')" `
  -Headers $headers -Body '{"accountEnabled": false}'
# 確認（False になれば成功）
(Invoke-RestMethod -Method Get -Uri "https://graph.microsoft.com/v1.0/servicePrincipals(appId='$agentId')?`$select=accountEnabled" -Headers $headers).accountEnabled
```

| 観測点 | 期待 |
|---|---|
| ACA の `/healthz` | 200（コンテナは生きている） |
| Teams で会話 | LLM / MCP が応答しない（fmi_path Step 2 の自律トークン発行が `AADSTS7000112`（SP 無効）で失敗）。実機では Teams に `Step2a (autonomous) failed: HTTP 400` / `AgentIdTokenError` が返る |
| `/debug/auth` | `step2a_autonomous_token` が `cache=miss` でエラー（無効化前に発行済みのトークンは `cache=hit` で生き残る） |

#### ⚠️ 重要: Disable は「即時遮断」ではない（トークン キャッシュ TTL）

`accountEnabled=false` で止まるのは **新規トークン発行（fmi_path Step2a の `cache=miss` 経路）だけ**。エージェントは **すでに発行済みの Agent ID リソース トークン（`aud=https://cognitiveservices.azure.com`・`expires_in≈3599`＝約1時間）をプロセス内キャッシュ**（[agent_id_token.py](agent-extended/app/agent_id_token.py) のスレッドセーフ キャッシュ、60s セーフティ スキュー付き）から使い回すため、**無効化後もキャッシュ TTL（最大約1時間）＋ Entra 伝播のラグの間は LLM / MCP が通り続ける**。`/debug/auth` で `step2a_autonomous_token cache=hit` が並んでいればこの状態。

即座に効かせる（デモで今すぐ止める）には、**ACA リビジョンを restart してプロセス内キャッシュをクリア**する。次のターンで新規 Step2a（`cache=miss`）が走り、SP 無効化により `AADSTS7000112` で失敗 → LLM / MCP が停止する（`/healthz` は 200 のまま）。

```powershell
az containerapp revision restart -g rg-foundryobs-eastus2 `
  -n custom-maf-agent-a365-ext `
  --revision custom-maf-agent-a365-ext--0000014
```

> 本番運用では、エージェント停止を「即時」に近づけたいなら **(a) トークン キャッシュ TTL を短くする**（その分トークン発行リクエストが増える）、**(b) CA（B-2）でセッション制御を併用**、**(c) コンテナの定期 restart / health 連動**などを設計に織り込む。Disable 単独は「新規発行を止める」統制であり、既発行トークンの寿命までは効かない点を前提にする。

復旧:

```powershell
$token = az account get-access-token --resource https://graph.microsoft.com --query accessToken -o tsv
$agentId = '9ff24e53-7789-41f2-9039-c19257f8f852'   # AGENT_IDENTITY_APP_ID
$headers = @{ Authorization = "Bearer $token"; 'Content-Type' = 'application/json' }
Invoke-RestMethod -Method Patch `
  -Uri "https://graph.microsoft.com/v1.0/servicePrincipals(appId='$agentId')" `
  -Headers $headers -Body '{"accountEnabled": true}'
```

### B-2. 条件付きアクセス（CA）で Agent ID をブロックする

Entra の CA で Agent Identity の SP を対象にした Block ポリシーを有効化すると、fmi_path Step 2 のトークン発行が **`AADSTS53003`** で失敗し、LLM / MCP が止まる。

> CA でワークロード ID（Agent Identity の SP）を対象にするには **Microsoft Entra Workload Identities Premium** が必要。

### B-3. Agent Identity を削除する（恒久遮断）

A365 管理センター / Entra で Agent Identity を削除すると、fmi_path 交換そのものが成立せず LLM / MCP は恒久的に止まる。Agent 365 のライフサイクル統制（Disable → Delete）が実トラフィックに直結することを示す。

### B-4.（副次）UAMI は Bot 認証専用になる

出口を Agent ID に切り替えた後、UAMI は **Bot 認証・Key Vault 取得・Graph（`get_my_profile`）**にのみ使われる。UAMI を無効化すると Bot 受信や Graph は止まるが、**LLM / MCP を止めたいなら Agent ID を止める**（B-1～B-3）のが筋。`USE_AGENT_ID_EGRESS=false` に戻せば出口は UAMI に戻り、その場合は UAMI 統制が LLM / MCP にも効く。

---

## C. Agent 365 ネイティブ観測性を検証する（extLab2 で「A365 だからできる」検証）

A（APIM）と B（Agent ID）は Azure 汎用の統制で、Agent 365 でなくても成立する。**Agent 365 でしか取れない検証**は、エージェントの per-span トレースが **Agent 365 観測性バックエンド（実体は Microsoft Defender 基盤）に届き、Defender / Microsoft 365 管理センター / Microsoft Purview の 3 面で見える**こと。extLab2 は **Agent 365 SDK の MAF 計装**を組み込んでいるので、この A365 ネイティブ export を検証できる。

> ⚠️ 区別: **Application Insights（C-3）は Azure Monitor へのローカル OTel であって A365 ネイティブではない**。A365 面（管理センター / Defender / Purview）に出るのは C-1/C-2 の経路のみ。

### C-1. SDK 計装が有効化されたことを確認する（前提チェック）

`main.py` の `_configure_observability()` が起動時に Agent 365 SDK の MAF 計装を試行する（パッケージ `microsoft-agents-a365-observability-extensions-agent-framework`）。起動ログに次が出ていれば計装は有効。

```powershell
$RG = 'rg-foundryobs-eastus2'
az containerapp logs show -g $RG -n custom-maf-agent-a365-ext `
  --revision (az containerapp show -g $RG -n custom-maf-agent-a365-ext --query properties.latestRevisionName -o tsv) `
  --tail 60 | Select-String -Pattern "Agent 365 SDK|計装"
```

| 出力 | 意味 |
|---|---|
| `[ok] Agent 365 SDK の MAF 計装を有効化しました。` | 計装 OK（スパン生成は始まる） |
| 出力なし | パッケージ未導入か import 失敗 → A365 面には何も出ない |

> 計装が有効でも、後段の **OtelWrite 権限とトークン配管（C-2）が無いと A365 バックエンドには届かない**。計装＝生成、export ＝送信は別物。

### C-2. A365 観測性バックエンドへ export できることを検証する

A365 の Direct OTel イングレスは「**エージェントの appId（=トークンの `appid`/`azp`）と URL の `{agentId}` が一致**」かつ「**`Agent365.Observability.OtelWrite` ロールを持つトークン**」を要求する。観測性 export は **LLM / MCP の出口切替（Step 0）とは独立**で、Bot appId = `c7824504-433e-4d54-a0ae-e16d724f9dc7`（UAMI clientId）に `OtelWrite` を付ければ custom-engine 構成のまま export できる（agentic user 登録は不要）。

**(1) UAMI の SP に OtelWrite アプリ ロールを付与（前提・1 回だけ）**

```powershell
$tenant   = '655bd66a-5001-4cb3-9aad-ce54a27d5d95'
$agentId  = 'c7824504-433e-4d54-a0ae-e16d724f9dc7'   # UAMI clientId = Bot appId
$obsResId = '9b975845-388f-4429-889e-eab1ef63949c'   # A365 Observability リソース appId

# UAMI と A365 観測性リソースの SP を解決
$uamiSp = az ad sp show --id $agentId --query id -o tsv
$obsSp  = az rest --method get `
  --uri "https://graph.microsoft.com/v1.0/servicePrincipals(appId='$obsResId')" --query id -o tsv
$roleId = az rest --method get `
  --uri "https://graph.microsoft.com/v1.0/servicePrincipals/$obsSp" `
  --query "appRoles[?value=='Agent365.Observability.OtelWrite'].id | [0]" -o tsv

# OtelWrite を UAMI に割り当て（管理者同意相当の appRoleAssignment）
az rest --method post `
  --uri "https://graph.microsoft.com/v1.0/servicePrincipals/$uamiSp/appRoleAssignments" `
  --headers "Content-Type=application/json" `
  --body (@{ principalId=$uamiSp; resourceId=$obsSp; appRoleId=$roleId } | ConvertTo-Json)
```

> このロール割り当てが **A365 でしかできない統制ポイント**。外せばエージェントは A365 観測性へ書けなくなる（＝観測の停止も A365 側で制御できる）。

**(2) Direct OTel 疎通テスト（SDK と独立に export 経路を確認）**

UAMI トークンで最小スパンを 1 件 POST し、`200 OK` を確認する。`{agentId}` はトークンの appId と一致必須。

```powershell
$token = az account get-access-token --resource "$obsResId/.default" --query accessToken -o tsv
$uri   = "https://agent365.svc.cloud.microsoft/observabilityService/tenants/$tenant/otlp/agents/$agentId/traces?api-version=1"
curl -i -X POST $uri `
  -H "Authorization: Bearer $token" -H "Content-Type: application/json" `
  --data '@otlp-request.json'
# 期待: 200 OK / { "partialSuccess": null }
```

| 結果 | 切り分け |
|---|---|
| `200` + `partialSuccess: null` | export 経路 OK |
| `401` | OtelWrite ロール未付与、または token の audience 不一致 |
| `403` / `rejectedSpans` | `{agentId}` と token の `appid` 不一致、または span 必須属性（`gen_ai.operation.name` 等）欠落 |

> `otlp-request.json` の組み立て（OTLP/HTTP+JSON、`traceId`/`spanId` の hex、必須属性）は [Observability_DirectOTel_と格納先.md](../Observability_DirectOTel_と格納先.md) の「最小リクエスト」を参照。

**(3) 実ターンを流して A365 の 3 面で確認**

Teams で「返品ポリシーは？」を 1 回送り、数分後に確認する。

| 面 | 確認内容 |
|---|---|
| **M365 管理センター（Agent 管理）** | 該当エージェントの Activity に `invoke_agent` / `chat` / `execute_tool`（MCP `get_return_policy`）スパンが出る |
| **Microsoft Defender** | エージェント アクティビティ／脅威面でのトレース |
| **Microsoft Purview** | 監査ログ（誰が・いつ・どのツールを呼んだか） |

> 出ない場合は C-1（計装）→ C-2(1)（OtelWrite）→ C-2(2)（疎通 200）の順に切り分ける。**App Insights には出るが A365 面に出ない**なら、原因はローカル OTel は動いていて A365 export 経路（OtelWrite / agentId 一致）が未成立。

### C-3. （参考）Application Insights = ローカル OTel

A365 ネイティブではないが、`APPLICATIONINSIGHTS_CONNECTION_STRING` があれば Azure Monitor にも同じトレースをファンアウトできる（A365 面の代替ではなく追加宛先）。

```powershell
$appId = az monitor app-insights component show -g $RG -a <app-insights-name> --query appId -o tsv
az monitor app-insights query --app $appId `
  --analytics-query "dependencies | where timestamp > ago(15m) | project timestamp, name, target, resultCode | take 50"
```

> 詳細は [Observability_DirectOTel_と格納先.md](../Observability_DirectOTel_と格納先.md) と [_report/A365_Observability_Export_調査結果.md](../../_report/A365_Observability_Export_調査結果.md) を参照。

---

## 検証マトリクス（まとめ）

| 操作 | LLM | MCP | Graph | 観測性 | 効く層 |
|---|---|---|---|---|---|
| **Agent Identity 無効化** | **止まる** | **止まる** | — | — | **(a) Agent ID** |
| **Agent ID への CA Block** | **止まる** | **止まる** | — | — | **(a) Agent ID** |
| **Agent Identity 削除** | **止まる（恒久）** | **止まる（恒久）** | — | — | **(a) Agent ID** |
| APIM audience 検証 | 止まる | 止まる | — | — | (b) AI Gateway |
| APIM token limit | 429 で制限 | — | — | — | (b) AI Gateway |
| APIM content safety | ブロック | — | — | — | (b) AI Gateway |
| named value 失効 | — | 止まる | — | — | (b) AI Gateway |
| OtelWrite ロール付与/取消 | — | — | — | A365 面に出る / 止まる | (c) A365 ネイティブ観測性 |
| （副次）UAMI 割り当て解除 | ※2 | ※2 | 止まる | 止まる | UAMI（Bot/Graph） |

> ※2 出口が Agent ID のときは LLM / MCP は Agent ID トークンで動くため UAMI 解除では止まらない。`USE_AGENT_ID_EGRESS=false`（UAMI 出口）に戻した場合のみ UAMI 解除で LLM / MCP も止まる。

> **ポイント**: extLab2 は出口を **Agent ID（fmi_path）に切り替え + APIM 1 ゲートウェイ**に集約したため、「身分証だけ統制しても実トラフィックが残る」という旧構成の欠落が解消されている。**Agent ID を止めれば LLM / MCP が、APIM を締めれば LLM / MCP が確実に止まる**。さらに Agent 365 だからこそ、per-span トレースが Defender / 管理センター / Purview の 3 面に集約され、`OtelWrite` ロール 1 つで観測の有効化／停止まで A365 側で制御できる（C）。

> **extLab2 スコープの注記**: 本 extLab2 は Agent ID を **出口トークン**として採用し、Disable / CA / Delete が LLM / MCP に効くことを検証する（B）。さらに上位の A365 ネイティブ統制（agentic user としての条件付きアクセス、Purview DLP / 保持ポリシー）はフル AI teammate 登録（Blueprint + agentic user）が前提。発行手順は [Lab1-5](../Lab1/Lab1-5_extLab2をA365フル機能化.md)、AI teammate は [Lab1-4](../Lab1/Lab1-4_AIteammate.md) を参照。

---

これで extLab2 は完了。全体像は [extLab2 README](README.md) を参照。
