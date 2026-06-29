# Agent 365 Blueprint 管理者同意（一括付与）

`a365 setup all`（Blueprint 型）実行後に残る **「Blueprint Permission Grants: PENDING」** を、
受講者全員分まとめて付与するための手順とスクリプト。

- スクリプト: [Grant-A365BlueprintConsent.ps1](./Grant-A365BlueprintConsent.ps1)

---

## 1. 背景：なぜ「PENDING」が残るのか

`a365 setup all --agent-name custom-maf-agent-a365-userNN` を **Agent ID Developer** 権限で実行すると、
Blueprint / Agent Identity / Azure インフラは作られるが、**管理者同意だけは未付与**で終了する。

CLI の出力（Setup Summary）:

```
  4. Blueprint Permission Grants  PENDING

Action Required:
  1. Permission Grants - forward the following to Global Administrator:
     Consent URL: https://login.microsoftonline.com/<tenant>/v2.0/adminconsent?client_id=<Blueprint>&scope=...
  2. Observability API S2S app role (PowerShell):
     New-MgServicePrincipalAppRoleAssignment ...
```

つまり残作業は次の **2 種類**：

| # | 種別 | 内容 |
|---|------|------|
| 1 | 委任同意（テナント全体） | Graph / Agent Tools / Observability / Power Platform の委任スコープへの管理者同意 |
| 2 | アプリロール（S2S） | Observability `Agent365.Observability.OtelWrite` のアプリロール割り当て |

---

## 2. なぜ「承認待ちキュー」や「同意ボタン」では解決しないか

| 想定ルート | 結果 |
|------------|------|
| M365 admin center > Agents > **Requests**（承認キュー） | **空**。Blueprint 型は Registry に自動登録される方式で、ストア公開申請（Publish to store）を伴わないため Requests に出ない |
| Entra > Enterprise applications で SP を開いて Grant admin consent | Agent ID SP は **Enterprise apps 一覧から除外**されており到達できない |
| Entra > Agents > Agent identities / blueprints > **Granted permissions** | **Preview の閲覧専用**。Grant ボタンが無い（付与済みの権限を見るだけ） |
| CLI が出す adminconsent URL を管理者に配布 | 受講者ごとに URL が異なり、**12 人運用では非現実的**。CA/マネージド ブラウザでブロックされる場合もある |

→ **ポータル UI に同意ボタンは存在しない**。`a365` CLI 自身が Action Required #2 を
Graph PowerShell スニペットで示している通り、**supported な非 URL 経路は Microsoft Graph 直接付与**。

---

## 3. 解決策：Graph で一括同意（Global Admin が 1 回実行）

委任スコープは **全受講者で完全に一定**で、変わるのは Blueprint appId だけ。
よって命名規約 `custom-maf-agent-a365-*Blueprint` で対象を自動列挙し、

- 委任同意 → `oauth2PermissionGrant`（`consentType=AllPrincipals` = テナント全体） … adminconsent URL の等価物
- OtelWrite → `appRoleAssignment` … CLI Action Required #2 の等価物

を **冪等**に一括付与する。URL 配布ゼロ、管理者の 1 実行で完結。

### 付与されるスコープ一覧

| リソース | 種別 | スコープ / ロール |
|----------|------|-------------------|
| Microsoft Graph | 委任 | `Mail.ReadWrite` `Mail.Send` `Chat.ReadWrite` `User.Read.All` `Sites.Read.All` `Files.ReadWrite.All` `ChannelMessage.Read.All` `ChannelMessage.Send` |
| Agent 365 Tools (`agent365.svc.cloud.microsoft`) | 委任 | `McpServersMetadata.Read.All` |
| Observability (`9b975845-…`) | 委任 | `Agent365.Observability.OtelWrite` |
| Power Platform (`api.powerplatform.com`) | 委任 | `Connectivity.Connections.Read` |
| Observability (`9b975845-…`) | アプリロール (S2S) | `Agent365.Observability.OtelWrite` |

---

## 4. 実行手順

> 要ロール: **Global Administrator**（`User.Read.All` 等 `*.All` 委任同意のため）
> 要モジュール: `Microsoft.Graph.Authentication`, `Microsoft.Graph.Applications`

```powershell
cd C:\GitHub\Agent365-Onboarding\lab準備

# 1) 対象 Blueprint だけ確認（付与しない）
.\Grant-A365BlueprintConsent.ps1 -WhatIfOnly

# 2) 問題なければ一括付与
.\Grant-A365BlueprintConsent.ps1
```

初回は **Microsoft Graph Command Line Tools アプリへのサインイン同意**画面が出る。
要求権限（Read applications / Manage app permission grants / Manage all delegated permission grants /
Read directory data）はスクリプトの `-Scopes` に対応。**「承諾」**を押す
（「組織の代理として同意する」は任意。チェックすると以後プロンプトが出ない）。

### パラメーター

| パラメーター | 既定値 | 用途 |
|--------------|--------|------|
| `-TenantId` | `<TENANT_ID>` | 対象テナント |
| `-BlueprintNameLike` | `custom-maf-agent-a365-*Blueprint` | 対象 Blueprint の displayName パターン |
| `-WhatIfOnly` | （なし） | 対象一覧のみ表示し付与しない |

成功時の出力例:

```
=== custom-maf-agent-a365-user99 Blueprint  (appId=75744116-…) ===
  付与: Microsoft Graph <- Mail.ReadWrite Mail.Send Chat.ReadWrite User.Read.All Sites.Read.All Files.ReadWrite.All ChannelMessage.Read.All ChannelMessage.Send
  付与: Agent Tools <- McpServersMetadata.Read.All
  付与: Agent365Observability <- Agent365.Observability.OtelWrite
  付与: Power Platform API <- Connectivity.Connections.Read
  付与: OtelWrite app role
完了: 全 Blueprint へ委任同意 + OtelWrite を一括付与しました。
```

---

## 5. 付与確認

### A. Graph で確認（同じセッションで実行）

```powershell
$bp = $allSp | Where-Object { $_.DisplayName -like 'custom-maf-agent-a365-*Blueprint' }

foreach ($b in $bp) {
  Write-Host "`n=== $($b.DisplayName) ==="

  Write-Host "--- 委任同意 (oauth2PermissionGrant / AllPrincipals) ---"
  Get-MgOauth2PermissionGrant -Filter "clientId eq '$($b.Id)'" |
    ForEach-Object {
      $r = $allSp | Where-Object Id -eq $_.ResourceId
      [pscustomobject]@{ Resource = $r.DisplayName; ConsentType = $_.ConsentType; Scope = $_.Scope }
    } | Format-Table -AutoSize -Wrap

  Write-Host "--- アプリロール (appRoleAssignment) ---"
  Get-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $b.Id |
    ForEach-Object {
      $r = $allSp | Where-Object Id -eq $_.ResourceId
      $role = ($r.AppRoles | Where-Object Id -eq $_.AppRoleId).Value
      [pscustomobject]@{ Resource = $r.DisplayName; Role = $role }
    } | Format-Table -AutoSize
}
```

期待結果:
- 委任同意 **4 行**（Microsoft Graph / Agent Tools / Agent365Observability / Power Platform API）すべて `ConsentType = AllPrincipals`
- アプリロール **1 行**（Agent365Observability / `Agent365.Observability.OtelWrite`）

### B. ポータルで確認

**Entra > Agents > Agent identities > `custom-maf-agent-a365-userNN` Blueprint > Granted permissions (Preview) > 管理者の同意**

→ 付与前は `AgentIdentity.CreateAsManagedIdentity` の 1 件のみ。
付与後は Mail.ReadWrite / Chat.ReadWrite / OtelWrite など今回付与した権限が並ぶ
（反映に数十秒。「最新の情報に更新」を押す）。

---

## 6. 補足

- **冪等**: 再実行しても重複作成せず、既存は更新／スキップ。
- **受講者の増減**: 命名規約に従っていれば、同じスクリプトで自動的に全員分を処理。
  別命名のラボでは `-BlueprintNameLike` で上書き。
- **同意の対象は Identity ではなく Blueprint**: Agent Identity（インスタンス）は
  親 Blueprint の権限を継承するため、Blueprint に 1 回同意すれば全インスタンスに効く。
