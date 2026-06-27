#requires -Version 7.0
<#
.SYNOPSIS
    extLab1-3 / extLab1-4 用の OBO エンドツーエンド検証スクリプト。
    MSAL.PS でユーザー トークンを取得し、/obo-chat に渡して Graph 呼び出しが OBO 経由で
    成功することを確認する。

.PARAMETER BaseUrl
    Container App の URL
.PARAMETER ClientId
    chat-ui-obo クライアント アプリ（05 スクリプトで作成）の appId
.PARAMETER TenantId
    Entra テナント ID
.PARAMETER BlueprintAppId
    Blueprint の appId（スコープを api://{blueprint}/access_as_user として要求）

.EXAMPLE
    pwsh test-obo-end-to-end.ps1 -BaseUrl https://... -ClientId ... -TenantId ... -BlueprintAppId ...
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$BaseUrl,
    [Parameter(Mandatory=$true)][string]$ClientId,
    [Parameter(Mandatory=$true)][string]$TenantId,
    [Parameter(Mandatory=$true)][string]$BlueprintAppId,
    [string]$Message = 'あなたから見た私のプロフィールを Graph で取得して教えてください。'
)

$ErrorActionPreference = 'Stop'

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
