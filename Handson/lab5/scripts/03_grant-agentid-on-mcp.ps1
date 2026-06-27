#requires -Version 7.0
<#
.SYNOPSIS
    Agent Identity SP に MCP リソース アプリ（contoso-mcp-api）のアプリロールを付与する。
    これにより Step 2a 自律型トークンの `roles` クレームに該当値が載り、MCP 側で出し分け可能になる。

.PARAMETER MCPAppId
    contoso-mcp-api の appId（02 スクリプト出力）。

.PARAMETER AgentIdentityAppId
    Lab1-2 の a365.generated.config.json の agenticAppId。

.PARAMETER Roles
    付与するアプリロール名の配列。既定 Policy.Read.All と Batch.Run。
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$MCPAppId,
    [Parameter(Mandatory=$true)][string]$AgentIdentityAppId,
    [string[]]$Roles = @('Policy.Read.All', 'Batch.Run')
)

$ErrorActionPreference = 'Stop'

Write-Host '== Agent Identity に MCP アプリロールを付与 ==' -ForegroundColor Cyan

# MCP SP の object id
$mcpSp = az ad sp list --filter "appId eq '$MCPAppId'" --query '[0]' -o json | ConvertFrom-Json
if (-not $mcpSp) { throw "MCP SP が見つかりません (appId=$MCPAppId)。02 スクリプトを先に実行してください。" }
$mcpSpId = $mcpSp.id

# Agent Identity SP の object id
$agentSp = az ad sp list --filter "appId eq '$AgentIdentityAppId'" --query '[0]' -o json | ConvertFrom-Json
if (-not $agentSp) { throw "Agent Identity SP が見つかりません (appId=$AgentIdentityAppId)。" }
$agentSpId = $agentSp.id
Write-Host "      Agent Identity SP objectId: $agentSpId" -ForegroundColor DarkGray

# 既存ロール定義を取得
$mcpApp = az ad app show --id $MCPAppId -o json | ConvertFrom-Json
$mcpRoles = @($mcpApp.appRoles)

foreach ($roleName in $Roles) {
    $role = $mcpRoles | Where-Object { $_.value -eq $roleName }
    if (-not $role) {
        Write-Host "[warn] MCP アプリに $roleName が無い（02 を再実行してください）。" -ForegroundColor Yellow
        continue
    }
    $roleId = $role.id

    # 既存付与チェック
    $existing = az rest --method GET `
        --uri "https://graph.microsoft.com/v1.0/servicePrincipals/$agentSpId/appRoleAssignments" `
        -o json | ConvertFrom-Json
    $hit = $existing.value | Where-Object { $_.resourceId -eq $mcpSpId -and $_.appRoleId -eq $roleId }
    if ($hit) {
        Write-Host "      既に付与済: $roleName" -ForegroundColor DarkGray
        continue
    }

    $body = @{
        principalId = $agentSpId
        resourceId  = $mcpSpId
        appRoleId   = $roleId
    } | ConvertTo-Json -Compress
    $tmp = New-TemporaryFile
    try {
        Set-Content -Path $tmp -Value $body -Encoding utf8 -NoNewline
        az rest --method POST `
            --uri "https://graph.microsoft.com/v1.0/servicePrincipals/$agentSpId/appRoleAssignments" `
            --headers 'Content-Type=application/json' `
            --body "@$($tmp.FullName)" --only-show-errors | Out-Null
    }
    finally { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
    Write-Host "      ロール付与: $roleName" -ForegroundColor Green
}

Write-Host ''
Write-Host '== 完了 ==' -ForegroundColor Cyan
Write-Host '次の確認:'
Write-Host '  Step 2a 自律型トークンを取得して `roles` クレームに上記が載るか確認。'
Write-Host '  pwsh scripts/test-autonomous-mcp.ps1'
