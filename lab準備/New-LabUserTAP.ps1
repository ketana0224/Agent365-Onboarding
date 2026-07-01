<#
.SYNOPSIS
  ラボ受講者ユーザー（user01..userNN）の一時アクセス パス（Temporary Access Pass: TAP）を
  Microsoft Graph でまとめて発行する。パスワードや MFA 未登録でも初回サインインできる
  使い捨て/時限クレデンシャルを、管理者が 1 回実行するだけで全受講者分そろえる。

.DESCRIPTION
  各ユーザーに対して以下を実行する（冪等）：
    1) 既存 TAP を取得し削除（TAP は 1 ユーザー 1 個までのため、再実行時は作り直し）
    2) 新しい TAP を発行（isUsableOnce / lifetimeInMinutes を指定）
  発行された TAP コードは「作成時のみ」平文で取得可能。結果はコンソール表とともに
  JSON ファイル（-OutFile）にも書き出す。

  UPN は "<Prefix><NN>@<Domain>" 形式で自動生成する（既定: user01..user12）。

.NOTES
  要ロール : Authentication Administrator もしくは Privileged Authentication Administrator
             （Global Administrator でも可）
  要スコープ: UserAuthenticationMethod.ReadWrite.All（Connect-MgGraph で同意）
  要モジュール: Microsoft.Graph.Authentication
  前提      : Entra ID > 認証方法 > Temporary Access Pass ポリシーで対象ユーザーが「有効」

  ※ az CLI の Graph トークン（az account get-access-token）は
     UserAuthenticationMethod.ReadWrite.All を含まないため 403 になる。必ず本スクリプトの
     Connect-MgGraph 経由で認証すること。
  ※ デバイス コード認証（-UseDeviceCode）は 120 秒無操作でタイムアウトし固まりやすい。
     既定はブラウザ/WAM 認証（アカウント キャッシュ済みなら無操作で通過）。

.EXAMPLE
  # user01..user12 に 8 時間有効・複数回利用可の TAP を発行
  ./New-LabUserTAP.ps1 -Domain "M365CPI65139919.onmicrosoft.com"

.EXAMPLE
  # user01..user20、1 時間有効・1 回のみ使用可の TAP を発行
  ./New-LabUserTAP.ps1 -Domain "contoso.onmicrosoft.com" -End 20 -LifetimeMinutes 60 -UsableOnce

.EXAMPLE
  # 発行せず対象 UPN のみ確認（ドライラン）
  ./New-LabUserTAP.ps1 -Domain "contoso.onmicrosoft.com" -WhatIfOnly
#>

param(
  [Parameter(Mandatory)]
  [string]$Domain,
  # ユーザー名プレフィックス（"user" -> user01, user02, ...）
  [string]$Prefix = 'user',
  # 連番の開始/終了
  [int]$Start = 1,
  [int]$End = 12,
  # 連番の桁数（2 -> 01, 3 -> 001）
  [int]$Pad = 2,
  # TAP の有効期間（分）。既定 480 分 = 8 時間。範囲 10..43200
  [int]$LifetimeMinutes = 480,
  # 指定すると 1 回のみ使用可能な TAP を発行（既定は期間内複数回利用可）
  [switch]$UsableOnce,
  # 結果 JSON の出力先
  [string]$OutFile = "$PSScriptRoot/tap-results.json",
  # デバイス コード認証を使う（GUI が無い環境向け。120 秒制限に注意）
  [switch]$UseDeviceCode,
  # 発行せず対象 UPN のみ表示する
  [switch]$WhatIfOnly
)

$ErrorActionPreference = 'Stop'
Import-Module Microsoft.Graph.Authentication -ErrorAction Stop

# ── 対象 UPN を生成 ─────────────────────────────────────────────
$fmt  = "{0}{1:D$Pad}@{2}"
$upns = $Start..$End | ForEach-Object { $fmt -f $Prefix, $_, $Domain }

Write-Host "対象ユーザー: $($upns.Count) 件"
$upns | ForEach-Object { Write-Host "  - $_" }

if ($WhatIfOnly) {
  Write-Host "`n[WhatIfOnly] TAP は発行しません。" -ForegroundColor Yellow
  return
}

# ── サインイン（必要スコープ）─────────────────────────────────
$connectArgs = @{ Scopes = 'UserAuthenticationMethod.ReadWrite.All'; NoWelcome = $true }
if ($UseDeviceCode) { $connectArgs['UseDeviceCode'] = $true }
Connect-MgGraph @connectArgs
Write-Host ("サインイン: " + (Get-MgContext).Account) -ForegroundColor Green

# ── TAP 発行本体 ───────────────────────────────────────────────
$bodyObj = @{ isUsableOnce = [bool]$UsableOnce; lifetimeInMinutes = $LifetimeMinutes }

$results = foreach ($upn in $upns) {
  $base = "https://graph.microsoft.com/v1.0/users/$upn/authentication/temporaryAccessPassMethods"
  try {
    # 既存 TAP（1 ユーザー 1 個まで）を削除してから発行
    $existing = Invoke-MgGraphRequest -Method GET -Uri $base
    foreach ($m in $existing.value) {
      Invoke-MgGraphRequest -Method DELETE -Uri "$base/$($m.id)" | Out-Null
    }
    $r = Invoke-MgGraphRequest -Method POST -Uri $base -Body $bodyObj
    [pscustomobject]@{
      UPN         = $upn
      TAP         = $r.temporaryAccessPass
      StartUTC    = $r.startDateTime
      LifetimeMin = $r.lifetimeInMinutes
      UsableOnce  = $r.isUsableOnce
    }
  } catch {
    $msg = $_.ErrorDetails.Message; if (-not $msg) { $msg = $_.Exception.Message }
    [pscustomobject]@{
      UPN = $upn; TAP = "ERROR: $msg"; StartUTC = ''; LifetimeMin = ''; UsableOnce = ''
    }
  }
}

# ── 出力 ───────────────────────────────────────────────────────
$results | ConvertTo-Json | Out-File -FilePath $OutFile -Encoding utf8
$results | Format-Table -AutoSize -Wrap

$ok  = ($results | Where-Object { $_.TAP -notlike 'ERROR:*' }).Count
$err = $results.Count - $ok
Write-Host "`n完了: 発行 $ok 件 / 失敗 $err 件。詳細は $OutFile" -ForegroundColor Green
Write-Host "注意: TAP コードは作成時のみ平文取得可能です。安全に配布し、$OutFile は使用後に削除してください。" -ForegroundColor Yellow
