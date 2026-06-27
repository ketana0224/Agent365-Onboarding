#requires -Version 7.0
<#
.SYNOPSIS
    Blueprint アプリを OAuth API 化するために必要な 4 要素を Graph PATCH で設定する。

.DESCRIPTION
    a365 setup all では設定されない以下を一括投入する:
      1. identifierUris : ["api://{blueprint-app-id}"]
      2. api.oauth2PermissionScopes : access_as_user
      3. preAuthorizedApplications : 指定の Client App ID
      4. optionalClaims.accessToken : idtyp（user/app 判別用）

    既存値があれば保持しつつマージ更新する。

.PARAMETER BlueprintAppId
    Lab1-2 の a365.generated.config.json の agentBlueprintId。

.PARAMETER ClientAppId
    OBO チャット UI（または任意のフロント）のクライアント アプリ appId。
    まだ存在しないなら 05 スクリプトを先に実行してから本スクリプトを呼ぶ。
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$BlueprintAppId,
    [Parameter(Mandatory=$true)][string]$ClientAppId
)

$ErrorActionPreference = 'Stop'

Write-Host '== Blueprint アプリを OAuth API 化 ==' -ForegroundColor Cyan

$app = az ad app list --filter "appId eq '$BlueprintAppId'" --query '[0]' -o json | ConvertFrom-Json
if (-not $app) { throw "Blueprint アプリが見つかりません: $BlueprintAppId" }
$objectId = $app.id

$identifierUri = "api://$BlueprintAppId"

# scope を組み立て（既存があれば再利用）
$existingScopes = @()
if ($app.api -and $app.api.oauth2PermissionScopes) { $existingScopes = @($app.api.oauth2PermissionScopes) }
$scope = $existingScopes | Where-Object { $_.value -eq 'access_as_user' } | Select-Object -First 1
if (-not $scope) {
    $scope = @{
        id                      = ([Guid]::NewGuid().ToString())
        adminConsentDescription = 'Allow this app to access the Blueprint API on behalf of the signed-in user.'
        adminConsentDisplayName = 'Access Blueprint API as user'
        isEnabled               = $true
        type                    = 'User'
        userConsentDescription  = 'Allow this app to access the Blueprint API on your behalf.'
        userConsentDisplayName  = 'Access Blueprint API'
        value                   = 'access_as_user'
    }
}
$scopeId = $scope.id

# preAuthorizedApplications
$existingPreAuth = @()
if ($app.api -and $app.api.preAuthorizedApplications) { $existingPreAuth = @($app.api.preAuthorizedApplications) }
$preAuthHit = $existingPreAuth | Where-Object { $_.appId -eq $ClientAppId }
if (-not $preAuthHit) {
    $preAuth = @($existingPreAuth + @{
        appId                  = $ClientAppId
        delegatedPermissionIds = @($scopeId)
    })
}
else {
    # 同じ scope を既存に含んでいなければ追加
    $merged = @()
    foreach ($p in $existingPreAuth) {
        if ($p.appId -eq $ClientAppId) {
            $ids = @($p.delegatedPermissionIds)
            if (-not ($ids -contains $scopeId)) { $ids += $scopeId }
            $merged += @{ appId = $p.appId; delegatedPermissionIds = $ids }
        }
        else { $merged += $p }
    }
    $preAuth = $merged
}

# optionalClaims (idtyp)
$existingOptional = $app.optionalClaims
if (-not $existingOptional) { $existingOptional = @{ accessToken = @(); idToken = @(); saml2Token = @() } }
$accessClaims = @($existingOptional.accessToken)
if (-not ($accessClaims | Where-Object { $_.name -eq 'idtyp' })) {
    $accessClaims += @{
        name                 = 'idtyp'
        essential            = $false
        additionalProperties = @()
    }
}
$optional = @{
    accessToken = $accessClaims
    idToken     = @($existingOptional.idToken)
    saml2Token  = @($existingOptional.saml2Token)
}

$body = @{
    identifierUris  = @($identifierUri)
    api             = @{
        oauth2PermissionScopes    = @($scope)
        preAuthorizedApplications = $preAuth
        requestedAccessTokenVersion = 2
    }
    optionalClaims  = $optional
} | ConvertTo-Json -Depth 12 -Compress

$tmp = New-TemporaryFile
try {
    Set-Content -Path $tmp -Value $body -Encoding utf8 -NoNewline
    az rest --method PATCH `
        --uri "https://graph.microsoft.com/v1.0/applications/$objectId" `
        --headers 'Content-Type=application/json' `
        --body "@$($tmp.FullName)" --only-show-errors | Out-Null
}
finally { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }

Write-Host ''
Write-Host '== 完了 ==' -ForegroundColor Cyan
Write-Host "Blueprint App ID  : $BlueprintAppId"
Write-Host "identifierUri     : $identifierUri"
Write-Host "scope             : access_as_user"
Write-Host "preAuthorized     : $ClientAppId"
Write-Host "optionalClaims    : idtyp"
Write-Host ''
Write-Host '.env に次を追記してください:' -ForegroundColor Cyan
Write-Host "  BLUEPRINT_API_AUDIENCE=$identifierUri"
