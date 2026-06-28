#requires -Version 7.0
<#
.SYNOPSIS
    lab5 OBO エンドツーエンド検証スクリプト。
    MSAL.PS でユーザー トークンを取得し、/obo-chat に渡して Graph 呼び出しが
    OBO 経由（Step 2b）で成功することを確認する。

.PARAMETER BaseUrl
    Container App の URL（例: https://custom-maf-a365-obo-userNN.xxxx.eastus2.azurecontainerapps.io）。
.PARAMETER ClientId
    OBO チャット UI クライアント アプリ（01 スクリプトで作成）の appId。
.PARAMETER TenantId
    Entra テナント ID。未指定なら az アカウントのテナントを使用。
.PARAMETER BlueprintAppId
    Blueprint の appId（スコープを api://{blueprint}/access_as_user として要求）。未指定なら lab2 から自動解決。

.EXAMPLE
    pwsh test-obo-end-to-end.ps1 -BaseUrl https://... -ClientId ...
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$BaseUrl,
    [string]$ClientId,
    [string]$TenantId,
    [string]$BlueprintAppId,
    [string]$Message = 'あなたから見た私のプロフィールを Graph で取得して教えてください。'
)

$ErrorActionPreference = 'Stop'

# lab2 config / az アカウントから既定値を解決
$lab2Cfg = Join-Path $PSScriptRoot '..\..\..\lab2\a365.generated.config.json'
if ((-not $BlueprintAppId) -and (Test-Path $lab2Cfg)) {
    $cfg = Get-Content $lab2Cfg -Raw | ConvertFrom-Json
    $BlueprintAppId = $cfg.agentBlueprintId
}
if (-not $BlueprintAppId) { throw '-BlueprintAppId を指定してください（lab2 config から解決できませんでした）。' }
if (-not $TenantId) { $TenantId = az account show --query tenantId -o tsv 2>$null }
if (-not $ClientId) { throw '-ClientId（OBO チャット UI クライアント アプリ appId）を指定してください。' }

if (-not (Get-Module -ListAvailable -Name MSAL.PS)) {
    Write-Host '[info] MSAL.PS をインストール中 (CurrentUser)...' -ForegroundColor Yellow
    Install-Module MSAL.PS -Scope CurrentUser -Force -AcceptLicense
}
Import-Module MSAL.PS -Force

$scope = "api://$BlueprintAppId/access_as_user"
Write-Host "== ユーザー トークン取得 ==" -ForegroundColor Cyan
Write-Host "  scope = $scope" -ForegroundColor DarkGray

$tokenResult = Get-MsalToken `
    -ClientId $ClientId `
    -TenantId $TenantId `
    -Scopes $scope `
    -RedirectUri 'http://localhost' `
    -Interactive

$userToken = $tokenResult.AccessToken
Write-Host "  取得 OK (len=$($userToken.Length))" -ForegroundColor Green

# 簡易にデコードして aud / scp を表示
$parts = $userToken -split '\.'
if ($parts.Length -ge 2) {
    $pad = $parts[1].PadRight([math]::Ceiling($parts[1].Length / 4.0) * 4, '=')
    $json = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($pad.Replace('-', '+').Replace('_', '/')))
    $claims = $json | ConvertFrom-Json
    Write-Host "  aud = $($claims.aud) / scp = $($claims.scp) / sub = $($claims.sub)" -ForegroundColor DarkGray
}

Write-Host ''
Write-Host '== /obo-chat ==' -ForegroundColor Cyan
$body = @{ message = $Message } | ConvertTo-Json
$headers = @{
    'Authorization' = "Bearer $userToken"
    'Content-Type'  = 'application/json'
}
try {
    $r = Invoke-RestMethod -Uri "$BaseUrl/obo-chat" -Method Post -Headers $headers -Body $body
    $r | ConvertTo-Json -Depth 10
}
catch {
    Write-Host "[error] $($_.Exception.Message)" -ForegroundColor Red
    if ($_.ErrorDetails) { Write-Host $_.ErrorDetails.Message -ForegroundColor Red }
    throw
}
