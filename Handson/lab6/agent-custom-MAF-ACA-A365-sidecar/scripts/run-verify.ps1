<#
.SYNOPSIS
  サイドカー + B エージェント（Contoso /chat）を起動し、/chat スモークテストを実行する。

.DESCRIPTION
  1) docker compose up -d --build（sidecar = Entra SDK for AgentID, agent = B の MAF /chat）
  2) サイドカー /healthz とエージェント /healthz が 200 を返すまで待機
  3) POST /chat に質問を投げ、応答本文を表示
  4) GET /debug/auth で出口トークン（aud=cognitiveservices）の発行記録を表示

  これにより「LLM / MCP の出口トークンをサイドカー（Agent Identity）から取得して
  APIM AI Gateway 経由で Contoso エージェントが動く」ことを一気通貫で確認できる。

.NOTES
  - 事前に ./scripts/prepare-env.ps1 で .env を生成しておくこと。
  - Docker Desktop が起動している必要がある。
#>
[CmdletBinding()]
param(
    [int]$HealthTimeoutSec = 120,
    [string]$SidecarHealthUrl = 'http://localhost:5001/healthz',
    [string]$AgentBaseUrl     = 'http://localhost:8000',
    [string]$Message          = 'Contoso の返品ポリシーを教えてください。'
)

$ErrorActionPreference = 'Stop'
$labDir = Resolve-Path (Join-Path $PSScriptRoot '..')
Push-Location $labDir
try {
    if (-not (Test-Path (Join-Path $labDir '.env'))) {
        throw ".env がありません。先に ./scripts/prepare-env.ps1 を実行してください。"
    }

    Write-Host "[1] sidecar + agent を起動（build 込み）..." -ForegroundColor Cyan
    docker compose up -d --build
    if ($LASTEXITCODE -ne 0) { throw "docker compose up に失敗しました。Docker Desktop が起動しているか確認してください。" }

    Write-Host "[2] サイドカー /healthz を待機（最大 ${HealthTimeoutSec}s）..." -ForegroundColor Cyan
    $deadline = (Get-Date).AddSeconds($HealthTimeoutSec)
    $healthy = $false
    while ((Get-Date) -lt $deadline) {
        try {
            $r = Invoke-WebRequest -Uri $SidecarHealthUrl -UseBasicParsing -TimeoutSec 5
            if ($r.StatusCode -eq 200) { $healthy = $true; break }
        } catch { Start-Sleep -Seconds 2 }
    }
    if (-not $healthy) {
        Write-Host "サイドカーが healthy になりませんでした。ログ:" -ForegroundColor Yellow
        docker compose logs --tail 50 sidecar
        throw "サイドカー /healthz タイムアウト。"
    }
    Write-Host "    -> サイドカー OK" -ForegroundColor Green

    Write-Host "[3] エージェント /healthz を待機..." -ForegroundColor Cyan
    $deadline = (Get-Date).AddSeconds($HealthTimeoutSec)
    $agentUp = $false
    while ((Get-Date) -lt $deadline) {
        try {
            $r = Invoke-WebRequest -Uri "$AgentBaseUrl/healthz" -UseBasicParsing -TimeoutSec 5
            if ($r.StatusCode -eq 200) { $agentUp = $true; break }
        } catch { Start-Sleep -Seconds 3 }
    }
    if (-not $agentUp) {
        Write-Host "エージェントが healthy になりませんでした。ログ:" -ForegroundColor Yellow
        docker compose logs --tail 80 agent
        throw "エージェント /healthz タイムアウト。"
    }
    Write-Host "    -> エージェント OK" -ForegroundColor Green

    Write-Host "[4] POST /chat スモークテスト..." -ForegroundColor Cyan
    Write-Host "    質問: $Message"
    $body = @{ message = $Message } | ConvertTo-Json -Compress
    try {
        $resp = Invoke-RestMethod -Method Post -Uri "$AgentBaseUrl/chat" `
            -ContentType 'application/json' -Body $body -TimeoutSec 120
        Write-Host "    応答:" -ForegroundColor Green
        Write-Host ($resp | ConvertTo-Json -Depth 6)
    } catch {
        Write-Host "    /chat が失敗しました（出口トークン取得失敗なら 500 = fail-closed）。ログ:" -ForegroundColor Yellow
        docker compose logs --tail 80 agent
        throw
    }

    Write-Host "[5] GET /debug/auth（出口トークン発行記録）..." -ForegroundColor Cyan
    try {
        $dbg = Invoke-RestMethod -Method Get -Uri "$AgentBaseUrl/debug/auth" -TimeoutSec 30
        Write-Host ($dbg | ConvertTo-Json -Depth 6)
    } catch {
        Write-Host "    /debug/auth の取得に失敗しました（致命的ではありません）。" -ForegroundColor Yellow
    }

    Write-Host ""
    Write-Host "完了。停止する場合: docker compose down" -ForegroundColor Cyan
}
finally {
    Pop-Location
}
