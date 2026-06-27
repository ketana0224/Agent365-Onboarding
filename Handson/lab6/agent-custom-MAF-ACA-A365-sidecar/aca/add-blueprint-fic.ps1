<#
.SYNOPSIS
  Blueprint アプリに「UAMI を信頼するフェデレーション資格情報（FIC）」を追加する。

.DESCRIPTION
  パスワードレス（CredentialMode=ManagedIdentity）でサイドカーを動かす場合、サイドカーは
  Container App の UAMI トークンを client_assertion として Blueprint のトークン交換に使う。
  これを Entra が信頼するには、Blueprint アプリ（agentIdentityBlueprint）に対し
  発行者=テナント v2.0 / サブジェクト=UAMI の principalId / 対象=api://AzureADTokenExchange
  の FIC を登録する必要がある。

.NOTES
  Windows の az.cmd は Graph URI の ( ) ? $ = を壊すため、token だけ az で取得し
  Invoke-RestMethod で直接 Graph を叩く。
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$UamiPrincipalId,
    [Parameter(Mandatory)][string]$TenantId,
    [string]$BlueprintAppId,
    [string]$EnvFile = "$PSScriptRoot/../.env",
    [string]$Name = "aca-sidecar-uami"
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

if (-not $BlueprintAppId) {
    if (Test-Path $EnvFile) {
        $line = Get-Content $EnvFile | Where-Object { $_ -match '^\s*BLUEPRINT_APP_ID\s*=' } | Select-Object -First 1
        if ($line) { $BlueprintAppId = ($line -split "=", 2)[1].Trim().Trim('"') }
    }
}
if (-not $BlueprintAppId) { throw "BLUEPRINT_APP_ID を特定できません。-BlueprintAppId を指定してください。" }

$token = az account get-access-token --resource https://graph.microsoft.com --query accessToken -o tsv
$headers = @{ Authorization = "Bearer $token"; "Content-Type" = "application/json" }

# Blueprint アプリのオブジェクト ID を appId から解決
$filter = "appId eq '$BlueprintAppId'"
$appsUri = "https://graph.microsoft.com/v1.0/applications?`$filter=$([uri]::EscapeDataString($filter))"
$apps = Invoke-RestMethod -Method Get -Uri $appsUri -Headers $headers
if (-not $apps.value -or $apps.value.Count -lt 1) { throw "Blueprint アプリが見つかりません: appId=$BlueprintAppId" }
$appObjectId = $apps.value[0].id
Write-Host "Blueprint object id: $appObjectId"

$body = @{
    name      = $Name
    issuer    = "https://login.microsoftonline.com/$TenantId/v2.0"
    subject   = $UamiPrincipalId
    audiences = @("api://AzureADTokenExchange")
} | ConvertTo-Json

$ficUri = "https://graph.microsoft.com/v1.0/applications/$appObjectId/federatedIdentityCredentials"
try {
    $res = Invoke-RestMethod -Method Post -Uri $ficUri -Headers $headers -Body $body
    Write-Host "FIC を作成しました: $($res.name) (subject=$($res.subject))" -ForegroundColor Green
}
catch {
    $msg = $_.ErrorDetails.Message
    if ($msg -and $msg -match "FederatedIdentityCredential with name .* already exists") {
        Write-Host "FIC '$Name' は既に存在します（スキップ）。" -ForegroundColor Yellow
    }
    else {
        throw
    }
}
