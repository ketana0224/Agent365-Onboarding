<#
.SYNOPSIS
  Agent 365 Blueprint の保留中の管理者同意（Blueprint Permission Grants: PENDING）を
  全受講者分まとめて付与する。a365 setup all が出力する個別の adminconsent URL を
  管理者に配布せず、Global Administrator が 1 回実行するだけで完結する。

.DESCRIPTION
  a365 setup all（Blueprint 型）は「委任スコープの管理者同意」と
  「Observability S2S アプリロール(OtelWrite)」を未付与のまま終了する。
  本スクリプトはその 2 つを Microsoft Graph PowerShell で一括付与する：
    1) 委任同意（consentType=AllPrincipals = テナント全体） … adminconsent URL の等価物
    2) Observability OtelWrite app role assignment           … CLI 出力 #2 の等価物

  スコープは全受講者で一定。変わるのは Blueprint appId だけなので、
  命名規約 'custom-maf-agent-a365-*Blueprint' で対象を自動列挙する。
  冪等（再実行で重複作成せず更新/スキップ）。

.NOTES
  要ロール: Global Administrator（User.Read.All 等 *.All 委任同意のため）
  要モジュール: Microsoft.Graph.Authentication, Microsoft.Graph.Applications
#>

param(
  [string]$TenantId = '655bd66a-5001-4cb3-9aad-ce54a27d5d95',
  # 対象 Blueprint を絞り込む displayName パターン（既定は本ラボの命名規約）
  [string]$BlueprintNameLike = 'custom-maf-agent-a365-*Blueprint',
  # 付与せず対象と操作内容のみ表示する
  [switch]$WhatIfOnly
)

$ErrorActionPreference = 'Stop'

# ── 全受講者で共通の委任スコープ（a365 setup all の scope= をリソース別に分解）──
$grants = @(
  @{ Resource = '00000003-0000-0000-c000-000000000000'; Scope = 'Mail.ReadWrite Mail.Send Chat.ReadWrite User.Read.All Sites.Read.All Files.ReadWrite.All ChannelMessage.Read.All ChannelMessage.Send' }
  @{ Resource = 'https://agent365.svc.cloud.microsoft';  Scope = 'McpServersMetadata.Read.All' }
  @{ Resource = '9b975845-388f-4429-889e-eab1ef63949c';  Scope = 'Agent365.Observability.OtelWrite' }
  @{ Resource = 'https://api.powerplatform.com';         Scope = 'Connectivity.Connections.Read' }
)
$obsAppId   = '9b975845-388f-4429-889e-eab1ef63949c'
$obsRoleVal = 'Agent365.Observability.OtelWrite'

Connect-MgGraph -TenantId $TenantId `
  -Scopes 'Application.Read.All','DelegatedPermissionGrant.ReadWrite.All','AppRoleAssignment.ReadWrite.All','Directory.Read.All'

# リソース SP を一度だけ解決（appId 一致 or servicePrincipalNames 一致）
Write-Host 'サービス プリンシパルを取得中...'
$allSp = Get-MgServicePrincipal -All -Property Id,AppId,DisplayName,ServicePrincipalNames,AppRoles
function Resolve-Sp([string]$key) {
  $allSp | Where-Object { $_.AppId -eq $key -or $_.ServicePrincipalNames -contains $key } | Select-Object -First 1
}

# 対象 Blueprint を列挙（命名規約で抽出）
$blueprints = $allSp | Where-Object { $_.DisplayName -like $BlueprintNameLike }
Write-Host "対象 Blueprint: $($blueprints.Count) 件 (pattern: $BlueprintNameLike)"
if ($blueprints.Count -eq 0) { Write-Warning '対象 Blueprint が見つかりません。-BlueprintNameLike を確認してください。'; return }
$blueprints | ForEach-Object { Write-Host "  - $($_.DisplayName)  (appId=$($_.AppId))" }

if ($WhatIfOnly) { Write-Host "`n[WhatIfOnly] 付与は実行しません。" -ForegroundColor Yellow; return }

$obs    = Resolve-Sp $obsAppId
$obsRid = ($obs.AppRoles | Where-Object { $_.Value -eq $obsRoleVal }).Id

foreach ($bp in $blueprints) {
  Write-Host "`n=== $($bp.DisplayName)  (appId=$($bp.AppId)) ==="

  # 1) 委任同意（テナント全体）= adminconsent URL の等価物
  foreach ($g in $grants) {
    $res = Resolve-Sp $g.Resource
    if (-not $res) { Write-Warning "  リソース未解決: $($g.Resource)"; continue }
    try {
      $existing = Get-MgOauth2PermissionGrant -Filter "clientId eq '$($bp.Id)' and resourceId eq '$($res.Id)'" -ErrorAction SilentlyContinue
      if ($existing) {
        Update-MgOauth2PermissionGrant -OAuth2PermissionGrantId $existing.Id -Scope $g.Scope
        Write-Host "  更新: $($res.DisplayName) <- $($g.Scope)"
      } else {
        New-MgOauth2PermissionGrant -ClientId $bp.Id -ConsentType 'AllPrincipals' -ResourceId $res.Id -Scope $g.Scope | Out-Null
        Write-Host "  付与: $($res.DisplayName) <- $($g.Scope)"
      }
    } catch {
      Write-Warning "  委任同意失敗 ($($res.DisplayName)): $($_.Exception.Message)"
    }
  }

  # 2) Observability S2S アプリロール（OtelWrite）= CLI 出力 #2 の等価物
  try {
    $hasRole = Get-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $bp.Id -ErrorAction SilentlyContinue |
               Where-Object { $_.AppRoleId -eq $obsRid -and $_.ResourceId -eq $obs.Id }
    if ($hasRole) {
      Write-Host '  既存: OtelWrite app role'
    } else {
      New-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $bp.Id -PrincipalId $bp.Id -ResourceId $obs.Id -AppRoleId $obsRid | Out-Null
      Write-Host '  付与: OtelWrite app role'
    }
  } catch {
    Write-Warning "  OtelWrite 付与失敗: $($_.Exception.Message)"
  }
}

Write-Host "`n完了: 全 Blueprint へ委任同意 + OtelWrite を一括付与しました。" -ForegroundColor Green
