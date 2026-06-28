# Lab2-3｜Agent ID 作成と統制検証

> 親: [lab2-1 全体概要](lab2-1_全体概要.md) ／ 前: [lab2-2 ACA カスタム エージェントのデプロイ](lab2-2_ACAカスタムエージェントデプロイ.md)
> 本ファイルは Lab2 の **§4–§7（Setup / Publish / インスタンス作成 / 検証結果）**。実行体のデプロイ（§3）は [lab2-2](lab2-2_ACAカスタムエージェントデプロイ.md)。ガバナンスの検証（CA / Purview / Defender）は [lab4-1 Agent ID のガバナンス検証](../lab4/lab4-1_AgentIDガバナンス検証.md) に分離した。

## 4. Setup（blueprint 登録）

> 出典: [Set up an agent blueprint](https://learn.microsoft.com/en-us/microsoft-agent-365/developer/registration)

Agent ID・Blueprint・権限は **`a365 setup all` で作成**する。本セクションは「自分で一から作る」手順書。ここで作る Agent Identity（SP）が [lab4-1 Agent ID のガバナンス検証](../lab4/lab4-1_AgentIDガバナンス検証.md) の統制対象になる。

### 4.1 前提

| 項目 | 内容 |
|---|---|
| CLI | **Agent 365 CLI**（.NET global tool・.NET 8.0+ が必要）。下記でインストールし `a365 -h` で確認 |
| Entra ロール | **Global Administrator** または **Agent ID Developer** のいずれか |
| Azure | サブスクリプションへの **共同作成者（Contributor）以上**。`az login` 済み（`az account show` で確認） |
| config | エージェント（AI teammate ではない）は config 不要。`--agent-name` でテナント/クライアント アプリを自動解決 |

```powershell
# Agent 365 CLI をインストール（出典: https://learn.microsoft.com/en-us/microsoft-agent-365/developer/agent-365-cli）
dotnet tool install --global Microsoft.Agents.A365.DevTools.Cli
a365 -h    # ヘルプが出れば OK

# Azure サインインとサブスクリプション確認
az login
az account show
```

> **`a365` が「認識されない」場合**: CLI 本体（`%USERPROFILE%\.dotnet\tools\a365.exe`）はあるのに `.dotnet\tools` が PATH 未登録のことがある。永続追加（**1 回だけ**・新しいターミナルから反映）:
>
> ```powershell
> $tools = "$env:USERPROFILE\.dotnet\tools"
> $userPath = [Environment]::GetEnvironmentVariable("Path","User")
> if ($userPath -notlike "*$tools*") {
>   [Environment]::SetEnvironmentVariable("Path", "$userPath;$tools", "User")
> }
> # 現在のセッションだけ通すなら:
> $env:PATH = "$tools;$env:PATH"
> ```

### 4.2 setup の実行

**lab2 フォルダー（`Handson\lab2`）で実行する**（**3〜5 分**かかる）。`a365 setup all` は**カレント ディレクトリ**に `a365.config.json` / `a365.generated.config.json` を生成するため、lab2 直下で実行して両 config を lab2 ルートに置く（agent フォルダー内のスクリプトは親の lab2 ルートから自動で読み取る）。

> **受講者は 12 人（user01〜user12）。エージェント名はテナント内で一意である必要がある**ため、`--agent-name` に**自分の受講者識別子をサフィックス**として付ける（例: `custom-maf-agent-a365-user01`）。これで Blueprint 登録・Agent Identity・Azure リソース名が受講者ごとに衝突しない。以降の手順に出てくる `custom-maf-agent-a365` も、自分のサフィックス付き名（`custom-maf-agent-a365-userNN`）に読み替えること。

```powershell
cd C:\GitHub\Agent365-Onboarding\Handson\lab2

# 受講者識別子（user01〜user12 のうち自分のもの）をここで指定
$me = "user01"   # ← 自分の番号に変更（user01〜user12）

# config 不要モード（エージェント）。受講者ごとに一意なエージェント名で実行:
a365 setup all --agent-name "custom-maf-agent-a365-$me"
```

> **`Warn: Frontier Preview Program - Tenant enrollment cannot be verified automatically ...` が出ても止まらない**。Agent 365 は **Frontier（Microsoft 365 Copilot 早期プレビュー）プログラム** の機能で、CLI はテナントが Frontier 登録済みかを自動確認できないため警告するだけ。**処理は継続する**。本ハンズオンのテナントは登録済みなので**無視して続行**してよい（未登録テナントだと後段の Blueprint 登録・同意 `resourceConsents` が失敗・空になり得る）。登録案内: <https://adoption.microsoft.com/copilot/frontier-program/>

`a365 setup all` が一括で行うこと:

| 種別 | 内容 |
|---|---|
| Azure インフラ | リソース グループ・App Service プラン・Web App（システム割り当て MI 付き）。Web App は `/api/messages` を想定したメッセージング ホスト |
| Entra 登録 | Blueprint アプリ登録・Blueprint SP・**インスタンス用 Agent Identity**・`managerApplications` 設定（プラットフォーム管理に必須・CLI が自動設定） |
| 権限付与 | Graph（Mail / Chat / Files / Sites / ChannelMessage 等）・Agent 365 Tools・Messaging Bot API・Observability・Power Platform。**継承可能（inheritable）** として設定され、インスタンスへ伝播 |
| 資格情報 | Blueprint のクライアント シークレット（DPAPI 保護で生成・config に格納） |
| 出力 | 作業ディレクトリに **2 つの config** を生成 → `a365.config.json`（入力＝tenantId・表示名・`useBlueprint` 等のフラグ。実 ID もシークレットも含まず**コミット可**）と `a365.generated.config.json`（出力＝provision された実リソース ID＋Blueprint シークレット〔DPAPI 保護〕。**コミット禁止**） |

> **Global Administrator で実行**: 同意用のブラウザーが開く。同意フローを完了すると `resourceConsents` が埋まり `completed: true` になる。
> **Agent ID Developer で実行**: OAuth2 の管理者同意だけは別ステップ。CLI が出力する **同意 URL を Global Administrator に共有**してもらう（完了まで `resourceConsents` が空・`completed: false` のことがある）。

> M365 エージェント（Teams/Copilot）としてメッセージング エンドポイントも自動登録したい場合は `a365 setup all --m365` を使う。AI teammate は `--aiteammate`（このモードだけ `a365.config.json` を**実行前に手書き**で用意する必要がある。素のエージェント モードでは CLI が `a365.config.json` を自動生成するので手書き不要）。
> 本ラボは素の `a365 setup all` で **Agent ID の発行と統制（§7）**まで。Teams からの実メッセージ往復（メッセージング エンドポイント登録）は後付け工程として [Lab1-3](../lab7/Lab1-3_m365.md) にまとめた。

### 4.3 作成結果の検証

**(1) 生成 config を確認**（`a365.generated.config.json` のこと。**シークレットはチャット/ログに貼らない**）。§4.2 と同じ lab2 フォルダーで実行する:

```powershell
cd C:\GitHub\Agent365-Onboarding\Handson\lab2
Get-Content a365.generated.config.json | ConvertFrom-Json | Format-List `
  agentBlueprintId, agentBlueprintServicePrincipalObjectId, agenticAppId, `
  agentRegistrationId, managedIdentityPrincipalId, messagingEndpoint, completed
```

確認ポイント（カッコ内は本ラボの実測値）:

| キー | 期待 | 意味 |
|---|---|---|
| `agentBlueprintId` | GUID（`e65ce763-…`） | Blueprint appId。Developer Portal / 管理センターで使う |
| `agentBlueprintServicePrincipalObjectId` | GUID（`d96dee9c-…`） | Blueprint SP |
| `agenticAppId` | GUID（`9ff24e53-…`） | **インスタンスの Agent Identity（§7 の統制対象）** |
| `agentRegistrationId` | `T_…`（`T_a1c916c0-…`） | エージェント登録 |
| `managedIdentityPrincipalId` | GUID | Web App のシステム割り当て MI |
| `agentBlueprintClientSecret` | 存在（値はマスク） | Blueprint 認証シークレット |
| `resourceConsents[*].consentGranted` | `true` | Graph 等が管理者同意済み |
| `resourceConsents[*].inheritablePermissionsConfigured` | `true` | インスタンスへ継承される |
| `completed` | `true` | setup 完了（同意未了だと `false`） |

**(2) Entra 登録を確認**:

確認手順（UI）:

1. [Microsoft Entra 管理センター](https://entra.microsoft.com) → 左メニュー **エージェント** → **Agents** を開く。
2. 左ブレードの **Agent blueprints** を選ぶ → テナント内の Blueprint 一覧が出る（**Name / Agent identities / Status / Blueprint Application ID / Object ID** 列）。
3. **Search by name, object ID or blueprint app ID** に自分の Blueprint 名 `custom-maf-agent-a365-userNN`（userNN は自分の番号。例 user01）を入れて絞り込む。自分の appId は `a365.generated.config.json` の `agentBlueprintId` で確認できる（appId で検索してもよい）。該当行（アイコン **CB** = `custom-maf-agent-a365-userNN Blueprint`）の **Status** が **Active** であることを確認する。
4. 一覧の **Name** 列のリンク（`custom-maf-agent-a365-userNN Blueprint`）をクリックして詳細を開き、次の値を確認する（タブ: **Agent identity blueprint** / **Agent blueprint principal**、操作: **Disable / Delete / Refresh**）。**下表は本ラボ実測の例。自分の app ID / object ID は §4.2 の `a365.generated.config.json`（`agentBlueprintId` / `agentBlueprintServicePrincipalObjectId`）と一致する。**

   | 項目 | 値（例・本ラボ実測） |
   |---|---|
   | **Status** | Active |
   | **Agent identities** | 1 |
   | **Owners** | 0 |
   | **Sponsors** | 0 |
   | **Created on** | 2026/6/23 |
   | **Blueprint app ID** | `e65ce763-…`（自分の値は `agentBlueprintId`） |
   | **Blueprint object ID** | `e65ce763-…`（app ID と同値） |
   | **Blueprint principal object ID** | `d96dee9c-…`（自分の値は `agentBlueprintServicePrincipalObjectId`） |

> CLI で確認するなら（実体はマルチテナントのアプリ登録 `signInAudience=AzureADMultipleOrgs`）:
>
> ```powershell
> # 自分の Blueprint appId を取得する。
> # 方法A（推奨・PC 非依存）: Entra から displayName で引く。userNN は自分の番号に変更（例 user01）
> $bp   = "custom-maf-agent-a365-userNN Blueprint"
> $bpId = (az ad app list --filter "displayName eq '$bp'" --query "[0].appId" -o tsv)
> # 方法B（setup を実行した同じ PC・同じフォルダなら）: generated config から取得
> #   $bpId = (Get-Content a365.generated.config.json | ConvertFrom-Json).agentBlueprintId
> $bpId   # 空でなく GUID が出ることを確認
> # ① アプリ登録: displayName / appId / audience を確認
> az ad app show --id $bpId `
>   --query "{displayName:displayName, appId:appId, audience:signInAudience}" -o json
> # ② サービスプリンシパル: displayName / type / enabled を確認
> az ad sp show --id $bpId `
>   --query "{displayName:displayName, type:servicePrincipalType, enabled:accountEnabled}" -o json
> ```
>
> **期待値（この値なら OK）**:
>
> | コマンド | キー | 期待値 |
> |---|---|---|
> | ① app | `displayName` | `custom-maf-agent-a365-userNN Blueprint` |
> | ① app | `appId` | 自分の `$bpId`（= `agentBlueprintId`） |
> | ① app | `audience` | `AzureADMultipleOrgs`（マルチテナント） |
> | ② sp | `displayName` | `custom-maf-agent-a365-userNN Blueprint` |
> | ② sp | `type` | `Application` |
> | ② sp | `enabled` | `true`（有効） |

**(3) Azure リソースを確認**（**ACA 版** / 任意・トラブルシュート用）:

> §3.3 のスモークテストが通っていれば、ACA のデプロイ・MI・公開 FQDN はすべて成立済みのため**このステップは省略してよい**。エージェントが応答しない場合の切り分けに使う。

```powershell
cd C:\GitHub\Agent365-Onboarding\_report\Handson\lab2\agent-custom-MAF-ACA-A365
pwsh -NoProfile -File ./verify-azure-resources.ps1
```

[verify-azure-resources.ps1](agent-custom-MAF-ACA-A365/verify-azure-resources.ps1) が確認すること（読み取り専用）:

1. リソース グループ内のリソース一覧（`az resource list ... --output table`）
2. ACA 本体のプロビジョニング状態・公開 FQDN（`az containerapp show`）
3. ACA の**システム割り当て MI**（`az containerapp identity show` → `principalId`）

> **MI への Foundry ロール（`Azure AI Developer`）は本ラボの APIM 経由構成では不要。** モデル/MCP は APIM AI Gateway 経由で呼ばれ、MI は `cognitiveservices` の token を取得するだけ（RBAC 不要）。Foundry への RBAC は APIM 自身の MI が保持する。verify スクリプトが「ロール割り当てなし」と表示しても**正常**。

実測の確認結果（本ラボ）:

| 確認項目 | 値 |
|---|---|
| ACA `custom-maf-agent-a365` | `provisioningState = Succeeded` |
| FQDN | `https://custom-maf-agent-a365.proudflower-d41f2cf1.eastus2.azurecontainerapps.io` |
| システム割り当て MI principalId | `18b76884-e692-43e9-9b7b-ebb08c326d2c` |

> 手動で確認する場合:
>
> ```powershell
> az resource list --resource-group rg-userNN --output table   # 例 rg-user01
> # ACA の MI が有効か
> az containerapp identity show --name custom-maf-agent-a365-userNN --resource-group rg-userNN
> ```

> **作り直したいとき**: `Resource already exists` 等で詰まったら `a365 cleanup`（**破壊的**）→ `a365 setup all` でやり直す。config-free で作った場合は `a365 cleanup --agent-name custom-maf-agent-a365-userNN`。

---

## 7. 検証結果（実行後に追記）

| 項目 | 結果 |
|---|---|
| 実行体のデプロイ（§3） | ✅ デプロイ済み・`/chat` 疎通確認済み（`custom-maf-agent-a365.proudflower-d41f2cf1.eastus2.azurecontainerapps.io`） |
| Setup / Agent ID の確認（§4） | （未） |
| Publish（§5） | （未） |
| インスタンス作成（§6） | 対象外（`/api/messages` 未実装で検証不能・Agent ID は §4 で発行済み） |

> **ガバナンスの検証（CA / Purview / Defender、Lab1-1 との対比）** は本ラボの主旨（Agent ID 作成）と分けて、[lab4-1 Agent ID のガバナンス検証](../lab4/lab4-1_AgentIDガバナンス検証.md) に移動した。
