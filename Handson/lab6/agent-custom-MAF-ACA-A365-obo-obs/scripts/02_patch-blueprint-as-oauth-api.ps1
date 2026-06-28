#requires -Version 7.0
<#
.SYNOPSIS
    Blueprint アプリを OAuth API 化するために必要な 4 要素を Graph PATCH で設定する。
    （lab5 OBO ハンズオンの Entra 構成スクリプト 2/3）

.DESCRIPTION
    a365 setup all では設定されない以下を一括投入する:
      1. identifierUris : ["api://{blueprint-app-id}"]
      2. api.oauth2PermissionScopes : access_as_user
      3. preAuthorizedApplications : 指定の Client App ID（OBO チャット UI）
      4. optionalClaims.accessToken : idtyp（user/app 判別用）
      5. api.requestedAccessTokenVersion = 2

    既存値があれば保持しつつマージ更新する。requestedAccessTokenVersion = 2 により
    ユーザー トークンは v2 形式となり、aud は api://{blueprint} ではなく Blueprint の
    appId（GUID）になる。エージェント側の OBO 検証（obo_validator.py）は api:// 形式と
    GUID 形式の両方を受理するため、どちらのトークンバージョンでも user_assertion として使える。

.PARAMETER BlueprintAppId
    lab2 の a365.generated.config.json の agentBlueprintId。未指定なら自動解決。

.PARAMETER ClientAppId
    OBO チャット UI のクライアント アプリ appId（01 スクリプトの出力）。
#>
[CmdletBinding()]
param(
    [string]$BlueprintAppId,
    [Parameter(Mandatory=$true)][string]$ClientAppId
)

$ErrorActionPreference = 'Stop'

if (-not $BlueprintAppId) {
    $lab2Cfg = Join-Path $PSScriptRoot '..\..\..\lab2\a365.generated.config.json'
    if (Test-Path $lab2Cfg) {
        $cfg = Get-Content $lab2Cfg -Raw | ConvertFrom-Json
        $BlueprintAppId = $cfg.agentBlueprintId
    }
}
if (-not $BlueprintAppId) {
    throw 'BlueprintAppId を解決できません。-BlueprintAppId を指定してください。'
}

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

# 既存スコープ（a365 由来の access_agent_as_user 等）を保持したままマージする。
# 既存の有効スコープを送らずに上書きすると
# CannotDeleteOrUpdateEnabledEntitlement で拒否されるため。
$mergedScopes = @($existingScopes)
if (-not ($existingScopes | Where-Object { $_.value -eq 'access_as_user' })) {
    $mergedScopes = @($existingScopes + $scope)
}

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
        oauth2PermissionScopes    = $mergedScopes
        requestedAccessTokenVersion = 2
    }
    optionalClaims  = $optional
} | ConvertTo-Json -Depth 12 -Compress

function Invoke-AppPatch([string]$ObjectId, [string]$Json) {
    $tmp = New-TemporaryFile
    try {
        Set-Content -Path $tmp -Value $Json -Encoding utf8 -NoNewline
        az rest --method PATCH `
            --uri "https://graph.microsoft.com/v1.0/applications/$ObjectId" `
            --headers 'Content-Type=application/json' `
            --body "@$($tmp.FullName)" --only-show-errors | Out-Null
    }
    finally { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
}

# Phase 1: identifierUri / scope / tokenVersion / optionalClaims を先に確定する。
#   preAuthorizedApplications.delegatedPermissionIds は「永続化済みスコープ」しか
#   参照できず、新規 scopeId を同一 PATCH で参照すると Graph が
#   "Permission Id cannot be found in the AppPermissions sets" で全体を拒否する。
Invoke-AppPatch $objectId $body

# Phase 2: 永続化済みスコープを参照して preAuthorizedApplications を追加する。
#   api プロパティは置換されるため oauth2PermissionScopes / tokenVersion も再送する。
$body2 = @{
    api = @{
        oauth2PermissionScopes      = $mergedScopes
        requestedAccessTokenVersion = 2
        preAuthorizedApplications   = $preAuth
    }
} | ConvertTo-Json -Depth 12 -Compress
Invoke-AppPatch $objectId $body2

Write-Host ''
Write-Host '== 完了 ==' -ForegroundColor Cyan
Write-Host "Blueprint App ID  : $BlueprintAppId"
Write-Host "identifierUri     : $identifierUri"
Write-Host "scope             : access_as_user"
Write-Host "preAuthorized     : $ClientAppId"
Write-Host "optionalClaims    : idtyp"
Write-Host "tokenVersion      : 2"
Write-Host ''
Write-Host '.env / prepare-env.ps1 で次が設定されます:' -ForegroundColor Cyan
Write-Host "  BLUEPRINT_API_AUDIENCE=$identifierUri"
