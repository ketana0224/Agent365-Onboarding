<#
.SYNOPSIS
  Lab1-2 §4.3(2) Azure リソース検証（ACA 版）。
  本ラボの実行体は App Service Web App ではなく Azure Container Apps（ACA）。

.DESCRIPTION
  .env（ACA_RESOURCE_GROUP / ACA_APP_NAME / ACA_ENV_NAME）を読み、以下を確認する:
    1) リソース グループ内のリソース一覧
    2) ACA 本体の存在・プロビジョニング状態・公開 FQDN
    3) ACA のシステム割り当てマネージド ID（principalId）が有効か
    4) その MI に付与されたロール割り当て（Foundry への Azure AI Developer 等）
  読み取り専用（破壊的操作なし）。事前に `az login` 済みであること。

.EXAMPLE
  pwsh -NoProfile -File .\verify-azure-resources.ps1
#>
[CmdletBinding()]
param(
    [string]$ResourceGroup,
    [string]$AcaName,
    [string]$EnvName
)

$ErrorActionPreference = 'Stop'

# --- .env から既定値を読む（引数指定があれば優先） ---
$envPath = Join-Path $PSScriptRoot '.env'
$envMap  = @{}
if (Test-Path $envPath) {
    Get-Content $envPath | ForEach-Object {
        if ($_ -match '^\s*([^#=]+?)\s*=\s*(.*?)\s*$') {
            $envMap[$Matches[1]] = $Matches[2].Trim('"').Trim("'")
        }
    }
}
if (-not $ResourceGroup) { $ResourceGroup = $envMap['ACA_RESOURCE_GROUP']; if (-not $ResourceGroup) { $ResourceGroup = $envMap['AZURE_RESOURCE_GROUP'] } }
if (-not $AcaName)       { $AcaName       = $envMap['ACA_APP_NAME'] }
if (-not $EnvName)       { $EnvName       = $envMap['ACA_ENV_NAME'] }

if (-not $ResourceGroup -or -not $AcaName) {
    throw "ResourceGroup / AcaName を解決できません。.env を確認するか引数で指定してください。"
}

Write-Host "================ 検証パラメータ ================" -ForegroundColor Cyan
Write-Host "  ResourceGroup : $ResourceGroup"
Write-Host "  ACA App       : $AcaName"
Write-Host "  ACA Env       : $EnvName"
Write-Host ""

# az login 済みか確認
$acct = az account show -o json 2>$null | ConvertFrom-Json
if (-not $acct) { throw "az login が必要です。'az login' を実行してください。" }
Write-Host "  Subscription  : $($acct.name) ($($acct.id))"
Write-Host ""

# containerapp 拡張が無いと containerapp サブコマンドが失敗するので確認
$ext = az extension list -o json 2>$null | ConvertFrom-Json
if (-not ($ext | Where-Object { $_.name -eq 'containerapp' })) {
    Write-Host "containerapp 拡張を追加します..." -ForegroundColor DarkGray
    az extension add --name containerapp --only-show-errors 2>$null | Out-Null
}

# --- 1) リソース一覧 ---
Write-Host "===== 1) リソース グループ内のリソース =====" -ForegroundColor Green
az resource list --resource-group $ResourceGroup --output table
Write-Host ""

# --- 2) ACA 本体 ---
Write-Host "===== 2) ACA 本体（プロビジョニング状態・FQDN） =====" -ForegroundColor Green
$aca = az containerapp show --name $AcaName --resource-group $ResourceGroup -o json 2>$null | ConvertFrom-Json
if (-not $aca) {
    Write-Host "  ACA '$AcaName' が見つかりません。" -ForegroundColor Red
} else {
    $fqdn  = $aca.properties.configuration.ingress.fqdn
    $state = $aca.properties.provisioningState
    Write-Host "  name              : $($aca.name)"
    Write-Host "  provisioningState : $state"
    Write-Host "  FQDN              : https://$fqdn"
    Write-Host "  healthz           : https://$fqdn/healthz"
}
Write-Host ""

# --- 3) ACA システム割り当て MI ---
Write-Host "===== 3) ACA のシステム割り当てマネージド ID =====" -ForegroundColor Green
$mi = az containerapp identity show --name $AcaName --resource-group $ResourceGroup -o json 2>$null | ConvertFrom-Json
$principalId = $null
if ($mi -and $mi.principalId) {
    $principalId = $mi.principalId
    Write-Host "  type        : $($mi.type)"
    Write-Host "  principalId : $principalId"
    Write-Host "  tenantId    : $($mi.tenantId)"
} else {
    Write-Host "  システム割り当て MI が有効ではありません。" -ForegroundColor Yellow
    Write-Host "  有効化: az containerapp identity assign --system-assigned -n $AcaName -g $ResourceGroup" -ForegroundColor DarkGray
}
Write-Host ""

# --- 4) MI のロール割り当て（APIM 経由構成では参考情報） ---
Write-Host "===== 4) MI に付与されたロール割り当て（APIM 経由なら不要） =====" -ForegroundColor Green
if ($principalId) {
    $roles = az role assignment list --assignee $principalId --all -o json 2>$null | ConvertFrom-Json
    if ($roles) {
        $roles | ForEach-Object {
            Write-Host "  - $($_.roleDefinitionName)" -ForegroundColor White
            Write-Host "      scope: $($_.scope)" -ForegroundColor DarkGray
        }
    } else {
        Write-Host "  ロール割り当てなし。" -ForegroundColor DarkGray
    }
    Write-Host ""
    Write-Host "  ℹ 本ラボはモデル/MCP を APIM AI Gateway 経由で呼ぶため、MI への Foundry ロール（Azure AI Developer）は不要です。" -ForegroundColor DarkGray
    Write-Host "    （MI は cognitiveservices の token を取得するだけ。Foundry への RBAC は APIM 自身の MI が保持します。ロールなしでも正常です。）" -ForegroundColor DarkGray
} else {
    Write-Host "  （MI が無いためスキップ）" -ForegroundColor DarkGray
}
Write-Host ""
Write-Host "================ 検証完了 ================" -ForegroundColor Cyan
