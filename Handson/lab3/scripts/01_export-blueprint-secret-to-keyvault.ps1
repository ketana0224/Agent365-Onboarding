#requires -Version 7.0
<#
.SYNOPSIS
    Lab1-2 の a365.generated.config.json に DPAPI 暗号化で保存されている
    Blueprint クライアント シークレットを復号し、Azure Key Vault に格納する。

.DESCRIPTION
    - DPAPI(CurrentUser) で暗号化されているため、`a365 setup` を実行したのと
      同じ Windows ユーザーで実行する必要がある。
    - Key Vault が無ければ作成する（RBAC 認可・public-network=Enabled）。
    - シークレット名は `blueprint-client-secret`（変更可）。

.PARAMETER ConfigPath
    a365.generated.config.json のパス。既定はリポジトリ ルート直下。

.PARAMETER KeyVaultName
    対象 Key Vault 名。未指定なら .env / 引数 / ランダム生成の順で決定。

.EXAMPLE
    pwsh scripts/01_export-blueprint-secret-to-keyvault.ps1 `
         -KeyVaultName kv-extlab1 -ResourceGroup rg-mufg-agent365 -Location eastus2
#>
[CmdletBinding()]
param(
    [string]$ConfigPath,
    [string]$SubscriptionId,
    [string]$ResourceGroup,
    [string]$Location = 'eastus2',
    [string]$KeyVaultName,
    [string]$SecretName = 'blueprint-client-secret'
)

$ErrorActionPreference = 'Stop'

# --- 0. ConfigPath を解決 ------------------------------------------------------
if (-not $ConfigPath) {
    $repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..\..')
    $ConfigPath = Join-Path $repoRoot 'a365.generated.config.json'
}
if (-not (Test-Path $ConfigPath)) {
    throw "a365.generated.config.json が見つかりません: $ConfigPath"
}
$cfg = Get-Content $ConfigPath -Raw | ConvertFrom-Json

$blueprintAppId = $cfg.agentBlueprintId
$encryptedB64   = $cfg.agentBlueprintClientSecret
if (-not $blueprintAppId) { throw 'agentBlueprintId が無い設定です。Lab1-2 の a365 setup を先に実施してください。' }
if (-not $encryptedB64)   { throw 'agentBlueprintClientSecret が無い設定です。' }

Write-Host '== Blueprint Client Secret -> Key Vault エクスポート ==' -ForegroundColor Cyan
Write-Host "  Blueprint App ID: $blueprintAppId" -ForegroundColor DarkGray

# --- 1. DPAPI 復号 -------------------------------------------------------------
Write-Host '[1/3] DPAPI(CurrentUser) で復号...' -ForegroundColor Yellow
try {
    $cipher = [Convert]::FromBase64String($encryptedB64)
    $plain  = [System.Security.Cryptography.ProtectedData]::Unprotect(
        $cipher, $null, [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
    $plainText = [System.Text.Encoding]::UTF8.GetString($plain)
}
catch {
    throw "DPAPI 復号に失敗。$($_.Exception.Message)`n`n`a365 setup` を実行したのと同じ Windows ユーザーで実行していますか？"
}

# 軽い妥当性チェック（Entra のシークレットは英数字 + 一部記号で 32-128 文字程度）
if ($plainText.Length -lt 16) { throw '復号結果が異常に短い（破損の可能性）。' }
Write-Host "      長さ $($plainText.Length) chars を取り出しました。" -ForegroundColor Green

# --- 2. Key Vault 準備 ---------------------------------------------------------
Write-Host '[2/3] Key Vault を確認/作成...' -ForegroundColor Yellow
if (-not (Get-Command az -ErrorAction SilentlyContinue)) { throw 'Azure CLI が必要です。' }
if (-not $SubscriptionId) { $SubscriptionId = az account show --query id -o tsv }
az account set --subscription $SubscriptionId | Out-Null

if (-not $KeyVaultName) {
    $suffix = -join ((97..122) + (48..57) | Get-Random -Count 6 | ForEach-Object { [char]$_ })
    $KeyVaultName = "kvextlab1$suffix"
}
if (-not $ResourceGroup) {
    throw '-ResourceGroup を指定してください。'
}
az group create -n $ResourceGroup -l $Location --only-show-errors | Out-Null

$kv = az keyvault show -n $KeyVaultName --only-show-errors --query name -o tsv 2>$null
if (-not $kv) {
    Write-Host "      Key Vault を作成: $KeyVaultName" -ForegroundColor DarkGray
    az keyvault create -n $KeyVaultName -g $ResourceGroup -l $Location `
        --enable-rbac-authorization true `
        --public-network-access Enabled `
        --only-show-errors | Out-Null
}

# 自分自身に Key Vault Secrets Officer を付与（put が通るように）
$me = az ad signed-in-user show --query id -o tsv
$kvId = az keyvault show -n $KeyVaultName --query id -o tsv
az role assignment create --assignee-object-id $me --assignee-principal-type User `
    --role 'Key Vault Secrets Officer' --scope $kvId --only-show-errors 2>$null | Out-Null

# --- 3. secret を put ----------------------------------------------------------
Write-Host '[3/3] シークレットを put...' -ForegroundColor Yellow
$tmp = New-TemporaryFile
try {
    Set-Content -Path $tmp -Value $plainText -NoNewline -Encoding ascii
    # CLI 経由でファイルから書き込み（コマンドライン履歴に平文を載せない）
    az keyvault secret set --vault-name $KeyVaultName -n $SecretName --file $tmp.FullName --only-show-errors --query id -o tsv | Out-Null
}
finally {
    Remove-Item $tmp -Force -ErrorAction SilentlyContinue
}

$secretUri = "https://$KeyVaultName.vault.azure.net/secrets/$SecretName"
Write-Host ''
Write-Host '== 完了 ==' -ForegroundColor Cyan
Write-Host "Key Vault Name : $KeyVaultName"
Write-Host "Secret Name    : $SecretName"
Write-Host "Secret URI     : $secretUri"
Write-Host ''
Write-Host '.env に次を追記してください:' -ForegroundColor Cyan
Write-Host "  KEY_VAULT_NAME=$KeyVaultName"
Write-Host "  BLUEPRINT_SECRET_KEY_VAULT_URI=$secretUri"
