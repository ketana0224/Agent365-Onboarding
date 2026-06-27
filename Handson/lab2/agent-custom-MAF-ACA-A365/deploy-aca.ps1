#requires -Version 7.0
<#
.SYNOPSIS
    MAF ホスト型エージェントを Azure Container Apps にデプロイします。

.DESCRIPTION
    プロンプトエージェント（agent-aif-prompt-agent）と同一仕様（Contoso サポート・
    同一指示・同一 MCP ツール・同一モデル）を、自前コンテナ（Microsoft Agent Framework）
    として ACA 上で実行します。

    1. .env を読み込み（scripts/setup-env で生成。PROJECT_ENDPOINT / モデル / MCP /
       App Insights / Foundry RG などを取得）
    2. Azure CLI / containerapp 拡張 / リソースプロバイダーを確認・登録
    3. `az acr build --file Dockerfile` で ACR にイメージを明示ビルド（ローカル Docker 不要）し、
       ACR + Container Apps 環境 + Container App（外部 HTTPS Ingress, port 8000）を作成
    4. システム割り当てマネージド ID を有効化
    5. その MI に、Foundry アカウント（PROJECT_ENDPOINT のプロジェクトが属する
       Cognitive Services アカウント）への「Azure AI Developer」を付与（推論・エージェント実行）
    6. 公開 URL をコンソールに出力

.NOTES
    先に scripts/setup-env.ps1（または .sh）で .env を生成してください。
    エージェントは実行時にマネージド ID で Foundry へ認証します（コードにキーは持ちません）。
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

Write-Host '== MAF ホスト型エージェント デプロイ (Azure Container Apps) ==' -ForegroundColor Cyan

# --- 0. .env 読み込み ----------------------------------------------------------
if (-not (Test-Path $EnvFile)) {
    throw ".env が見つかりません: $EnvFile`n先に scripts/setup-env.ps1 を実行してください。"
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
if (-not $ResourceGroup)         { $ResourceGroup         = if ($envMap['ACA_RESOURCE_GROUP']) { $envMap['ACA_RESOURCE_GROUP'] } else { $envMap['AZURE_RESOURCE_GROUP'] } }
if (-not $AppName)               { $AppName               = if ($envMap['ACA_APP_NAME']) { $envMap['ACA_APP_NAME'] } else { 'custom-maf-agent' } }
if (-not $EnvName)               { $EnvName               = if ($envMap['ACA_ENV_NAME']) { $envMap['ACA_ENV_NAME'] } else { 'aca-contoso-agent' } }
if (-not $FoundryResourceGroup)  { $FoundryResourceGroup  = $envMap['AZURE_RESOURCE_GROUP'] }

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

if (-not $projectEndpoint) { throw '.env に PROJECT_ENDPOINT がありません。' }
if (-not $modelDeployment) { throw '.env に MODEL_DEPLOYMENT_NAME / AGENT_MODEL_DEPLOYMENT_NAME がありません。' }
if (-not $apimAoaiEndpoint) { throw '.env に APIM_AOAI_ENDPOINT がありません（APIM 経由化に必須）。' }

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
# 注: `az containerapp up --source` は Dockerfile があっても Oryx ビルドパックを
#     優先し、FastAPI アプリを gunicorn の既定 (application:app) で起動して失敗する。
#     そのため ACR にイメージを明示ビルド (Dockerfile 使用) してからデプロイする。
Write-Host "[1/5] イメージをビルドして Container App をデプロイ（数分かかります）..." -ForegroundColor Yellow
$envVars = @(
    "PROJECT_ENDPOINT=$projectEndpoint",
    "MODEL_DEPLOYMENT_NAME=$modelDeployment",
    "AGENT_MODEL_DEPLOYMENT_NAME=$($envMap['AGENT_MODEL_DEPLOYMENT_NAME'])",
    "APIM_AOAI_ENDPOINT=$apimAoaiEndpoint",
    "APIM_AOAI_DEPLOYMENT=$apimAoaiDeployment",
    "PORT=8000"
)
if ($apimAoaiApiVersion) { $envVars += "APIM_AOAI_API_VERSION=$apimAoaiApiVersion" }
if ($apimScope)         { $envVars += "APIM_SCOPE=$apimScope" }
if ($mcpResourceAppId)  { $envVars += "MCP_RESOURCE_APP_ID=$mcpResourceAppId" }
if ($mcpScope)          { $envVars += "MCP_SCOPE=$mcpScope" }
if ($appInsightsConn) { $envVars += "APPLICATIONINSIGHTS_CONNECTION_STRING=$appInsightsConn" }
if ($mcpUrl)          { $envVars += "CONTOSO_MCP_URL=$mcpUrl" }
if ($mcpKey)          { $envVars += "CONTOSO_MCP_KEY=$mcpKey" }

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
        # 先にレジストリ資格情報を登録してから image を更新する（更新時のプル認証を通すため）
        az containerapp registry set -n $AppName -g $ResourceGroup `
            --server "$acrName.azurecr.io" --username $acrName --password $acrPassword --only-show-errors | Out-Null
        az containerapp update -n $AppName -g $ResourceGroup `
            --image $image --set-env-vars $envVars --only-show-errors | Out-Null
    }
    else {
        az containerapp create -n $AppName -g $ResourceGroup `
            --environment $EnvName `
            --image $image `
            --registry-server "$acrName.azurecr.io" --registry-username $acrName --registry-password $acrPassword `
            --ingress external --target-port 8000 `
            --env-vars $envVars --only-show-errors | Out-Null
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

# --- 4. Foundry への RBAC 付与 -------------------------------------------------
if (-not $SkipRbac) {
    if (-not $FoundryResourceGroup) {
        Write-Host '[3/5] AZURE_RESOURCE_GROUP（Foundry RG）が不明のため RBAC をスキップします。' -ForegroundColor Yellow
        Write-Host '       手動で MI に Foundry アカウントへの「Azure AI User」を付与してください。' -ForegroundColor Yellow
    }
    else {
        Write-Host "[3/5] Foundry アカウント（RG: $FoundryResourceGroup）を探索し RBAC を付与..." -ForegroundColor Yellow
        # PROJECT_ENDPOINT のサブドメインから Foundry アカウントを特定（customSubDomain 一致）
        $subDomain = ([uri]$projectEndpoint).Host.Split('.')[0]
        $accounts  = az cognitiveservices account list -g $FoundryResourceGroup --only-show-errors -o json | ConvertFrom-Json
        $foundry   = $accounts | Where-Object { $_.properties.customSubDomainName -eq $subDomain } | Select-Object -First 1
        if (-not $foundry) {
            # フォールバック: kind=AIServices の先頭
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

# --- 5. リビジョン再起動（MI ＋ ロール反映のため） ------------------------------
Write-Host "[4/5] 最新リビジョンを再起動（MI / ロール反映）..." -ForegroundColor Yellow
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
Write-Host "App URL  : $baseUrl"
Write-Host "Chat API : $baseUrl/chat  (POST {""message"":""...""})"
Write-Host "Health   : $baseUrl/healthz"
Write-Host ''
Write-Host 'スモークテスト:' -ForegroundColor Cyan
Write-Host "  python smoke_test.py $baseUrl"
Write-Host ''
Write-Host '注: ロール伝播に数分かかる場合があります。初回 /chat が 401/403 の場合は少し待って再試行してください。' -ForegroundColor DarkGray
