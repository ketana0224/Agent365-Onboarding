<#
.SYNOPSIS
  Agent ID（SP）を実際にサインインさせて §7.2 の CA ブロックを検証するスクリプト。

.DESCRIPTION
  Agent 365 SDK のメッセージング ホストが内部でやっている fmi_path トークン交換を
  手で 1 回だけ再現し、Agent Identity（agenticAppId）として Microsoft Graph を呼ぶ。
  これにより Entra のサービス プリンシパル サインイン ログに当該 SP のサインインが記録される。

  - CA ポリシー（§7.1）を有効化する「前」に実行 → Graph 200・サインイン ログは Success（ベースライン）。
  - CA ポリシー（§7.1）を有効化した「後」に実行 → トークン交換が AADSTS53003 等で失敗し、
    サインイン ログに Conditional Access = Failure / Blocked が記録される（= §7.2 のブロック実証）。

  Teams 往復・SDK メッセージング ホストの実装は不要。

.NOTES
  - 設定値は a365.config.json / a365.generated.config.json から読む。
  - Blueprint シークレットは DPAPI(CurrentUser) で暗号化保存されているため、
    a365 setup を実行したのと同じ Windows ユーザーでのみ復号できる。
  - シークレット / トークンの中身は一切表示しない。
  - 前提: User.Read.All のアプリ権限が当該 Agent Identity に付与済み（a365 setup all で付与済み）。
#>
[CmdletBinding()]
param(
    [string]$ConfigDir = $PSScriptRoot
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Security

# --- 設定読み込み ---------------------------------------------------------
$cfg     = Get-Content (Join-Path $ConfigDir 'a365.config.json')           -Raw | ConvertFrom-Json
$gen     = Get-Content (Join-Path $ConfigDir 'a365.generated.config.json') -Raw | ConvertFrom-Json

$TenantId          = $cfg.tenantId
$BlueprintAppId    = $gen.agentBlueprintId      # 例: e65ce763-...  ← Step1 の client_id（シークレット保持）
$AgentIdentityAppId = $gen.agenticAppId         # 例: 9ff24e53-...  ← fmi_path / Step2 の client_id（CA 対象）

Write-Host "TenantId            : $TenantId"
Write-Host "Blueprint appId     : $BlueprintAppId"
Write-Host "Agent Identity appId: $AgentIdentityAppId  (CA でブロックする対象)"
Write-Host ""

# --- Blueprint シークレット復号（DPAPI / CurrentUser）---------------------
if (-not $gen.agentBlueprintClientSecretProtected) {
    throw "agentBlueprintClientSecretProtected が true ではありません。想定外の保存形式です。"
}
$protected   = [Convert]::FromBase64String($gen.agentBlueprintClientSecret)
$secretBytes = [System.Security.Cryptography.ProtectedData]::Unprotect(
    $protected, $null, [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
$secret      = [System.Text.Encoding]::UTF8.GetString($secretBytes)

$tokenUrl = "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token"

# --- Step 1: 親トークン（Blueprint 資格情報 + fmi_path）-------------------
Write-Host "[Step 1] 親トークン取得（fmi_path = Agent Identity）..." -ForegroundColor Cyan
$body1 = @{
    grant_type    = 'client_credentials'
    client_id     = $BlueprintAppId
    client_secret = $secret
    scope         = 'api://AzureADTokenExchange/.default'
    fmi_path      = $AgentIdentityAppId
}
$parent = Invoke-RestMethod -Method Post -Uri $tokenUrl -Body $body1 -ContentType 'application/x-www-form-urlencoded'
$parentToken = $parent.access_token
Write-Host "  -> 親トークン取得 OK（中身は非表示）" -ForegroundColor Green

# --- Step 2: Agent Identity として Graph トークン取得（ここが CA 対象）----
Write-Host "[Step 2] Agent Identity として Graph トークン取得..." -ForegroundColor Cyan
$body2 = @{
    grant_type            = 'client_credentials'
    client_id             = $AgentIdentityAppId
    client_assertion_type = 'urn:ietf:params:oauth:client-assertion-type:jwt-bearer'
    client_assertion      = $parentToken
    scope                 = 'https://graph.microsoft.com/.default'
}

try {
    $graphTok = Invoke-RestMethod -Method Post -Uri $tokenUrl -Body $body2 -ContentType 'application/x-www-form-urlencoded'
    # ここに到達した = Agent Identity の SP サインインが成功し、サインイン ログに Success で記録された。
    # CA(§7.1) が有効なら、この Step 2 が AADSTS53003 で失敗する（下の catch に入る）。
    Write-Host "  -> Graph トークン取得 OK（= Agent Identity のサインイン成功・中身は非表示）" -ForegroundColor Green
}
catch {
    $resp = $_.Exception.Response
    $detail = ''
    if ($resp) {
        $reader = New-Object System.IO.StreamReader($resp.GetResponseStream())
        $detail = $reader.ReadToEnd()
    }
    Write-Host ""
    Write-Host "================ トークン発行が拒否された ================" -ForegroundColor Yellow
    if ($detail -match 'AADSTS53003') {
        Write-Host "AADSTS53003: 条件付きアクセスによりブロックされました（= §7.2 のブロック実証）。" -ForegroundColor Yellow
    } else {
        Write-Host "エラー応答（error/description のみ）:" -ForegroundColor Yellow
        try {
            $j = $detail | ConvertFrom-Json
            Write-Host ("  error             : {0}" -f $j.error)
            Write-Host ("  error_description : {0}" -f ($j.error_description -split "`r?`n")[0])
        } catch { Write-Host "  $detail" }
    }
    Write-Host "Entra → 監視 > サインイン ログ > サービス プリンシパルのサインイン で" -ForegroundColor Yellow
    Write-Host "  appId $AgentIdentityAppId の Conditional Access = Failure を確認してください。" -ForegroundColor Yellow
    exit 2
}

# --- Step 3: Graph を実際に呼ぶ（任意・ベストエフォート）-------------------
# 注意: §7.2 の検証本体は「Step 2 のトークン発行が成功/ブロックされるか」。
#       下の Graph データ呼び出しは付録で、権限不足(403)でもサインイン自体は成立している。
Write-Host "[Step 3] Graph /users を 1 件呼び出し（任意・付録）..." -ForegroundColor Cyan
try {
    $g = Invoke-RestMethod -Method Get `
        -Uri 'https://graph.microsoft.com/v1.0/users?$top=1&$select=displayName' `
        -Headers @{ Authorization = "Bearer $($graphTok.access_token)" }
    Write-Host "  -> Graph 応答 OK（取得件数: $($g.value.Count)）" -ForegroundColor Green
}
catch {
    Write-Host "  -> Graph データ呼び出しは権限不足等で失敗（サインインは Step 2 で成立済みなので検証には影響なし）" -ForegroundColor DarkYellow
}

Write-Host ""
Write-Host "ベースライン成功。Entra → 監視 > サインイン ログ > サービス プリンシパルのサインインで" -ForegroundColor Green
Write-Host "  appId $AgentIdentityAppId の Success サインインを確認できます。" -ForegroundColor Green
Write-Host "次に §7.1 の CA ポリシーを有効化し、本スクリプトを再実行するとブロックを実証できます。" -ForegroundColor Green
