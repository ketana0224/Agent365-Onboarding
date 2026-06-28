#requires -Version 7.0
<#
.SYNOPSIS
    MAF ホスト型エージェント（Agent ID 出口化 + OBO 版）を Azure Container Apps にデプロイします。

.DESCRIPTION
    lab3 / lab4 の Agent ID 出口化版（egress）の deploy-aca.ps1 と同一仕様（Contoso サポート・
    同一指示・同一 MCP ツール・同一モデル・APIM 経由・Agent ID 出口化）に加え、
    OBO（ユーザー委任型）の設定（BLUEPRINT_API_AUDIENCE / GRAPH_SCOPE）を投入します。

    1. .env を読み込み（APIM / MCP / App Insights / Agent ID 出口化 / OBO 設定など）
    2. Azure CLI / containerapp 拡張 / リソースプロバイダーを確認・登録
    3. `az acr build --file Dockerfile` で ACR にイメージを明示ビルドし、
       ACR + Container Apps 環境 + Container App（外部 HTTPS Ingress, port 8000）を作成
    4. Blueprint クライアント シークレットを ACA シークレット（blueprint-secret）として注入
    5. システム割り当てマネージド ID（SAMI）を有効化
    6. 公開 URL をコンソールに出力

.NOTES
    OBO を使う前に scripts\01〜03 を実行して、Blueprint の OAuth API 化（identifierUri /
    access_as_user スコープ / preAuthorizedApplications / optionalClaims）、OBO クライアント アプリ、
    Agent Identity の Graph 委任付与（User.Read / User.ReadBasic.All）を済ませてください。
#>

[CmdletBinding()]
param(
    [string]$EnvFile,
    [string]$SubscriptionId,
    [string]$ResourceGroup,
    [string]$Location,
    [string]$AppName,
    [string]$EnvName,
    [string]$FoundryResourceGroup,
    [string]$AiRole = 'Azure AI Developer',
    [switch]$SkipRbac
)

$ErrorActionPreference = 'Stop'
$repoRoot = $PSScriptRoot
if (-not $EnvFile) { $EnvFile = Join-Path $repoRoot '.env' }

Write-Host '== MAF ホスト型エージェント（Agent ID 出口化 + OBO 版）デプロイ (Azure Container Apps) ==' -ForegroundColor Cyan

# --- 0. .env 読み込み ----------------------------------------------------------
if (-not (Test-Path $EnvFile)) {
    throw ".env が見つかりません: $EnvFile`n.env.example をコピーして値を埋めてください。"
}
$envMap = @{}
foreach ($line in Get-Content $EnvFile) {
    $t = $line.Trim()
    if ($t -and -not $t.StartsWith('#') -and $t.Contains('=')) {
        $k, $v = $t -split '=', 2
        $envMap[$k.Trim()] = $v.Trim()
    }
}

if (-not $SubscriptionId)        { $SubscriptionId        = $envMap['AZURE_SUBSCRIPTION_ID'] }
if (-not $Location)              { $Location              = if ($envMap['AZURE_LOCATION']) { $envMap['AZURE_LOCATION'] } else { 'eastus2' } }
if (-not $ResourceGroup)         { $ResourceGroup         = if ($envMap['ACA_RESOURCE_GROUP']) { $envMap['ACA_RESOURCE_GROUP'] } else { 'rg-foundryobs-eastus2' } }
if (-not $AppName)               { $AppName               = if ($envMap['ACA_APP_NAME']) { $envMap['ACA_APP_NAME'] } else { 'custom-maf-a365-obo' } }
if (-not $EnvName)               { $EnvName               = if ($envMap['ACA_ENV_NAME']) { $envMap['ACA_ENV_NAME'] } else { 'aca-contoso-agent' } }

$projectEndpoint = $envMap['PROJECT_ENDPOINT']
$modelDeployment = if ($envMap['AGENT_MODEL_DEPLOYMENT_NAME']) { $envMap['AGENT_MODEL_DEPLOYMENT_NAME'] } else { $envMap['MODEL_DEPLOYMENT_NAME'] }
$appInsightsConn = $envMap['APPLICATIONINSIGHTS_CONNECTION_STRING']
$mcpUrl          = $envMap['CONTOSO_MCP_URL']
$mcpKey          = $envMap['CONTOSO_MCP_KEY']
# APIM AI Gateway 経由（LLM + MCP）
$apimAoaiEndpoint   = $envMap['APIM_AOAI_ENDPOINT']
$apimAoaiDeployment = if ($envMap['APIM_AOAI_DEPLOYMENT']) { $envMap['APIM_AOAI_DEPLOYMENT'] } else { $modelDeployment }
$apimAoaiApiVersion = $envMap['APIM_AOAI_API_VERSION']
$apimScope          = $envMap['APIM_SCOPE']
$mcpResourceAppId   = $envMap['MCP_RESOURCE_APP_ID']
$mcpScope           = $envMap['MCP_SCOPE']
# Agent ID 出口化
$useAgentIdEgress   = if ($envMap['USE_AGENT_ID_EGRESS']) { $envMap['USE_AGENT_ID_EGRESS'] } else { 'false' }
$tenantId           = $envMap['AZURE_TENANT_ID']
$blueprintAppId     = $envMap['BLUEPRINT_APP_ID']
$agentIdAppId       = $envMap['AGENT_IDENTITY_APP_ID']
$blueprintSecret    = $envMap['BLUEPRINT_CLIENT_SECRET']
# OBO（ユーザー委任型）
$blueprintApiAudience = $envMap['BLUEPRINT_API_AUDIENCE']
$graphScope           = $envMap['GRAPH_SCOPE']

# PROJECT_ENDPOINT / MODEL_DEPLOYMENT_NAME は APIM 経由化後は未使用（切り戻し用）。
if (-not $apimAoaiEndpoint) { throw '.env に APIM_AOAI_ENDPOINT がありません（APIM 経由化に必須）。' }
if (-not $apimAoaiDeployment) { throw '.env に APIM_AOAI_DEPLOYMENT がありません（APIM 経由化に必須）。' }

# OBO（/obo-chat の get_my_profile）には Agent ID 構成が必須。
foreach ($pair in @(
    @{ Name = 'AZURE_TENANT_ID'; Value = $tenantId },
    @{ Name = 'BLUEPRINT_APP_ID'; Value = $blueprintAppId },
    @{ Name = 'AGENT_IDENTITY_APP_ID'; Value = $agentIdAppId },
    @{ Name = 'BLUEPRINT_CLIENT_SECRET'; Value = $blueprintSecret }
)) {
    if (-not $pair.Value) {
        throw "OBO 版には Agent ID 構成が必須ですが .env に $($pair.Name) がありません。scripts\01〜03 と prepare-env.ps1 を実行してください。"
    }
}
# BLUEPRINT_API_AUDIENCE 未設定なら api://<blueprint> を既定にする
if (-not $blueprintApiAudience) { $blueprintApiAudience = "api://$blueprintAppId" }
if (-not $graphScope)           { $graphScope = 'https://graph.microsoft.com/.default' }

# --- 0b. 前提確認 --------------------------------------------------------------
if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw 'Azure CLI (az) が見つかりません。'
}
if (-not $SubscriptionId) { $SubscriptionId = az account show --query id -o tsv 2>$null }
if (-not $SubscriptionId) { throw 'サブスクリプションが特定できません。az login を実行するか -SubscriptionId を指定してください。' }
az account set --subscription $SubscriptionId | Out-Null

Write-Host '[0/5] containerapp 拡張 / プロバイダーを確認...' -ForegroundColor Yellow
az extension add --name containerapp --upgrade --only-show-errors 2>$null | Out-Null
az provider register --namespace Microsoft.App --wait 2>$null | Out-Null
az provider register --namespace Microsoft.OperationalInsights --wait 2>$null | Out-Null
az provider register --namespace Microsoft.ContainerRegistry --wait 2>$null | Out-Null

# --- 1. RG 確認 ----------------------------------------------------------------
az group create -n $ResourceGroup -l $Location --only-show-errors | Out-Null

# --- 2. Dockerfile でイメージをビルドして Container App をデプロイ ---------------
Write-Host "[1/5] イメージをビルドして Container App をデプロイ（数分かかります）..." -ForegroundColor Yellow
$envVars = @(
    "APIM_AOAI_ENDPOINT=$apimAoaiEndpoint",
    "APIM_AOAI_DEPLOYMENT=$apimAoaiDeployment",
    "USE_AGENT_ID_EGRESS=$useAgentIdEgress",
    "BLUEPRINT_API_AUDIENCE=$blueprintApiAudience",
    "GRAPH_SCOPE=$graphScope",
    "PORT=8000"
)
# PROJECT_ENDPOINT / MODEL_DEPLOYMENT_NAME は切り戻し用。設定されている場合のみ渡す。
if ($projectEndpoint)   { $envVars += "PROJECT_ENDPOINT=$projectEndpoint" }
if ($modelDeployment)   { $envVars += "MODEL_DEPLOYMENT_NAME=$modelDeployment" }
if ($envMap['AGENT_MODEL_DEPLOYMENT_NAME']) { $envVars += "AGENT_MODEL_DEPLOYMENT_NAME=$($envMap['AGENT_MODEL_DEPLOYMENT_NAME'])" }
if ($apimAoaiApiVersion) { $envVars += "APIM_AOAI_API_VERSION=$apimAoaiApiVersion" }
if ($apimScope)         { $envVars += "APIM_SCOPE=$apimScope" }
if ($mcpResourceAppId)  { $envVars += "MCP_RESOURCE_APP_ID=$mcpResourceAppId" }
if ($mcpScope)          { $envVars += "MCP_SCOPE=$mcpScope" }
if ($appInsightsConn)   { $envVars += "APPLICATIONINSIGHTS_CONNECTION_STRING=$appInsightsConn" }
if ($mcpUrl)            { $envVars += "CONTOSO_MCP_URL=$mcpUrl" }
if ($mcpKey)            { $envVars += "CONTOSO_MCP_KEY=$mcpKey" }
# Agent ID 出口化（シークレット以外）
if ($tenantId)       { $envVars += "AZURE_TENANT_ID=$tenantId" }
if ($blueprintAppId) { $envVars += "BLUEPRINT_APP_ID=$blueprintAppId" }
if ($agentIdAppId)   { $envVars += "AGENT_IDENTITY_APP_ID=$agentIdAppId" }
# Blueprint シークレットは ACA シークレット（secretref）として注入する
if ($blueprintSecret) { $envVars += "BLUEPRINT_CLIENT_SECRET=secretref:blueprint-secret" }

# ACR 名（RG 内に無ければ作成）。英数字のみ・グローバル一意にするため suffix を付与。
$acrName = ($envMap['ACA_ACR_NAME'])
if (-not $acrName) {
    $suffix  = -join ((97..122) + (48..57) | Get-Random -Count 6 | ForEach-Object { [char]$_ })
    $acrName = "acaagent$suffix"
}
$existingAcr = az acr show -n $acrName -g $ResourceGroup --query name -o tsv 2>$null
if (-not $existingAcr) {
    Write-Host "      ACR を作成: $acrName" -ForegroundColor DarkGray
    az acr create -n $acrName -g $ResourceGroup --sku Basic --admin-enabled true --only-show-errors | Out-Null
}
$image = "$acrName.azurecr.io/$($AppName):latest"

Push-Location $repoRoot
try {
    Write-Host "      Dockerfile から ACR ビルド: $image" -ForegroundColor DarkGray
    az acr build --registry $acrName --image "$($AppName):latest" --file Dockerfile . --only-show-errors
    if ($LASTEXITCODE -ne 0) { throw 'az acr build に失敗しました。' }

    # Container Apps 環境を用意（無ければ作成）
    $envExists = az containerapp env show -n $EnvName -g $ResourceGroup --query name -o tsv 2>$null
    if (-not $envExists) {
        Write-Host "      Container Apps 環境を作成: $EnvName" -ForegroundColor DarkGray
        az containerapp env create -n $EnvName -g $ResourceGroup -l $Location --only-show-errors | Out-Null
    }

    $acrPassword = az acr credential show -n $acrName --query "passwords[0].value" -o tsv
    $appExists = az containerapp show -n $AppName -g $ResourceGroup --query name -o tsv 2>$null
    if ($appExists) {
        # 先にレジストリ資格情報とシークレットを登録してから image を更新する
        az containerapp registry set -n $AppName -g $ResourceGroup `
            --server "$acrName.azurecr.io" --username $acrName --password $acrPassword --only-show-errors | Out-Null
        if ($blueprintSecret) {
            az containerapp secret set -n $AppName -g $ResourceGroup `
                --secrets "blueprint-secret=$blueprintSecret" --only-show-errors | Out-Null
        }
        az containerapp update -n $AppName -g $ResourceGroup `
            --image $image --set-env-vars $envVars --only-show-errors | Out-Null
    }
    else {
        $createArgs = @(
            '-n', $AppName, '-g', $ResourceGroup,
            '--environment', $EnvName,
            '--image', $image,
            '--registry-server', "$acrName.azurecr.io",
            '--registry-username', $acrName, '--registry-password', $acrPassword,
            '--ingress', 'external', '--target-port', '8000',
            '--env-vars'
        ) + $envVars
        if ($blueprintSecret) {
            $createArgs += @('--secrets', "blueprint-secret=$blueprintSecret")
        }
        az containerapp create @createArgs --only-show-errors | Out-Null
    }
    if ($LASTEXITCODE -ne 0) { throw 'Container App のデプロイに失敗しました。' }
}
finally {
    Pop-Location
}

# --- 3. システム割り当てマネージド ID を有効化 ---------------------------------
Write-Host "[2/5] システム割り当てマネージド ID を有効化..." -ForegroundColor Yellow
$principalId = az containerapp identity assign `
    --name $AppName --resource-group $ResourceGroup `
    --system-assigned --query principalId -o tsv
if ([string]::IsNullOrWhiteSpace($principalId)) {
    throw 'マネージド ID の principalId を取得できませんでした。'
}
Write-Host "      principalId = $principalId" -ForegroundColor Green

# --- 4. Foundry への RBAC 付与（任意） -----------------------------------------
if (-not $SkipRbac) {
    if (-not $FoundryResourceGroup) {
        Write-Host '[3/5] -FoundryResourceGroup 未指定のため Foundry RBAC をスキップします（APIM 経由では不要）。' -ForegroundColor DarkGray
    }
    else {
        Write-Host "[3/5] Foundry アカウント（RG: $FoundryResourceGroup）を探索し RBAC を付与..." -ForegroundColor Yellow
        $subDomain = ([uri]$projectEndpoint).Host.Split('.')[0]
        $accounts  = az cognitiveservices account list -g $FoundryResourceGroup --only-show-errors -o json | ConvertFrom-Json
        $foundry   = $accounts | Where-Object { $_.properties.customSubDomainName -eq $subDomain } | Select-Object -First 1
        if (-not $foundry) {
            $foundry = $accounts | Where-Object { $_.kind -eq 'AIServices' } | Select-Object -First 1
        }
        if (-not $foundry) {
            Write-Host "[warn] Foundry アカウントを特定できませんでした。RBAC を手動付与してください。" -ForegroundColor Yellow
        }
        else {
            $foundryId = $foundry.id
            Write-Host "      Foundry: $($foundry.name)" -ForegroundColor Green
            az role assignment create `
                --assignee-object-id $principalId `
                --assignee-principal-type ServicePrincipal `
                --role $AiRole `
                --scope $foundryId --only-show-errors | Out-Null
            if ($LASTEXITCODE -ne 0) {
                Write-Host "[warn] ロール '$AiRole' の付与に失敗しました。権限を確認してください。" -ForegroundColor Yellow
            }
            else {
                Write-Host "      ロール付与: $AiRole -> $($foundry.name)" -ForegroundColor Green
            }
        }
    }
}
else {
    Write-Host '[3/5] -SkipRbac 指定のため RBAC をスキップしました。' -ForegroundColor Yellow
}

# --- 5. リビジョン再起動（MI ＋ ロール反映 / 出口トグル反映のため） --------------
Write-Host "[4/5] 最新リビジョンを再起動（MI / ロール / 出口トグル反映）..." -ForegroundColor Yellow
$revision = az containerapp revision list -n $AppName -g $ResourceGroup --query "[-1].name" -o tsv 2>$null
if (-not [string]::IsNullOrWhiteSpace($revision)) {
    az containerapp revision restart -n $AppName -g $ResourceGroup --revision $revision --only-show-errors 2>$null | Out-Null
}

# --- 6. 公開 URL 取得 ----------------------------------------------------------
$fqdn = az containerapp show -n $AppName -g $ResourceGroup --query properties.configuration.ingress.fqdn -o tsv
if ([string]::IsNullOrWhiteSpace($fqdn)) {
    throw 'Container App の FQDN を取得できませんでした。'
}
$baseUrl = "https://$fqdn"
Write-Host "[5/5] 公開 URL: $baseUrl" -ForegroundColor Yellow

Write-Host ''
Write-Host '== 完了 ==' -ForegroundColor Cyan
Write-Host "App URL    : $baseUrl"
Write-Host "Chat API   : $baseUrl/chat       (POST {""message"":""...""})            自律型 (Step 2a)"
Write-Host "OBO API    : $baseUrl/obo-chat    (POST + Authorization: Bearer <user>)  OBO (Step 2b)"
Write-Host "Auth Debug : $baseUrl/debug/auth  (出口トークンの種別・クレームを確認)"
Write-Host "Health     : $baseUrl/healthz"
Write-Host "出口モード  : USE_AGENT_ID_EGRESS=$useAgentIdEgress / OBO aud=$blueprintApiAudience" -ForegroundColor Green
Write-Host ''
Write-Host 'スモークテスト:' -ForegroundColor Cyan
Write-Host "  python smoke_test.py $baseUrl                 # /chat（自律型）"
Write-Host "  pwsh .\scripts\test-obo-end-to-end.ps1 -BaseUrl $baseUrl   # /obo-chat（OBO）"
Write-Host '  またはブラウザ UI: ..\chat-ui-obo\app.py（Streamlit）'
Write-Host ''
Write-Host '注: ロール伝播に数分かかる場合があります。初回 /chat が 401/403 の場合は少し待って再試行してください。' -ForegroundColor DarkGray
