#requires -Version 7.0
<#
.SYNOPSIS
    Agent Identity SP に Microsoft Graph 委任権限（User.Read / User.ReadBasic.All）を付与する
    oauth2PermissionGrants を作成する。OBO 経路でテナント側同意済とみなされる。
    （lab5 OBO ハンズオンの Entra 構成スクリプト 3/3）

.DESCRIPTION
    OBO で Graph を呼ぶには、Agent Identity SP がそのテナント上で
    Graph の該当 delegated permission を「持っている」必要がある。
    通常はユーザー同意 / 管理者同意で `oauth2PermissionGrants` レコードが作られるが、
    Agent Identity SP は対話的同意フローを通らないので Graph 経由で直接 grant を投入する。

.PARAMETER AgentIdentityAppId
    lab2 の a365.generated.config.json の agenticAppId。未指定なら自動解決。

.PARAMETER UserPrincipalName
    (任意) 指定するとそのユーザー個別の同意。未指定はテナント全体（管理者同意相当）。
#>
[CmdletBinding()]
param(
    [string]$AgentIdentityAppId,
    [string]$UserPrincipalName,
    [string[]]$Scopes = @('User.Read', 'User.ReadBasic.All')
)

$ErrorActionPreference = 'Stop'

if (-not $AgentIdentityAppId) {
    $lab2Cfg = Join-Path $PSScriptRoot '..\..\..\lab2\a365.generated.config.json'
    if (Test-Path $lab2Cfg) {
        $cfg = Get-Content $lab2Cfg -Raw | ConvertFrom-Json
        $AgentIdentityAppId = $cfg.agenticAppId
    }
}
if (-not $AgentIdentityAppId) {
    throw 'AgentIdentityAppId を解決できません。-AgentIdentityAppId を指定してください。'
}

Write-Host '== Agent Identity に Graph delegated 権限 grant ==' -ForegroundColor Cyan

$agentSp = az ad sp list --filter "appId eq '$AgentIdentityAppId'" --query '[0]' -o json | ConvertFrom-Json
if (-not $agentSp) { throw "Agent Identity SP が見つかりません: $AgentIdentityAppId" }
$clientId = $agentSp.id

# Microsoft Graph SP (00000003-0000-0000-c000-000000000000)
$graphSp = az ad sp list --filter "appId eq '00000003-0000-0000-c000-000000000000'" --query '[0]' -o json | ConvertFrom-Json
$graphSpId = $graphSp.id

$principalId = $null
$consentType = 'AllPrincipals'
if ($UserPrincipalName) {
    $user = az ad user show --id $UserPrincipalName -o json | ConvertFrom-Json
    $principalId = $user.id
    $consentType = 'Principal'
}

# 期限（必須）
$expiry = (Get-Date).AddYears(1).ToString('yyyy-MM-ddTHH:mm:ssZ')

$scopeStr = ($Scopes -join ' ')
$body = @{
    clientId    = $clientId
    consentType = $consentType
    resourceId  = $graphSpId
    scope       = $scopeStr
    expiryTime  = $expiry
}
if ($principalId) { $body.principalId = $principalId }
$bodyJson = $body | ConvertTo-Json -Compress

# 既存検索（同じ resource + consentType + principal）
$query = "clientId eq '$clientId' and resourceId eq '$graphSpId'"
if ($principalId) { $query += " and principalId eq '$principalId'" }
$existingList = az rest --method GET `
    --uri "https://graph.microsoft.com/v1.0/oauth2PermissionGrants?`$filter=$([uri]::EscapeDataString($query))" `
    -o json | ConvertFrom-Json
$existing = $existingList.value | Select-Object -First 1

$tmp = New-TemporaryFile
try {
    Set-Content -Path $tmp -Value $bodyJson -Encoding utf8 -NoNewline
    if ($existing) {
        Write-Host "      既存 grant を更新: $($existing.id)" -ForegroundColor DarkGray
        az rest --method PATCH `
            --uri "https://graph.microsoft.com/v1.0/oauth2PermissionGrants/$($existing.id)" `
            --headers 'Content-Type=application/json' `
            --body "@$($tmp.FullName)" --only-show-errors | Out-Null
    }
    else {
        Write-Host '      新規 grant を作成' -ForegroundColor DarkGray
        az rest --method POST `
            --uri 'https://graph.microsoft.com/v1.0/oauth2PermissionGrants' `
            --headers 'Content-Type=application/json' `
            --body "@$($tmp.FullName)" --only-show-errors | Out-Null
    }
}
finally { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }

Write-Host ''
Write-Host '== 完了 ==' -ForegroundColor Cyan
Write-Host "Agent Identity SP : $clientId"
Write-Host "Resource          : Microsoft Graph ($graphSpId)"
Write-Host "Scopes            : $scopeStr"
Write-Host "Consent Type      : $consentType"
if ($UserPrincipalName) { Write-Host "Principal         : $UserPrincipalName ($principalId)" }
Write-Host "Expiry            : $expiry"
