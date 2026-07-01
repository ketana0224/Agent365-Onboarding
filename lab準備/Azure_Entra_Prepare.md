# C:\GitHub\Agent365-Onboarding\_report\Handsonを実習する環境を作る

# 対象の環境情報
- **対象テナント**: `<TENANT_ID>`
- **対象サブスクリプション**: `<SUBSCRIPTION_NAME>` 

# 0.共通設定（最初に1回だけ実行）
- 以降のセクション（1〜7）は、ここで設定した環境変数（`$tenantId` / `$subscription` / `$subId` / `$domain` / `$h` / `$aiRg` / `$aiName` など）を共有して使う。
- Graph トークン `$token` / `$h` は約1時間で失効する。4〜7 を実行する前に失効していたら、このブロックを再実行してから進む。

```powershell
# ===== 環境変数（適宜書き換え）=====
$tenantId     = "<TENANT_ID>"
$subscription = "<SUBSCRIPTION_NAME>"
$location     = "eastus2"

# 共有 App Insights（lab6 / APIM と同一の集約先）
$aiRg   = "<APPINSIGHTS_RESOURCE_GROUP>"
$aiName = "<APPINSIGHTS_NAME>"

# ===== サブスクリプション選択 =====
az account set --subscription $subscription
$subId = az account show --subscription $subscription --query id -o tsv

# ===== Graph トークン（az rest は $ を含む Graph URI で壊れるため Invoke-RestMethod を使用）=====
$token = az account get-access-token --resource https://graph.microsoft.com --query accessToken -o tsv
$h = @{ Authorization = "Bearer $token"; "Content-Type" = "application/json" }

# ===== 初期ドメイン (xxxx.onmicrosoft.com) を自動取得 =====
$domain = (Invoke-RestMethod -Method Get -Headers $h `
    -Uri "https://graph.microsoft.com/v1.0/domains").value |
    Where-Object isInitial | Select-Object -ExpandProperty id
Write-Host "利用ドメイン: $domain"
```

# 1.受講者ユーザを作る
- user01～user12 の12ユーザー

```powershell
# 初期パスワード (受講者には初回サインインで変更させる)
$initialPassword = "Handson@$(Get-Random -Minimum 100000 -Maximum 999999)"
Write-Host "初期パスワード: $initialPassword  (12ユーザー共通・控えておくこと)"

# === user01〜user12 を作成 ===
1..12 | ForEach-Object {
    $n   = "user{0:D2}" -f $_       # user01, user02, ...
    $upn = "$n@$domain"

    # 既存チェック
    $exists = az ad user list --filter "userPrincipalName eq '$upn'" --query "[0].id" -o tsv
    if ($exists) {
        Write-Host "スキップ (既存): $upn"
        return
    }

    az ad user create `
        --display-name $n `
        --user-principal-name $upn `
        --password $initialPassword `
        --force-change-password-next-sign-in true `
        --output none

    if ($LASTEXITCODE -eq 0) { Write-Host "作成: $upn" }
    else { Write-Warning "作成失敗: $upn" }
}
```

# 2.受講者毎にリソースグループを作る
- rg-user01～rg-user12 の12のリソースグループ

```powershell
# === rg-user01〜rg-user12 を作成 ===
1..12 | ForEach-Object {
    $n  = "user{0:D2}" -f $_
    $rg = "rg-$n"               # rg-user01, rg-user02, ...

    az group create `
        --name $rg `
        --location $location `
        --tags purpose=handson owner=$n `
        --output none

    if ($LASTEXITCODE -eq 0) { Write-Host "作成: $rg" }
    else { Write-Warning "作成失敗: $rg" }
}
```

# 3.Azure Portalからアクセスできる権限を付与する
- リソースグループに対する全ての権限

```powershell
# 付与するロール: リソースグループに対する全権限 = Owner
# (権限の委任まで不要なら "Contributor" に変更可)
$role = "Owner"

# === 各ユーザーに対応する rg-userNN への権限を付与 ===
1..12 | ForEach-Object {
    $n   = "user{0:D2}" -f $_
    $rg  = "rg-$n"
    $upn = "$n@$domain"

    $objectId = az ad user show --id $upn --query id -o tsv
    if (-not $objectId) {
        Write-Warning "ユーザー未検出のためスキップ: $upn"
        return
    }

    $scope = "/subscriptions/$subId/resourceGroups/$rg"

    az role assignment create `
        --assignee-object-id $objectId `
        --assignee-principal-type User `
        --role "$role" `
        --scope "$scope" `
        --output none

    if ($LASTEXITCODE -eq 0) { Write-Host "付与: $upn -> $rg ($role)" }
    else { Write-Warning "付与失敗: $upn -> $rg" }
}
```

# 4.a365 setup allが実行できるようにする
-必要な権限は Agent ID Developer

```powershell
# "Agent ID Developer (エージェント ID 開発者)" ロール定義の ID を取得
# 注意: roleDefinitions は $top / $filter(displayName) が不安定なため、
#       クエリ無しで全件取得(@odata.nextLink でページング)し、部分一致で特定する
$roleName = "Agent ID Developer"
$roles = @()
$uri = "https://graph.microsoft.com/v1.0/roleManagement/directory/roleDefinitions"
do {
    $resp  = Invoke-RestMethod -Method Get -Headers $h -Uri $uri
    $roles += $resp.value
    $uri    = $resp.'@odata.nextLink'
} while ($uri)

$roleDef = $roles | Where-Object {
    $_.displayName -like "*Agent ID Developer*" -or $_.displayName -like "*エージェント ID 開発者*"
} | Select-Object -First 1
if (-not $roleDef) { throw "ロール '$roleName' が見つかりません。テナントで利用可能か確認してください。" }
$roleDefId = $roleDef.id
Write-Host "ロール: $($roleDef.displayName)  ID: $roleDefId"

# 既存のロール割り当てを取得 (重複付与回避用)
$existing = (Invoke-RestMethod -Method Get -Headers $h `
    -Uri "https://graph.microsoft.com/v1.0/roleManagement/directory/roleAssignments?`$filter=roleDefinitionId eq '$roleDefId'").value
$assignedPrincipals = $existing.principalId

# === user01〜user12 に Agent ID Developer を付与 ===
1..12 | ForEach-Object {
    $n   = "user{0:D2}" -f $_
    $upn = "$n@$domain"

    $objectId = az ad user show --id $upn --query id -o tsv
    if (-not $objectId) {
        Write-Warning "ユーザー未検出のためスキップ: $upn"
        return
    }

    if ($assignedPrincipals -contains $objectId) {
        Write-Host "スキップ (既存): $upn"
        return
    }

    $body = @{
        "@odata.type"      = "#microsoft.graph.unifiedRoleAssignment"
        roleDefinitionId   = $roleDefId
        principalId        = $objectId
        directoryScopeId   = "/"
    } | ConvertTo-Json

    try {
        Invoke-RestMethod -Method Post -Headers $h `
            -Uri "https://graph.microsoft.com/v1.0/roleManagement/directory/roleAssignments" `
            -Body $body | Out-Null
        Write-Host "付与: $upn ($roleName)"
    } catch {
        Write-Warning "付与失敗: $upn -> $($_.Exception.Message)"
    }
}
```

# 5.Agent 365 でエージェントを管理できるようにする
- 必要な権限は **AI Administrator（AI 管理者）**
- Agent 365 管理センターでのエージェント管理（Block / Unblock 等）や AI 関連機能の管理に必要。
- 組み込みロール定義 ID は固定で `d2562ede-74db-457e-a7b6-544e236ebb61`。名前検索が不安定な場合はこの ID を直接使ってもよい。

```powershell
# "AI Administrator (AI 管理者)" ロール定義の ID を取得
# 注意: roleDefinitions は $top / $filter(displayName) が不安定なため、
#       クエリ無しで全件取得(@odata.nextLink でページング)し、部分一致で特定する
$roleName = "AI Administrator"
$roles = @()
$uri = "https://graph.microsoft.com/v1.0/roleManagement/directory/roleDefinitions"
do {
    $resp  = Invoke-RestMethod -Method Get -Headers $h -Uri $uri
    $roles += $resp.value
    $uri    = $resp.'@odata.nextLink'
} while ($uri)

$roleDef = $roles | Where-Object {
    $_.displayName -like "*AI Administrator*" -or $_.displayName -like "*AI 管理者*"
} | Select-Object -First 1
if (-not $roleDef) { throw "ロール '$roleName' が見つかりません。テナントで利用可能か確認してください。" }
$roleDefId = $roleDef.id
Write-Host "ロール: $($roleDef.displayName)  ID: $roleDefId"

# 既存のロール割り当てを取得 (重複付与回避用)
$existing = (Invoke-RestMethod -Method Get -Headers $h `
    -Uri "https://graph.microsoft.com/v1.0/roleManagement/directory/roleAssignments?`$filter=roleDefinitionId eq '$roleDefId'").value
$assignedPrincipals = $existing.principalId

# === user01〜user12 に AI Administrator を付与 ===
1..12 | ForEach-Object {
    $n   = "user{0:D2}" -f $_
    $upn = "$n@$domain"

    $objectId = az ad user show --id $upn --query id -o tsv
    if (-not $objectId) {
        Write-Warning "ユーザー未検出のためスキップ: $upn"
        return
    }

    if ($assignedPrincipals -contains $objectId) {
        Write-Host "スキップ (既存): $upn"
        return
    }

    $body = @{
        "@odata.type"      = "#microsoft.graph.unifiedRoleAssignment"
        roleDefinitionId   = $roleDefId
        principalId        = $objectId
        directoryScopeId   = "/"
    } | ConvertTo-Json

    try {
        Invoke-RestMethod -Method Post -Headers $h `
            -Uri "https://graph.microsoft.com/v1.0/roleManagement/directory/roleAssignments" `
            -Body $body | Out-Null
        Write-Host "付与: $upn ($roleName)"
    } catch {
        Write-Warning "付与失敗: $upn -> $($_.Exception.Message)"
    }
}
```

# 6.OBO の管理者同意（lab5）が実行できるようにする
- 必要な権限は **Cloud Application Administrator（クラウド アプリケーション管理者）**
- lab5 の `03_grant-agentid-graph-delegated.ps1` が Agent Identity SP に Graph 委任権限の `oauth2PermissionGrants`（テナント同意相当）を作成するために必要。これが無いと `Authorization_RequestDenied / Insufficient privileges` で失敗する。

```powershell
# "Cloud Application Administrator (クラウド アプリケーション管理者)" ロール定義の ID を取得
# 注意: roleDefinitions は $top / $filter(displayName) が不安定なため、
#       クエリ無しで全件取得(@odata.nextLink でページング)し、部分一致で特定する
$roleName = "Cloud Application Administrator"
$roles = @()
$uri = "https://graph.microsoft.com/v1.0/roleManagement/directory/roleDefinitions"
do {
    $resp  = Invoke-RestMethod -Method Get -Headers $h -Uri $uri
    $roles += $resp.value
    $uri    = $resp.'@odata.nextLink'
} while ($uri)

$roleDef = $roles | Where-Object {
    $_.displayName -like "*Cloud Application Administrator*" -or $_.displayName -like "*クラウド アプリケーション管理者*"
} | Select-Object -First 1
if (-not $roleDef) { throw "ロール '$roleName' が見つかりません。テナントで利用可能か確認してください。" }
$roleDefId = $roleDef.id
Write-Host "ロール: $($roleDef.displayName)  ID: $roleDefId"

# 既存のロール割り当てを取得 (重複付与回避用)
$existing = (Invoke-RestMethod -Method Get -Headers $h `
    -Uri "https://graph.microsoft.com/v1.0/roleManagement/directory/roleAssignments?`$filter=roleDefinitionId eq '$roleDefId'").value
$assignedPrincipals = $existing.principalId

# === user01〜user12 に Cloud Application Administrator を付与 ===
1..12 | ForEach-Object {
    $n   = "user{0:D2}" -f $_
    $upn = "$n@$domain"

    $objectId = az ad user show --id $upn --query id -o tsv
    if (-not $objectId) {
        Write-Warning "ユーザー未検出のためスキップ: $upn"
        return
    }

    if ($assignedPrincipals -contains $objectId) {
        Write-Host "スキップ (既存): $upn"
        return
    }

    $body = @{
        "@odata.type"      = "#microsoft.graph.unifiedRoleAssignment"
        roleDefinitionId   = $roleDefId
        principalId        = $objectId
        directoryScopeId   = "/"
    } | ConvertTo-Json

    try {
        Invoke-RestMethod -Method Post -Headers $h `
            -Uri "https://graph.microsoft.com/v1.0/roleManagement/directory/roleAssignments" `
            -Body $body | Out-Null
        Write-Host "付与: $upn ($roleName)"
    } catch {
        Write-Warning "付与失敗: $upn -> $($_.Exception.Message)"
    }
}
```

# 7.共有 App Insights の接続文字列を取得できるようにする（lab6）
- lab6 のエージェントは APIM と**同一の共有 App Insights `<APPINSIGHTS_NAME>`（`<APPINSIGHTS_RESOURCE_GROUP>`）**へテレメトリを集約し、E2E トレースを成立させる。
- lab6 の `scripts\00_generate-env.ps1` は、この共有 App Insights の接続文字列を `az` で自動取得して `.env` に焼き込む。**受講者ユーザーは共有 RG に権限が無いため取得に失敗する**ので、その App Insights リソース 1 個だけにスコープして権限を付与する。
- 付与するロールは 2 つ（いずれも App Insights リソース スコープ）:
  - **Reader（閲覧者）** … 接続文字列の取得（`Microsoft.Insights/components/read`）に必要。
  - **Monitoring Reader（監視閲覧者）** … lab6 §4.3 で **App Insights の Logs / トランザクション検索**を開いてトレースを見るために付与。共有 App Insights は**ワークスペース ベース**（`log-*` に格納）なので、Reader だけだと経路によっては Logs クエリが弾かれる。SP 側も Monitoring Reader を持っており、それに揃える。
- RG 全体ではなくリソース単位に絞った最小権限。

```powershell
# App Insights リソースID（このリソースだけにスコープ）
$aiId = az resource list -g $aiRg -n $aiName `
    --resource-type "Microsoft.Insights/components" --query "[0].id" -o tsv
if (-not $aiId) { throw "App Insights '$aiName' が $aiRg に見つかりません。" }
Write-Host "対象 App Insights: $aiId"

# === user01〜user12 に Reader + Monitoring Reader（リソース スコープ）を付与 ===
$obsRoles = @("Reader", "Monitoring Reader")
1..12 | ForEach-Object {
    $n   = "user{0:D2}" -f $_
    $upn = "$n@$domain"

    $objectId = az ad user show --id $upn --query id -o tsv
    if (-not $objectId) {
        Write-Warning "ユーザー未検出のためスキップ: $upn"
        return
    }

    foreach ($role in $obsRoles) {
        az role assignment create `
            --assignee-object-id $objectId `
            --assignee-principal-type User `
            --role "$role" `
            --scope "$aiId" `
            --output none

        if ($LASTEXITCODE -eq 0) { Write-Host "付与: $upn -> $aiName ($role)" }
        else { Write-Warning "付与失敗: $upn -> $aiName ($role)" }
    }
}
```

> 付与後、受講者側は lab6 で `pwsh .\scripts\00_generate-env.ps1 -Force` を再実行すれば、`APPLICATIONINSIGHTS_CONNECTION_STRING` が自動で `.env` に焼き込まれる。
>
> 権限を渡さない運用なら、運営側で接続文字列を取得して受講者に配布し、`pwsh .\scripts\00_generate-env.ps1 -Force -AppInsightsConnectionString "<接続文字列>"` で手動指定させる。


