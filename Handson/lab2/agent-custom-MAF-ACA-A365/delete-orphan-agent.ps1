<#
.SYNOPSIS
  Agent 365 レジストリ(管理センター > Agents)に二重登録された
  "custom-maf-agent-a365 Agent" の孤児 agentRegistration を削除する。

.DESCRIPTION
  - 管理センターの「Agents」は Agent 365 レジストリ(Agent Registration API / beta)由来。
    Entra アプリ/SP でも Teams カタログでもない。
  - エンドポイント:
      LIST   GET    https://graph.microsoft.com/beta/copilot/agentRegistrations
      GET    GET    https://graph.microsoft.com/beta/copilot/agentRegistrations/{id}
      DELETE DELETE https://graph.microsoft.com/beta/copilot/agentRegistrations/{id}
    必要スコープ(委任): AgentRegistration.ReadWrite.All
  - az の Graph トークンには当該スコープが無いため、デバイスコード フローで取得する。
  - 既定は -List(読み取りのみ)。削除は -Delete <id> を明示したときだけ。

.EXAMPLE
  pwsh -File .\delete-orphan-agent.ps1 -List
  pwsh -File .\delete-orphan-agent.ps1 -Delete T_13d79b9c-1672-9bd3-9308-3f5fb9799f07
#>
[CmdletBinding()]
param(
    [switch]$List,
    [string]$Delete
)

$ErrorActionPreference = 'Stop'

# --- 残すべき値(現役) ---
$KeeperBlueprintAppId   = 'e65ce763-b70a-4991-854c-788c2862fb08'
$KeeperRegistrationId   = 'T_a1c916c0-53bb-e435-f167-d318842f0094'
$AgentDisplayNameMatch  = 'custom-maf-agent-a365'

# Microsoft Graph PowerShell の公開クライアント(デバイスコード対応)
$ClientId  = '14d82eec-204b-4c2f-b7e8-296a70dab67e'
$Scope     = 'AgentRegistration.ReadWrite.All offline_access'
$GraphBase = 'https://graph.microsoft.com/beta'

function Get-TenantId {
    try { return (az account show --query tenantId -o tsv 2>$null) } catch { return $null }
}

function Get-GraphToken {
    param([string]$TenantId)
    if (-not $TenantId) { $TenantId = 'organizations' }
    $base = "https://login.microsoftonline.com/$TenantId/oauth2/v2.0"

    $dc = Invoke-RestMethod -Method Post -Uri "$base/devicecode" -Body @{
        client_id = $ClientId
        scope     = $Scope
    }
    Write-Host ""
    Write-Host "==================== サインインが必要 ====================" -ForegroundColor Cyan
    Write-Host $dc.message -ForegroundColor Yellow
    Write-Host "  (Global Administrator でサインインしてください)" -ForegroundColor DarkGray
    Write-Host "=========================================================" -ForegroundColor Cyan
    Write-Host ""

    $interval = [int]$dc.interval
    $deadline = (Get-Date).AddSeconds([int]$dc.expires_in)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds $interval
        try {
            $tok = Invoke-RestMethod -Method Post -Uri "$base/token" -Body @{
                grant_type  = 'urn:ietf:params:oauth:grant-type:device_code'
                client_id   = $ClientId
                device_code = $dc.device_code
            }
            return $tok.access_token
        }
        catch {
            $err = $_.ErrorDetails.Message | ConvertFrom-Json -ErrorAction SilentlyContinue
            switch ($err.error) {
                'authorization_pending' { continue }
                'slow_down'             { $interval += 5; continue }
                default { throw "トークン取得失敗: $($err.error) - $($err.error_description)" }
            }
        }
    }
    throw "デバイスコードの有効期限切れ。再実行してください。"
}

function Get-OneRegistration {
    param([string]$Token, [string]$Id)
    $h = @{ Authorization = "Bearer $Token" }
    try {
        return Invoke-RestMethod -Method Get -Uri "$GraphBase/copilot/agentRegistrations/$Id" -Headers $h
    } catch {
        return $null
    }
}

function Show-List {
    param([string]$Token)
    # Agent Registration API は List 非対応。既知の id を直接 GET して存在確認する。
    $orphanFull   = 'T_13d79b9c-1672-9bd3-9308-3f5fb9799f07'
    $orphanGuid   = '13d79b9c-1672-9bd3-9308-3f5fb9799f07'
    $keeperFull   = $KeeperRegistrationId
    $keeperGuid   = 'a1c916c0-53bb-e435-f167-d318842f0094'

    $targets = [ordered]@{
        "KEEPER  (T_ 形式)"   = $keeperFull
        "KEEPER  (GUID 形式)" = $keeperGuid
        "ORPHAN  (T_ 形式)"   = $orphanFull
        "ORPHAN  (GUID 形式)" = $orphanGuid
    }

    Write-Host ""
    Write-Host "===== agentRegistration 存在確認 =====" -ForegroundColor Green
    foreach ($label in $targets.Keys) {
        $id = $targets[$label]
        $reg = Get-OneRegistration -Token $Token -Id $id
        if ($reg) {
            Write-Host ""
            Write-Host "  [$label] 見つかりました" -ForegroundColor Cyan
            Write-Host "    id          : $($reg.id)"
            Write-Host "    displayName : $($reg.displayName)"
            Write-Host "    (削除用 id にこの値を使う)" -ForegroundColor DarkGray
        } else {
            Write-Host "  [$label] なし ($id)" -ForegroundColor DarkGray
        }
    }
    Write-Host ""
    Write-Host "孤児を削除:  pwsh -File .\delete-orphan-agent.ps1 -Delete <見つかった ORPHAN の id>" -ForegroundColor Yellow
}

function Remove-Registration {
    param([string]$Id, [string]$Token)
    if ($Id -eq $KeeperRegistrationId) {
        throw "この id は KEEPER(現役: $KeeperRegistrationId)です。削除を中止しました。"
    }
    $h = @{ Authorization = "Bearer $Token" }
    # 削除前に対象を表示
    try {
        $info = Invoke-RestMethod -Method Get -Uri "$GraphBase/copilot/agentRegistrations/$Id" -Headers $h
        Write-Host ""
        Write-Host "削除対象:" -ForegroundColor Yellow
        Write-Host "  id          : $($info.id)"
        Write-Host "  displayName : $($info.displayName)"
        Write-Host ""
    } catch {
        Write-Host "GET で詳細取得できませんでしたが、DELETE を試行します ($Id)。" -ForegroundColor DarkGray
    }

    $ans = Read-Host "本当に削除しますか? (yes と入力)"
    if ($ans -ne 'yes') { Write-Host "中止しました。"; return }

    Invoke-RestMethod -Method Delete -Uri "$GraphBase/copilot/agentRegistrations/$Id" -Headers $h | Out-Null
    Write-Host "削除しました: $Id" -ForegroundColor Green
}

# ---- main ----
$tenant = Get-TenantId
$token  = Get-GraphToken -TenantId $tenant

if ($Delete) {
    Remove-Registration -Id $Delete -Token $token
}
else {
    Show-List -Token $token
}
