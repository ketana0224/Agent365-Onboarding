#requires -Version 7.0
<#
.SYNOPSIS
    lab6（Observability 版）用の .env を自動生成します。

.DESCRIPTION
    lab5（agent-custom-MAF-ACA-A365-obo）の .env をベースにコピーし、
    観測（OTel スパン出口）用の Agent 365 Observability ブロックを追記/上書きして、
    本フォルダ（agent-custom-MAF-ACA-A365-obo-obs）の .env を作成します。

    - 観測ペア（OtelWrite を付与した親 Blueprint / Agent Identity / Blueprint シークレット）を
      引数 or 既存 .env から拾い、未指定なら egress 用の値を流用します。
    - 一切ハードコードしません。値はすべて lab5 .env と引数から取得します。

.EXAMPLE
    pwsh .\scripts\00_generate-env.ps1
    pwsh .\scripts\00_generate-env.ps1 -ObsBlueprintId 75744116-... -ObsAgentId ab356b76-... -ObsBlueprintSecret 'Qbd8Q~...'
#>

[CmdletBinding()]
param(
    # コピー元の lab5 .env（既定: ..\..\..\lab5\agent-custom-MAF-ACA-A365-obo\.env）
    [string]$SourceEnv,
    # 生成先（既定: 本フォルダの .env）
    [string]$DestEnv,
    # 観測用 親 Blueprint appId（未指定なら既存 .env → egress の BLUEPRINT_APP_ID）
    [string]$ObsBlueprintId,
    # 観測用 Agent Identity appId（未指定なら既存 .env → egress の AGENT_IDENTITY_APP_ID）
    [string]$ObsAgentId,
    # 観測用 Blueprint シークレット（未指定なら既存 .env → egress の BLUEPRINT_CLIENT_SECRET）
    [string]$ObsBlueprintSecret,
    # 共有 App Insights 名（APIM と E2E 集約する宛先。既定: appi-foundryobs-jyenh）
    [string]$AppInsightsName = 'appi-foundryobs-jyenh',
    # App Insights 接続文字列を直接指定（未指定なら $AppInsightsName から自動解決）
    [string]$AppInsightsConnectionString,
    # 既存 .env があっても上書きする
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
if (-not $SourceEnv) { $SourceEnv = Join-Path $root '..\..\lab5\agent-custom-MAF-ACA-A365-obo\.env' }
if (-not $DestEnv)   { $DestEnv   = Join-Path $root '.env' }

if (-not (Test-Path $SourceEnv)) {
    throw "lab5 の .env が見つかりません: $SourceEnv`n先に lab5 を実施して .env を作成してください。"
}
if ((Test-Path $DestEnv) -and -not $Force) {
    throw ".env が既に存在します: $DestEnv`n上書きするなら -Force を付けてください。"
}

# --- ベース .env を読み込み（順序維持） --------------------------------------
$lines = Get-Content $SourceEnv
$map = @{}
foreach ($l in $lines) {
    $t = $l.Trim()
    if ($t -and -not $t.StartsWith('#') -and $t.Contains('=')) {
        $k, $v = $t -split '=', 2
        $map[$k.Trim()] = $v.Trim()
    }
}

# --- 観測ペアを解決（引数 > 既存値 > egress フォールバック） ------------------
if (-not $ObsBlueprintId)     { $ObsBlueprintId     = $map['AGENT365OBSERVABILITY__BLUEPRINTID'] }
if (-not $ObsAgentId)         { $ObsAgentId         = $map['AGENT365OBSERVABILITY__AGENTID'] }
if (-not $ObsBlueprintSecret) { $ObsBlueprintSecret = $map['AGENT365OBSERVABILITY__BLUEPRINTSECRET'] }
if (-not $ObsBlueprintId)     { $ObsBlueprintId     = $map['BLUEPRINT_APP_ID'] }
if (-not $ObsAgentId)         { $ObsAgentId         = $map['AGENT_IDENTITY_APP_ID'] }
if (-not $ObsBlueprintSecret) { $ObsBlueprintSecret = $map['BLUEPRINT_CLIENT_SECRET'] }

# --- 共有 App Insights 接続文字列を自動解決（APIM と E2E 集約） ----------------
# APIM(apim-aigateway-eastus2) は共有 App Insights(appi-foundryobs-jyenh) に診断ログを
# 流している。アプリも同じ App Insights に出さないと E2E が分断するため、ここで接続文字列を
# 自動取得して .env に焼き込む（deploy-aca.ps1 はこの値が空だと throw する）。
if (-not $AppInsightsConnectionString) { $AppInsightsConnectionString = $map['APPLICATIONINSIGHTS_CONNECTION_STRING'] }
if (-not $AppInsightsConnectionString) {
    Write-Host "共有 App Insights '$AppInsightsName' の接続文字列を取得中..." -ForegroundColor Yellow
    az extension add --name application-insights --upgrade --only-show-errors 2>$null | Out-Null
    $aiId = az resource list -n $AppInsightsName --resource-type 'Microsoft.Insights/components' --query '[0].id' -o tsv 2>$null
    if ($aiId) {
        $AppInsightsConnectionString = az monitor app-insights component show --ids $aiId --query connectionString -o tsv 2>$null
    }
    if (-not $AppInsightsConnectionString) {
        Write-Warning "App Insights '$AppInsightsName' の接続文字列を自動取得できませんでした（az login / サブスクリプションを確認）。`n  -AppInsightsConnectionString で手動指定するか、az login 後に再実行してください。"
    }
}

# --- 観測キーを差し替え/追記 --------------------------------------------------
$obs = [ordered]@{
    'AGENT365OBSERVABILITY__BLUEPRINTID'     = $ObsBlueprintId
    'AGENT365OBSERVABILITY__AGENTID'         = $ObsAgentId
    'AGENT365OBSERVABILITY__BLUEPRINTSECRET' = $ObsBlueprintSecret
    'APPLICATIONINSIGHTS_CONNECTION_STRING'  = $AppInsightsConnectionString
}
$out = [System.Collections.Generic.List[string]]::new()
$seen = @{}
foreach ($l in $lines) {
    $k = ($l -split '=', 2)[0].Trim()
    if ($obs.Contains($k)) { $out.Add("$k=$($obs[$k])"); $seen[$k] = $true }
    else { $out.Add($l) }
}
$missing = $obs.Keys | Where-Object { -not $seen[$_] }
if ($missing) {
    $out.Add('')
    $out.Add('# Agent 365 Observability（OTel スパン出口 / 00_generate-env.ps1 で追記）')
    foreach ($k in $missing) { $out.Add("$k=$($obs[$k])") }
}

Set-Content -Path $DestEnv -Value $out -Encoding UTF8
Write-Host "生成しました: $DestEnv" -ForegroundColor Green
Write-Host "  BLUEPRINTID = $ObsBlueprintId"
Write-Host "  AGENTID     = $ObsAgentId"
Write-Host "  SECRET      = $(if ($ObsBlueprintSecret) { '(set)' } else { '(empty)' })"
Write-Host "  APPINSIGHTS = $(if ($AppInsightsConnectionString) { "(set) $AppInsightsName" } else { '(empty) ※未解決。deploy-aca.ps1 が throw します' })"
