#requires -Version 7.0
<#
.SYNOPSIS
    OBO チャット UI（Streamlit + MSAL）用のパブリック クライアント アプリ登録を作成する。
    （lab5 OBO ハンズオンの最初に実行する Entra 構成スクリプト 1/3）

.DESCRIPTION
    - PublicClient + RedirectUri: http://localhost / http://localhost:8501 (Device Code / Interactive 両対応)
    - Blueprint アプリの api://{blueprint}/access_as_user を委任 API 権限として要求
    - 02 スクリプト（patch-blueprint-as-oauth-api）の preAuthorizedApplications で
      「管理者同意済」相当になる前提

.PARAMETER BlueprintAppId
    lab2 の a365.generated.config.json の agentBlueprintId（Blueprint アプリ appId）。
    未指定なら ..\..\lab2 配下の a365.generated.config.json から自動解決する。

.OUTPUTS
    chat-ui-obo/.env に書き込むべき AAD_CLIENT_ID 等を表示。
#>
[CmdletBinding()]
param(
    [string]$BlueprintAppId,
    [string]$DisplayName = 'contoso-obo-chat-ui'
)

$ErrorActionPreference = 'Stop'

# lab2 の生成済み config から Blueprint appId を自動解決
if (-not $BlueprintAppId) {
    $lab2Cfg = Join-Path $PSScriptRoot '..\..\..\lab2\a365.generated.config.json'
    if (Test-Path $lab2Cfg) {
        $cfg = Get-Content $lab2Cfg -Raw | ConvertFrom-Json
        $BlueprintAppId = $cfg.agentBlueprintId
    }
}
if (-not $BlueprintAppId) {
    throw 'BlueprintAppId を解決できません。-BlueprintAppId を指定するか lab2 の a365.generated.config.json を用意してください。'
}

Write-Host "== OBO チャット UI クライアント アプリ登録: $DisplayName ==" -ForegroundColor Cyan

# 既存検索
$existing = az ad app list --display-name $DisplayName --query '[0]' -o json | ConvertFrom-Json
if ($existing) {
    $appId = $existing.appId
    $objectId = $existing.id
    Write-Host "      既存を使用: appId=$appId" -ForegroundColor DarkGray
}
else {
    Write-Host '      新規作成...' -ForegroundColor DarkGray
    $created = az ad app create --display-name $DisplayName `
        --sign-in-audience AzureADMyOrg `
        --public-client-redirect-uris http://localhost http://localhost:8501 `
        --is-fallback-public-client true `
        --query '{appId:appId,id:id}' -o json | ConvertFrom-Json
    $appId = $created.appId
    $objectId = $created.id
}

# SP も無ければ作成
$sp = az ad sp list --filter "appId eq '$appId'" --query '[0]' -o json | ConvertFrom-Json
if (-not $sp) {
    az ad sp create --id $appId --only-show-errors | Out-Null
}

# Blueprint の access_as_user scope id を取得
$blueprint = az ad app show --id $BlueprintAppId -o json | ConvertFrom-Json
$scope = $blueprint.api.oauth2PermissionScopes | Where-Object { $_.value -eq 'access_as_user' } | Select-Object -First 1
if (-not $scope) {
    Write-Host '[info] Blueprint に access_as_user scope がまだありません。先に 02 を実行すると作成されます。' -ForegroundColor Yellow
    Write-Host '       いったん 02 を実行 → 本スクリプトを再実行すると requiredResourceAccess を確定できます。' -ForegroundColor Yellow
    $scopeId = $null
}
else {
    $scopeId = $scope.id
}

# requiredResourceAccess を PATCH（scope が確定しているときのみ）
if ($scopeId) {
    $body = @{
        requiredResourceAccess = @(
            @{
                resourceAppId  = $BlueprintAppId
                resourceAccess = @(
                    @{ id = $scopeId; type = 'Scope' }
                )
            }
        )
        publicClient = @{
            redirectUris = @('http://localhost','http://localhost:8501')
        }
        isFallbackPublicClient = $true
    } | ConvertTo-Json -Depth 10 -Compress

    $tmp = New-TemporaryFile
    try {
        Set-Content -Path $tmp -Value $body -Encoding utf8 -NoNewline
        az rest --method PATCH `
            --uri "https://graph.microsoft.com/v1.0/applications/$objectId" `
            --headers 'Content-Type=application/json' `
            --body "@$($tmp.FullName)" --only-show-errors | Out-Null
    }
    finally { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
}

Write-Host ''
Write-Host '== 完了 ==' -ForegroundColor Cyan
Write-Host "Client App ID        : $appId"
Write-Host "Requested scope      : api://$BlueprintAppId/access_as_user"
Write-Host "Redirect URIs        : http://localhost, http://localhost:8501"
Write-Host ''
Write-Host 'chat-ui-obo/.env に次を設定:' -ForegroundColor Cyan
Write-Host "  AAD_CLIENT_ID=$appId"
Write-Host "  BLUEPRINT_APP_ID=$BlueprintAppId"
Write-Host ''
Write-Host '次に 02 スクリプトを実行（Blueprint を OAuth API 化 + preAuthorizedApplications 登録）:'
Write-Host "  pwsh scripts/02_patch-blueprint-as-oauth-api.ps1 -BlueprintAppId $BlueprintAppId -ClientAppId $appId"
