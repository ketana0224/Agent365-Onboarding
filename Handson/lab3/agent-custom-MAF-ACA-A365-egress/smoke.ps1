<#
.SYNOPSIS
    ACA にデプロイした egress 版エージェントの FQDN を .env から自動解決し、smoke_test.py を実行する。

.DESCRIPTION
    エンドポイント（FQDN）は受講者ごと・デプロイごとに変わるため手打ちしない。
    .env の ACA_APP_NAME / ACA_RESOURCE_GROUP を読み、`az containerapp show` で
    ingress の FQDN を取得して `python smoke_test.py https://<fqdn>` を呼ぶ。

.EXAMPLE
    pwsh .\smoke.ps1
    # .env の値でデプロイ済みアプリの URL を自動解決してスモークテスト

.EXAMPLE
    pwsh .\smoke.ps1 -AppName custom-maf-a365-egress-user01 -ResourceGroup rg-user01
    # 明示指定（.env と別のアプリを叩く場合）
#>
[CmdletBinding()]
param(
    [string]$EnvFile,
    [string]$AppName,
    [string]$ResourceGroup
)

$ErrorActionPreference = 'Stop'
$repoRoot = $PSScriptRoot
if (-not $EnvFile) { $EnvFile = Join-Path $repoRoot '.env' }

# --- .env 読み込み（未指定パラメーターの既定値に使う） ---
$envMap = @{}
if (Test-Path $EnvFile) {
    foreach ($line in Get-Content $EnvFile) {
        $t = $line.Trim()
        if ($t -and -not $t.StartsWith('#') -and $t.Contains('=')) {
            $k, $v = $t -split '=', 2
            $envMap[$k.Trim()] = $v.Trim()
        }
    }
}

if (-not $AppName)       { $AppName       = if ($envMap['ACA_APP_NAME'])       { $envMap['ACA_APP_NAME'] }       else { 'custom-maf-a365-egress' } }
if (-not $ResourceGroup) { $ResourceGroup = if ($envMap['ACA_RESOURCE_GROUP']) { $envMap['ACA_RESOURCE_GROUP'] } else { 'rg-foundryobs-eastus2' } }

Write-Host "== FQDN を解決: app=$AppName rg=$ResourceGroup ==" -ForegroundColor Cyan
$fqdn = az containerapp show -n $AppName -g $ResourceGroup --query properties.configuration.ingress.fqdn -o tsv 2>$null
if ([string]::IsNullOrWhiteSpace($fqdn)) {
    throw "FQDN を取得できませんでした（app=$AppName / rg=$ResourceGroup）。デプロイ済みか、az のログイン/サブスクリプションを確認してください。"
}
$baseUrl = "https://$fqdn"
Write-Host "   BASE: $baseUrl" -ForegroundColor Green

# --- smoke_test.py 実行 ---
python (Join-Path $repoRoot 'smoke_test.py') $baseUrl
exit $LASTEXITCODE
