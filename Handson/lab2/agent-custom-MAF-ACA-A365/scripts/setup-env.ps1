#requires -Version 7.0
<#
.SYNOPSIS
    MAF ホスト型エージェント（ACA）用の .env を生成します。

.DESCRIPTION
    既存の Foundry プロジェクトをそのまま使うため、観測基盤の接続情報を引き継ぎます。
    リポジトリ ルートの .env から接続情報を取得し、このフォルダ直下の .env を
    生成します（ローカル実行 / deploy-aca.ps1 が参照）。

    既存 .env の CONTOSO_MCP_URL / CONTOSO_MCP_KEY は維持されます。

.NOTES
    生成後（ローカル実行）:
      python -m pip install -r requirements.txt
      uvicorn app.main:app --host 0.0.0.0 --port 8000
    生成後（ACA デプロイ）:
      ./deploy-aca.ps1
#>
[CmdletBinding()]
param(
    [string]$ObservabilityEnv,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$agentRoot = Split-Path -Parent $PSScriptRoot
$repoRoot  = Split-Path -Parent $agentRoot
$envFile   = Join-Path $agentRoot '.env'

Write-Host '== MAF ホスト型エージェント（ACA）用 .env 生成 ==' -ForegroundColor Cyan

if ((Test-Path $envFile) -and -not $Force) {
    Write-Host "$envFile は既に存在します。CONTOSO_MCP_* は維持しつつ更新します。" -ForegroundColor Yellow
}

# --- ルートの .env から接続情報を取得 -------------------------------------
if (-not $ObservabilityEnv) {
    $ObservabilityEnv = Join-Path $repoRoot '.env'
}
$obs = @{}
if (Test-Path $ObservabilityEnv) {
    foreach ($line in Get-Content $ObservabilityEnv) {
        $t = $line.Trim()
        if ($t -and -not $t.StartsWith('#') -and $t.Contains('=')) {
            $k, $v = $t -split '=', 2
            $obs[$k.Trim()] = $v.Trim()
        }
    }
    Write-Host "観測基盤 .env を検出: $ObservabilityEnv" -ForegroundColor Green
}
else {
    throw "ルートの .env が見つかりません: $ObservabilityEnv`n先に ../ms-foundry-observability をデプロイするか、-ObservabilityEnv で明示指定してください。"
}

$tenantId        = $obs['AZURE_TENANT_ID']
$subscriptionId  = $obs['AZURE_SUBSCRIPTION_ID']
$resourceGroup   = $obs['AZURE_RESOURCE_GROUP']
$location        = if ($obs['AZURE_LOCATION']) { $obs['AZURE_LOCATION'] } else { 'eastus2' }
$projectEndpoint = $obs['PROJECT_ENDPOINT']
$modelDeployment = $obs['MODEL_DEPLOYMENT_NAME']
$appInsightsConn = $obs['APPLICATIONINSIGHTS_CONNECTION_STRING']
$appInsightsName = $obs['APPLICATIONINSIGHTS_NAME']

if (-not $projectEndpoint) {
    throw "PROJECT_ENDPOINT を観測基盤 .env から取得できませんでした: $ObservabilityEnv"
}

# --- 既存 .env から MCP 設定を維持 --------------------------------------------
$existingMcpUrl = ''
$existingMcpKey = ''
if (Test-Path $envFile) {
    foreach ($line in Get-Content $envFile) {
        if ($line -match '^CONTOSO_MCP_URL=(.*)$') { $existingMcpUrl = $Matches[1] }
        if ($line -match '^CONTOSO_MCP_KEY=(.*)$') { $existingMcpKey = $Matches[1] }
    }
}

# フォルダの .env に無ければルートの .env（mcp デプロイが書き込む）から引き継ぐ
if (-not $existingMcpUrl) { $existingMcpUrl = $obs['CONTOSO_MCP_URL'] }
if (-not $existingMcpKey) { $existingMcpKey = $obs['CONTOSO_MCP_KEY'] }

$envContent = @"
# 自動生成 (agent-custom-MAF-ACA/scripts/setup-env.ps1) - $(Get-Date -Format o)
AZURE_TENANT_ID=$tenantId
AZURE_SUBSCRIPTION_ID=$subscriptionId
AZURE_RESOURCE_GROUP=$resourceGroup
AZURE_LOCATION=$location
PROJECT_ENDPOINT=$projectEndpoint
MODEL_DEPLOYMENT_NAME=$modelDeployment
AGENT_MODEL_DEPLOYMENT_NAME=
APPLICATIONINSIGHTS_CONNECTION_STRING=$appInsightsConn
APPLICATIONINSIGHTS_NAME=$appInsightsName
CONTOSO_MCP_URL=$existingMcpUrl
CONTOSO_MCP_KEY=$existingMcpKey
ACA_RESOURCE_GROUP=$resourceGroup
ACA_APP_NAME=custom-maf-agent
ACA_ENV_NAME=aca-contoso-agent
"@
Set-Content -Path $envFile -Value $envContent -Encoding utf8

Write-Host ''
Write-Host "環境変数を書き出しました: $envFile" -ForegroundColor Green
Write-Host "  PROJECT_ENDPOINT       = $projectEndpoint"
Write-Host "  MODEL_DEPLOYMENT_NAME  = $modelDeployment"
Write-Host "  AZURE_LOCATION         = $location"
Write-Host ''
Write-Host '次の手順:' -ForegroundColor Yellow
Write-Host '  # ローカル実行'
Write-Host '  python -m pip install -r requirements.txt'
Write-Host '  uvicorn app.main:app --host 0.0.0.0 --port 8000'
Write-Host '  # ACA へデプロイ'
Write-Host '  ./deploy-aca.ps1'
