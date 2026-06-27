# Lab1-1｜レジストリ同期のみ（見えるだけ）

**ホスト型（Copilot Studio / Foundry Agent Service）は Agent 365 に自動登録されるため、本章の Registry sync の対象ではない（本章は外部 AI 基盤上のエージェントを同期して可視化するレイヤー）。**

> 統制レベル: **最弱**。在庫に「見える」だけで、Entra Agent ID を主体として持たないため CA / Purview / Defender は効かない。
> 親: [Lab1 全体まとめ](README.md)
> 一次情報: [Registry sync（preview）](https://learn.microsoft.com/microsoft-agent-365/admin/agent-registry)

---

## 1. ゴール

- **外部 AI 基盤上のエージェント**が Registry sync により Agent 365 レジストリ（M365 管理センターの在庫）に **見える** ことを確認する。
- ただし Entra Agent ID を主体として持たないため、**CA でブロック等の主体統制はできない**（＝可視化のみ・弱い統制）ことを Lab1-2 との対比で示す。

> **位置づけ：Lab1-1 は“外部基盤エージェントの棚卸し（可視化同期）”のレイヤー**であり、**自作エージェントを“統制”する仕組みではない**。**ホスト型（Copilot Studio / Foundry Agent Service）は Microsoft が身分証と実行ランタイムの両方を管理し、Agent 365 に自動登録される**ため Registry sync は不要で、本章はあくまで外部基盤の同期を扱う。自作エージェントを本当に統制したい場合は **Agent ID を付与する Lab1-2** が正道。

## 2. 実現方式

| 区分 | 方法 | 必要なもの | 位置づけ |
|---|---|---|---|
| **A: Registry sync（本章の主題）** | M365 管理センターで外部基盤を接続し `Sync agents` で在庫へ同期 | 外部クラウドの認証情報（後述） | 外部基盤エージェントの可視化（Unmanaged） |

> 本章の主題は **A（Registry sync）**。Lab1-1 の“弱い統制”は外部基盤の可視化同期であって、自作エージェント統制の手段ではないことに注意。自作エージェントを統制したい場合は Lab1-2 の Agent ID 付与へ進む。

---

## 3. 案A：外部基盤の Registry sync

### 3.1 仕組み（重要）

- Registry sync は外部 AI 基盤（**Amazon Bedrock / Google Vertex AI / Salesforce Agentforce / Databricks Genie**）を接続し、その基盤上のエージェントを Agent 365 registry へ同期して "centralized visibility" を得る機能（preview）。
- **同期されたエージェントには Entra Agent ID は付与されない**。よって CA / Purview / Defender は適用されず、管理操作は「AI platform API がサポートする範囲」に留まる（＝可視化のみ）。
- レジストリ上では、これらは **「Unmanaged agents（Agent 365 の外で作成・管理され、リスク保護も観測も無いエージェント）」** として集計・表示される。サマリの `Unmanaged agents` カウント、および `Publisher Type`（Microsoft / 外部パートナー / 自社）・`Platform` フィルターで素のエージェントと区別できる。← これが「統制が効かない弱い段」の公式な見え方。
- 認証は **各基盤ネイティブのクレデンシャル**で行う。Azure RBAC は使わないため、対象基盤が別の Azure テナント／サブスクリプション（あるいは AWS/GCP）にあっても、URL とクレデンシャルさえ揃えば接続できる。
- 一次情報: [Registry sync（preview）](https://learn.microsoft.com/microsoft-agent-365/admin/agent-registry) / [Manage agent registry（Unmanaged agents / フィルター）](https://learn.microsoft.com/microsoft-365/admin/manage/agent-registry) / [Connect existing agents](https://learn.microsoft.com/microsoft-agent-365/connect-existing-agents)

### 3.2 基盤別の必要情報

| 基盤 | 必要情報 |
|---|---|
| **Databricks Genie** | ワークスペース URL（Databricks ポータルの URL）／クライアント ID（サービス プリンシパルの client/application ID）／クライアント シークレット（SP の client secret）。**SP はワークスペース管理者権限が必要** |
| Amazon Bedrock | AWS リージョン／アクセス キー ID／シークレット アクセス キー（IAM 権限 `bedrock:ListAgents` `bedrock:GetAgent` ほか） |
| Google Vertex AI | GCP リージョン／プロジェクト ID／サービス アカウント キー |
| Salesforce Agentforce | Salesforce 組織のリージョン／接続アプリ（Connected App）の OAuth クレデンシャル（Consumer Key / Secret）等。Agentforce の Agent API へアクセスできる権限が必要 |

> **Registry sync の対応プラットフォームは現時点で上記 4 つのみ**（Amazon Bedrock / Google Vertex AI / Salesforce Agentforce / Databricks Genie）。一次情報: [Registry sync（preview）— Supported platforms](https://learn.microsoft.com/microsoft-agent-365/admin/agent-registry)。Microsoft は順次拡大予定。

> **本検証で使う Databricks（確定）**
> - Workspace URL: `https://adb-1992108119650763.3.azuredatabricks.net`
> - SP Client ID: `f96a96fc-eb44-445d-b570-f0e942c3806a`
> - Client Secret: 手元保管（ドキュメント／会話に記載しない）。Genie スペースあり。

### 3.3 接続手順（ポータル操作）

> ⚠️ 接続〜同期は **M365 管理センターのポータル操作**で、テナントの **Agent 365 Frontier プログラム参加 + 対応ライセンス**が前提。CLI からは自動化できない。

1. M365 管理センター → **エージェント** → **すべてのエージェント** を開く
2. **Registry sync** の Web パーツ → **管理** → **＋ プラットフォームの接続**
3. **名前 / 説明** を入力
4. **プラットフォーム**（例: Databricks Genie）を選択
5. **リージョン** を選択
6. **自動インポート** のトグルを設定（オンで以後の新規エージェントも自動同期）
7. **クレデンシャル**を入力（3.2 の基盤別フィールド）
8. **Validate（検証）** → 成功を確認
9. **Save（保存）**
10. **Sync agents（エージェントを同期）** を実行

#### ⚠️ ハマりどころ：`Success, 0 agents synced`（同期は成功するがエージェントが0件）

接続は成功するのに **0 agents synced** になる場合、**Genie Space が同期 SP に共有されていない**のが原因。同期は SP のトークンで Genie API を叩いて「その SP がアクセスできる Space」を列挙するため、ワークスペース admin でも **Genie Space 個別の共有権限**が無いと列挙対象に入らない。

**対処：Genie Space を SP に共有**
1. Databricks → **Genie スペース** → 対象 Space（例: `bank_code`）を開く
2. 右上 **Share（共有）**
3. `agent365-registry-sync`（SP）を追加し、権限 **Can View（または Can Run）以上**を付与 → 保存
4. M365 管理センターの Databricks Genie 接続画面に戻り、**Sync agents** を再実行
5. **Synced agents** に Space が出れば成功

**任意：SP から Space が見えるか API 確認**（共有前は空配列、共有後に出れば原因確定）

```powershell
$tok = $r.access_token
Invoke-RestMethod -Method Get -Uri "$workspaceUrl/api/2.0/genie/spaces" `
  -Headers @{ Authorization = "Bearer $tok" } | ConvertTo-Json -Depth 6
```

### 3.4（任意）接続前に Databricks SP を事前検証

ポータル接続でクレデンシャル不正に気づくと手戻りになるため、事前に Databricks OAuth M2M でトークンが取れるか確認しておくと安全。

```powershell
# client_secret はターミナルに直接入力する（このドキュメントや会話には貼らない）
$workspaceUrl = "https://<your-workspace>.azuredatabricks.net"
$clientId     = "<service-principal-client-id>"
$body = @{ grant_type = "client_credentials"; scope = "all-apis" }
$pair = "$clientId`:$($env:DB_CLIENT_SECRET)"   # シークレットは環境変数経由で
$basic = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes($pair))
Invoke-RestMethod -Method Post -Uri "$workspaceUrl/oidc/v1/token" `
  -Headers @{ Authorization = "Basic $basic" } -Body $body -ContentType "application/x-www-form-urlencoded"
```

> シークレットは **クエスチョン入力ツール経由では渡さない**（モデルを経由するため）。ターミナル／ポータルに直接入力する。

#### ⚠️ ハマりどころ：401 Unauthorized の切り分け

本検証で発生した 401 とその原因。Registry sync 用 SP（`agent365-registry-sync`）は **Databricks アカウント レベル**で作成したため、つまずきやすい。

| 症状 | 原因 | 対処 |
|---|---|---|
| ワークスペース版 `/oidc/v1/token` が 401 | OAuth secret を貼らず、**シークレットの「ID（識別子）」を貼っていた** | 「資格情報とシークレット」タブで OAuth secret を生成し、**Secret 値**（生成直後のみ表示）を使う。Client ID は SP の **UUID**（数値 ID ではない） |
| 新しい OAuth secret でも 401 | **SP がワークスペース未所属** | アカウント コンソール → Workspaces → 対象WS → Permissions で SP を **Admin** で追加 |

**切り分け手順**：アカウント レベル エンドポイントで成功するか確認すると、シークレット正否とワークスペース所属を分離できる。

```powershell
# アカウント レベル（シークレット自体の正否確認）— OK なら secret は正常
$r = Invoke-RestMethod -Method Post -Uri "https://accounts.azuredatabricks.net/oidc/accounts/<account_id>/v1/token" `
  -Headers @{ Authorization = "Basic $basic" } -Body $body -ContentType "application/x-www-form-urlencoded"
```

アカウント レベルが OK でワークスペース レベルが 401 → **ワークスペース未所属が確定**。SP を WS admin で追加すれば解決。

**本検証の実績（2026-06-23）**：上記2件をクリアし、ワークスペース版で `TOKEN OK (expires_in=3600)` を確認。認証要件（Workspace URL / Client ID / Client Secret + SP=workspace admin）すべて充足。

---

## 4. 検証観点（Lab1-2 との対比）

| 観点 | Lab1-1（本章） | Lab1-2（Agent ID 付き） |
|---|---|---|
| 在庫に見えるか | ○（**外部基盤の同期のみ**で可視化） | ○ |
| アクセス主体として CA でブロックできるか | **×（主体が無い）** | ○ |
| Purview / Defender が自動で効くか | **×** | ○ |
| 管理できる範囲 | AI platform API の範囲のみ | Entra governance 全般 |

---

## 5. 検証結果（実行後に追記）

| 項目 | 結果 |
|---|---|
| 案A: 接続〜同期 | ✅ 成功（2026-06-23）。M365 管理センターで Databricks Genie 接続を作成 → `Sync agents` → `Success`。初回は `0 agents synced`（Genie Space 未共有が原因）→ Genie Space `bank_code` を SP `agent365-registry-sync` に共有後、再同期で取り込み成功 |
| 案A: 在庫に同期エージェントが出たか | ✅ `Synced agents` に `bank_code` が掲載。**Unmanaged agents（管理対象外）**＝ Agent ID 無し |
| 対比: CA ブロック不可の確認 | ⚠️ `contoso-helpdesk-a365 Agent`（Agent ID 持ち）は行メニューに **Block** が出る＝統制可能。一方 Unmanaged（同期のみ）のエージェントにはこの統制が効かない（Block 不可） |
