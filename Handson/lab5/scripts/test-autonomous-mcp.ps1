#requires -Version 7.0
<#
.SYNOPSIS
    extLab1-1 / extLab1-2 用の自律型 (autonomous) 検証スクリプト。
    /chat エンドポイントを叩き、MCP がどの方式（API Key / Bearer）で動いているか確認する。

.DESCRIPTION
    1) /healthz
    2) /chat に MCP を必ず使う問い合わせを投げる (返金ポリシー)
    3) Container App のログから MCP 呼び出しモード行を取得して表示

.PARAMETER BaseUrl
    deploy-aca.ps1 の出力 URL。例: https://custom-maf-agent-a365-ext.....azurecontainerapps.io
.PARAMETER AppName / ResourceGroup
    ログ確認用（省略可）。
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$BaseUrl,
    [string]$AppName = 'custom-maf-agent-a365-ext',
    [string]$ResourceGroup,
    [string]$Message = '返金ポリシーを教えてください。MCP を必ず利用すること。'
)

$ErrorActionPreference = 'Stop'
Write-Host '== /healthz ==' -ForegroundColor Cyan
$h = Invoke-RestMethod -Uri "$BaseUrl/healthz" -Method Get
$h | ConvertTo-Json -Depth 5

Write-Host ''
Write-Host '== /chat (autonomous) ==' -ForegroundColor Cyan
$body = @{ message = $Message } | ConvertTo-Json
$r = Invoke-RestMethod -Uri "$BaseUrl/chat" -Method Post -ContentType 'application/json' -Body $body
$r | ConvertTo-Json -Depth 10

if ($ResourceGroup) {
    Write-Host ''
    Write-Host '== 直近ログから MCP モード行を抽出 ==' -ForegroundColor Cyan
    Start-Sleep 3
    az containerapp logs show -n $AppName -g $ResourceGroup --tail 200 --type console 2>$null `
        | Select-String -Pattern '\[MCP\]','mode=','Agent ID Bearer'
}
