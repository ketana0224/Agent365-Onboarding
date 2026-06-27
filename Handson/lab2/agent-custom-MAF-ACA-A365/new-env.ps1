#requires -Version 7.0
<#
.SYNOPSIS
    受講者ごとの .env を生成します（userNN で Azure リソースを分離）。

.DESCRIPTION
    .env は .gitignore 済みのため、各受講者がこのスクリプトで自分用に生成します。
    出力は次の 3 つで構成されます。

      1) 全受講者で共有する基盤値（Foundry / APIM(モデル・MCP) / Application Insights）
         → スクリプト内の定数。変更不要。
      2) 受講者ごとの ACA 値（-Me userNN から導出）
         ACA_RESOURCE_GROUP = rg-<Me>
         ACA_APP_NAME       = custom-maf-agent-a365-<Me>
         ACA_ENV_NAME       = aca-contoso-agent-<Me>
         ※ AZURE_RESOURCE_GROUP は共有の Foundry RG(rg-foundryobs-eastus2)のまま。
      3) Agent ID / Observability 値
         §4.2 の `a365 setup all` 実行後に a365.generated.config.json から自動補完。
         未実行時は空のまま出力（§3 の ACA デプロイには不要）。

    冪等です。§3 の前に一度実行し、§4.2 の後にもう一度実行すると Agent ID が埋まります。

.PARAMETER Me
    受講者識別子（例: user01）。

.PARAMETER Force
    既存 .env を確認なしで上書きします。

.EXAMPLE
    ./new-env.ps1 -Me user01
    # 共有基盤 + ACA(-user01) を書き出す。a365 setup all 後に再実行で Agent ID 補完。
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^user\d{2}$')]
    [string]$Me,

    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$agentRoot = $PSScriptRoot
$envFile   = Join-Path $agentRoot '.env'
$genFile   = Join-Path $agentRoot 'a365.generated.config.json'

Write-Host "== 受講者 .env 生成 ($Me) ==" -ForegroundColor Cyan

if ((Test-Path $envFile) -and -not $Force) {
    $ans = Read-Host "$envFile は既に存在します。上書きしますか? (y/N)"
    if ($ans -notin @('y', 'Y')) { Write-Host '中止しました。' -ForegroundColor Yellow; return }
}

# --- 1) 全受講者で共有する基盤値（変更不要） -------------------------------
$TENANT_ID        = '655bd66a-5001-4cb3-9aad-ce54a27d5d95'
$SUBSCRIPTION_ID  = 'd1bf4d07-2dac-43a8-9060-4d5274fc7e33'
$FOUNDRY_RG       = 'rg-foundryobs-eastus2'   # Foundry アカウントの所在=ロール付与スコープ（共有）
$LOCATION         = 'eastus2'
$PROJECT_ENDPOINT = 'https://foundryobsjyenh.services.ai.azure.com/api/projects/proj-foundryobs-jyenh'
$MODEL_DEPLOYMENT = 'gpt-5.4'
$APIM_AOAI_ENDPOINT    = 'https://apim-aigateway-eastus2.azure-api.net/openai'
$APIM_AOAI_DEPLOYMENT  = 'gpt-5.4'
$APIM_AOAI_API_VERSION = '2024-10-21'
$APPINSIGHTS_CONN = 'InstrumentationKey=08f42633-374a-44aa-8f5d-43b06072f787;IngestionEndpoint=https://eastus2-3.in.applicationinsights.azure.com/;LiveEndpoint=https://eastus2.livediagnostics.monitor.azure.com/;ApplicationId=e96c9771-7512-4b0a-8aba-f88cdfa29540'
$APPINSIGHTS_NAME = 'appi-foundryobs-jyenh'
$CONTOSO_MCP_URL  = 'https://apim-aigateway-eastus2.azure-api.net/contoso-policy/mcp'
$CONTOSO_MCP_KEY  = 'd9bd884ff515d3ed09b854b80e003e7a'   # APIM 経由化後は通常不要。直接 backend への切り戻し用。
$A365_SCOPE       = '5a807f24-c9de-44ee-a3a7-329e88a00ffc/.default'  # SERVICE_CONNECTION リソース scope（共有）

# --- 2) 受講者ごとの ACA 値 --------------------------------------------------
$acaRg   = "rg-$Me"
$acaApp  = "custom-maf-agent-a365-$Me"
$acaEnv  = "aca-contoso-agent-$Me"

# --- 3) Agent ID / Observability（a365 setup all 後に補完） -----------------
$blueprintId = ''
$agenticAppId = ''
$clientSecret = ''
if (Test-Path $genFile) {
    try {
        $gen = Get-Content $genFile -Raw | ConvertFrom-Json
        $blueprintId  = $gen.agentBlueprintId
        $agenticAppId = $gen.agenticAppId
        $rawSecret    = $gen.agentBlueprintClientSecret
        if ($rawSecret) {
            if ($gen.agentBlueprintClientSecretProtected -eq $true) {
                # DPAPI(CurrentUser): a365 setup all を実行した本人・同一 Windows ユーザーのみ復号可
                Add-Type -AssemblyName System.Security -ErrorAction SilentlyContinue
                $bytes = [System.Security.Cryptography.ProtectedData]::Unprotect(
                    [Convert]::FromBase64String($rawSecret), $null, 'CurrentUser')
                $clientSecret = [System.Text.Encoding]::UTF8.GetString($bytes)
            }
            else {
                $clientSecret = $rawSecret
            }
        }
        Write-Host "a365.generated.config.json から Agent ID を補完しました。" -ForegroundColor Green
    }
    catch {
        Write-Host "Agent ID の補完に失敗（§4.2 後に再実行してください）: $($_.Exception.Message)" -ForegroundColor Yellow
    }
}
else {
    Write-Host "a365.generated.config.json 未検出。Agent ID は空で出力します（§4.2 後に再実行で補完）。" -ForegroundColor Yellow
}

# --- .env 生成 ----------------------------------------------------------------
$content = @"
# 自動生成 (new-env.ps1) - $(Get-Date -Format o) - $Me
AZURE_TENANT_ID=$TENANT_ID
AZURE_SUBSCRIPTION_ID=$SUBSCRIPTION_ID
# Foundry アカウントが属する共有 RG（RBAC スコープ）。受講者間で共通・変更しない。
AZURE_RESOURCE_GROUP=$FOUNDRY_RG
AZURE_LOCATION=$LOCATION
PROJECT_ENDPOINT=$PROJECT_ENDPOINT
MODEL_DEPLOYMENT_NAME=$MODEL_DEPLOYMENT
AGENT_MODEL_DEPLOYMENT_NAME=
# ----- LLM: APIM AI Gateway 経由 (apim-aigateway-eastus2) -----
APIM_AOAI_ENDPOINT=$APIM_AOAI_ENDPOINT
APIM_AOAI_DEPLOYMENT=$APIM_AOAI_DEPLOYMENT
APIM_AOAI_API_VERSION=$APIM_AOAI_API_VERSION
APIM_SCOPE=
APPLICATIONINSIGHTS_CONNECTION_STRING=$APPINSIGHTS_CONN
APPLICATIONINSIGHTS_NAME=$APPINSIGHTS_NAME
# ----- MCP: APIM AI Gateway 経由 (contoso-policy/mcp) -----
CONTOSO_MCP_URL=$CONTOSO_MCP_URL
MCP_RESOURCE_APP_ID=
MCP_SCOPE=
# APIM 経由化後は通常不要。直接 backend に当てる切り戻し用としてのみ残す。
CONTOSO_MCP_KEY=$CONTOSO_MCP_KEY
# ----- ACA: 受講者ごとに分離 ($Me) -----
ACA_RESOURCE_GROUP=$acaRg
ACA_APP_NAME=$acaApp
ACA_ENV_NAME=$acaEnv
# ----- Agent ID (§4.2 a365 setup all 後に補完) -----
CONNECTIONS__SERVICE_CONNECTION__SETTINGS__CLIENTID=$blueprintId
AGENT_ID=$blueprintId
CONNECTIONS__SERVICE_CONNECTION__SETTINGS__CLIENTSECRET=$clientSecret
CONNECTIONS__SERVICE_CONNECTION__SETTINGS__TENANTID=$TENANT_ID
CONNECTIONS__SERVICE_CONNECTION__SETTINGS__SCOPES=$A365_SCOPE
AGENTAPPLICATION__USERAUTHORIZATION__HANDLERS__AGENTIC__SETTINGS__TYPE=AgenticUserAuthorization
AGENTAPPLICATION__USERAUTHORIZATION__HANDLERS__AGENTIC__SETTINGS__ALT_BLUEPRINT_NAME=SERVICE_CONNECTION
AGENTAPPLICATION__USERAUTHORIZATION__HANDLERS__AGENTIC__SETTINGS__SCOPES=https://graph.microsoft.com/.default
CONNECTIONSMAP__0__SERVICEURL=*
CONNECTIONSMAP__0__CONNECTION=SERVICE_CONNECTION
ENABLE_A365_OBSERVABILITY_EXPORTER=false
AGENT365OBSERVABILITY__AGENTID=$agenticAppId
AGENT365OBSERVABILITY__AGENTNAME="$acaApp Identity"
AGENT365OBSERVABILITY__AGENTDESCRIPTION=$acaApp
AGENT365OBSERVABILITY__TENANTID=$TENANT_ID
AGENT365OBSERVABILITY__AGENTBLUEPRINTID=$blueprintId
AGENT365OBSERVABILITY__CLIENTID=$blueprintId
AGENT365OBSERVABILITY__CLIENTSECRET=$clientSecret
"@

# BOM なし UTF-8 で書き出し（.env は ASCII/UTF-8 想定）
[System.IO.File]::WriteAllText($envFile, $content, [System.Text.UTF8Encoding]::new($false))

Write-Host ''
Write-Host ".env を書き出しました: $envFile" -ForegroundColor Green
Write-Host "  ACA_RESOURCE_GROUP = $acaRg"
Write-Host "  ACA_APP_NAME       = $acaApp"
Write-Host "  ACA_ENV_NAME       = $acaEnv"
Write-Host "  AGENT_ID           = $(if ($blueprintId) { $blueprintId } else { '(空: §4.2 後に再実行)' })"
Write-Host ''
Write-Host '次の手順:' -ForegroundColor Yellow
Write-Host '  # §3 ACA デプロイ'
Write-Host '  ./deploy-aca.ps1'
Write-Host '  # §4.2 (a365 setup all) 実行後にもう一度このスクリプトを回すと Agent ID が埋まる'
Write-Host "  ./new-env.ps1 -Me $Me -Force"
