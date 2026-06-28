<#
.SYNOPSIS
    chat-ui-obo/.env を自動生成する。

.DESCRIPTION
    OBO チャット UI（lab5\chat-ui-obo）が必要とする 4 つの環境変数を解決して
    .env を書き出す。値は可能な限り自動解決し、解決できない場合のみ警告する。

      - AZURE_TENANT_ID  : az account show のテナント（-TenantId で上書き可）
      - AAD_CLIENT_ID    : 01 が作成した Public Client（既定 displayName: contoso-obo-chat-ui）
      - BLUEPRINT_APP_ID : lab2\a365.generated.config.json の agentBlueprintId
      - AGENT_BASE_URL   : -AgentBaseUrl 指定値。未指定なら ACA から自動探索を試みる。

    既存の .env がある場合は .env.bak に退避してから上書きする。

.EXAMPLE
    pwsh .\04_generate-chat-ui-env.ps1
    pwsh .\04_generate-chat-ui-env.ps1 -AgentBaseUrl https://custom-maf-a365-obo-user01.japaneast.azurecontainerapps.io
#>
[CmdletBinding()]
param(
    [string]$TenantId,
    [string]$ClientAppId,
    [string]$BlueprintAppId,
    [string]$AgentBaseUrl,
    [string]$DisplayName = 'contoso-obo-chat-ui',
    # AGENT_BASE_URL 自動探索時に使う ACA 名のプレフィックス
    [string]$AcaNamePrefix = 'custom-maf-a365-obo'
)

$ErrorActionPreference = 'Stop'

Write-Host '== chat-ui-obo/.env 生成 ==' -ForegroundColor Cyan

# --- TenantId ---
if (-not $TenantId) {
    $TenantId = az account show --query tenantId -o tsv 2>$null
}
if (-not $TenantId) { throw 'TenantId を解決できません。-TenantId を指定するか az login してください。' }

# --- BlueprintAppId（lab2 の生成 config から自動解決） ---
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

# --- ClientAppId（01 が作成した Public Client を displayName で検索） ---
if (-not $ClientAppId) {
    $ClientAppId = az ad app list --display-name $DisplayName --query '[0].appId' -o tsv 2>$null
}
if (-not $ClientAppId) {
    throw "ClientAppId を解決できません。先に 01_register-obo-client-app.ps1 を実行するか -ClientAppId を指定してください。（displayName: $DisplayName）"
}

# --- AgentBaseUrl（未指定なら ACA から探索） ---
if (-not $AgentBaseUrl) {
    Write-Host "[info] AGENT_BASE_URL 未指定。ACA から '$AcaNamePrefix*' を探索します..." -ForegroundColor Yellow
    $fqdns = az containerapp list `
        --query "[?starts_with(name, '$AcaNamePrefix')].properties.configuration.ingress.fqdn" -o tsv 2>$null
    $fqdns = @($fqdns | Where-Object { $_ })
    if ($fqdns.Count -eq 1) {
        $AgentBaseUrl = "https://$($fqdns[0])"
        Write-Host "[ok]   ACA を 1 件検出: $AgentBaseUrl" -ForegroundColor Green
    }
    elseif ($fqdns.Count -gt 1) {
        Write-Host "[warn] 候補が複数あります。-AgentBaseUrl で明示してください:" -ForegroundColor Yellow
        $fqdns | ForEach-Object { Write-Host "         https://$_" }
        $AgentBaseUrl = 'https://custom-maf-a365-obo-userNN.<region>.azurecontainerapps.io'
    }
    else {
        Write-Host "[warn] ACA が見つかりません。プレースホルダーを書き込みます（後で .env を手修正してください）。" -ForegroundColor Yellow
        $AgentBaseUrl = 'https://custom-maf-a365-obo-userNN.<region>.azurecontainerapps.io'
    }
}

# --- .env 書き出し ---
$envPath = Join-Path $PSScriptRoot '..\..\chat-ui-obo\.env'
$envPath = [System.IO.Path]::GetFullPath($envPath)

if (Test-Path $envPath) {
    Copy-Item $envPath "$envPath.bak" -Force
    Write-Host "[info] 既存 .env を $envPath.bak に退避しました。" -ForegroundColor DarkGray
}

$lines = @(
    '# lab5 chat-ui-obo 用（04_generate-chat-ui-env.ps1 が生成）'
    "AZURE_TENANT_ID=$TenantId"
    "AAD_CLIENT_ID=$ClientAppId"
    "BLUEPRINT_APP_ID=$BlueprintAppId"
    "AGENT_BASE_URL=$AgentBaseUrl"
)
Set-Content -Path $envPath -Value $lines -Encoding utf8

Write-Host ''
Write-Host '== 完了 ==' -ForegroundColor Cyan
Write-Host "出力先          : $envPath"
Write-Host "AZURE_TENANT_ID : $TenantId"
Write-Host "AAD_CLIENT_ID   : $ClientAppId"
Write-Host "BLUEPRINT_APP_ID: $BlueprintAppId"
Write-Host "AGENT_BASE_URL  : $AgentBaseUrl"
if ($AgentBaseUrl -like '*userNN*') {
    Write-Host ''
    Write-Host '[!] AGENT_BASE_URL がプレースホルダーのままです。.env を手で修正してください。' -ForegroundColor Red
}
