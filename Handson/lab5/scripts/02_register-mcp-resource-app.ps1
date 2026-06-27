#requires -Version 7.0
<#
.SYNOPSIS
    MCP を Entra 保護リソース化するアプリ登録を作成する。

.DESCRIPTION
    - アプリ名: contoso-mcp-api
    - identifierUri: api://contoso-mcp（指定可）
    - スコープ: access_as_user（ユーザー権限・OBO 用）
    - アプリロール: Policy.Read / Policy.Read.All / Batch.Run
      （Agent ID には extLab1-2 後段の 03 で付与）
    - 既存があれば idempotent に更新する。

.OUTPUTS
    .env に追記すべき MCP_RESOURCE_APP_ID / MCP_SCOPE を表示する。
#>
[CmdletBinding()]
param(
    [string]$DisplayName = 'contoso-mcp-api',
    [string]$IdentifierUri = 'api://contoso-mcp'
)

$ErrorActionPreference = 'Stop'

Write-Host "== MCP リソース アプリ登録: $DisplayName ==" -ForegroundColor Cyan

# 既存検索
$existing = az ad app list --display-name $DisplayName --query '[0]' -o json | ConvertFrom-Json
if ($existing) {
    $appId = $existing.appId
    $objectId = $existing.id
    Write-Host "      既存を使用: appId=$appId" -ForegroundColor DarkGray
}
else {
    Write-Host '      新規作成...' -ForegroundColor DarkGray
    $created = az ad app create --display-name $DisplayName --query '{appId:appId,id:id}' -o json | ConvertFrom-Json
    $appId = $created.appId
    $objectId = $created.id
}

# Service Principal も無ければ作成
$sp = az ad sp list --filter "appId eq '$appId'" --query '[0]' -o json | ConvertFrom-Json
if (-not $sp) {
    Write-Host '      Service Principal を作成...' -ForegroundColor DarkGray
    az ad sp create --id $appId --only-show-errors | Out-Null
}

# Scope (access_as_user) / Roles を idempotent に組み立てて PATCH
function New-Guid2 { [Guid]::NewGuid().ToString() }

# 既存値を一度取り出す
$current = az ad app show --id $appId -o json | ConvertFrom-Json
$existingApi = $current.api
$existingScopes = @()
if ($existingApi -and $existingApi.oauth2PermissionScopes) {
    $existingScopes = @($existingApi.oauth2PermissionScopes)
}
$existingRoles = @()
if ($current.appRoles) { $existingRoles = @($current.appRoles) }

function Get-OrCreateScope {
    param([string]$Name, [string]$Display, [string]$Desc)
    $hit = $existingScopes | Where-Object { $_.value -eq $Name } | Select-Object -First 1
    if ($hit) { return $hit }
    return @{
        id                      = (New-Guid2)
        adminConsentDescription = $Desc
        adminConsentDisplayName = $Display
        isEnabled               = $true
        type                    = 'User'
        userConsentDescription  = $Desc
        userConsentDisplayName  = $Display
        value                   = $Name
    }
}

function Get-OrCreateRole {
    param([string]$Name, [string]$Display, [string]$Desc)
    $hit = $existingRoles | Where-Object { $_.value -eq $Name } | Select-Object -First 1
    if ($hit) { return $hit }
    return @{
        id                 = (New-Guid2)
        allowedMemberTypes = @('Application')
        description        = $Desc
        displayName        = $Display
        isEnabled          = $true
        value              = $Name
    }
}

$scopeAccess = Get-OrCreateScope 'access_as_user' 'Access Contoso MCP as user' 'Allows the app to access Contoso MCP on behalf of the signed-in user.'
$rolePolicyRead    = Get-OrCreateRole 'Policy.Read'     'Read policy (self)'  'Read policies scoped to the calling agent.'
$rolePolicyReadAll = Get-OrCreateRole 'Policy.Read.All' 'Read all policies'   'Read every policy via the MCP.'
$roleBatchRun      = Get-OrCreateRole 'Batch.Run'       'Run batch'           'Run batch operations through the MCP.'

# preAuthorizedApplications: Agent Identity に同意不要で使わせるためのオプション
# （extLab1-1 段階では未使用。OBO 経路を Lab1-3 で組む時にもう一度叩く）

$body = @{
    identifierUris = @($IdentifierUri)
    api            = @{
        oauth2PermissionScopes = @($scopeAccess)
    }
    appRoles       = @($rolePolicyRead, $rolePolicyReadAll, $roleBatchRun)
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

Write-Host ''
Write-Host '== 完了 ==' -ForegroundColor Cyan
Write-Host "appId        : $appId"
Write-Host "identifierUri: $IdentifierUri"
Write-Host "appRoles     : Policy.Read / Policy.Read.All / Batch.Run"
Write-Host "scope        : access_as_user"
Write-Host ''
Write-Host '.env に次を追記してください:' -ForegroundColor Cyan
Write-Host "  MCP_RESOURCE_APP_ID=$appId"
Write-Host "  MCP_SCOPE=$IdentifierUri/.default"
